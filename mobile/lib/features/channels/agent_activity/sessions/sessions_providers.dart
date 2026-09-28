import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:nostr/nostr.dart' as nostr;
import 'package:uuid/uuid.dart';

import '../../../../shared/crypto/nip44.dart';
import '../../../../shared/relay/observer_control.dart';
import '../../../../shared/relay/relay.dart';
import '../observer_models.dart';
import '../observer_subscription.dart';
import '../transcript_builder.dart';
import 'active_turns.dart';
import 'session_usage.dart';

/// How far back the Sessions page reads usage reports.
const sessionUsageLookback = Duration(days: 7);

/// Usage reports arrive once per completed turn; a slow poll is enough.
const sessionUsageRefresh = Duration(seconds: 20);

/// How long Stop waits for the agent's `control_result`.
const stopResultTimeout = Duration(seconds: 8);

/// Upper bound on usage reports read per agent.
const _maxUsageReports = 1000;

/// One tick per second while the Sessions page is open.
final sessionsClockProvider = StreamProvider.autoDispose<DateTime>(
  (ref) => Stream.periodic(const Duration(seconds: 1), (_) => DateTime.now()),
);

/// How long after the activity subscription opens a missing turn can still
/// be a turn that has not sent its next liveness frame (about every 10 s).
const sessionsDiscoveryWindow = Duration(seconds: 15);

/// Every turn across the owner's agents that started and has not reported
/// an end, oldest first. Includes quiet turns ([ActiveTurn.isQuietAt]).
final activeTurnsProvider = Provider.autoDispose<List<ActiveTurn>>(
  (ref) =>
      ref.watch(observerRelayProvider.select((state) => state.activeTurns)),
);

/// How much the Sessions page can know about running turns right now.
enum SessionsDiscovery {
  /// No relay connection or signing key: no activity can arrive.
  notConnected,

  /// The activity subscription is opening.
  connecting,

  /// The activity subscription failed or closed.
  unavailable,

  /// Open, but running turns may not have sent their next liveness frame.
  discovering,

  /// Open for longer than [sessionsDiscoveryWindow].
  listening,
}

/// The activity subscription's state, with any error text and the number of
/// turns dropped for the per-agent limit.
typedef SessionsStatus = ({
  SessionsDiscovery discovery,
  String? errorMessage,
  int droppedTurnCount,
});

final sessionsStatusProvider = Provider.autoDispose<SessionsStatus>((ref) {
  final relay = ref.watch(observerRelayProvider);
  final now = ref.watch(sessionsClockProvider).value ?? DateTime.now();
  return (
    discovery: sessionsDiscoveryFor(relay, now),
    errorMessage: relay.errorMessage,
    droppedTurnCount: relay.droppedTurnCount,
  );
});

/// Maps the activity subscription to what the page may claim. Missing frames
/// never prove that no turn is running, so only [SessionsDiscovery.listening]
/// allows an empty list to read as "none reported".
SessionsDiscovery sessionsDiscoveryFor(ObserverRelayState relay, DateTime now) {
  switch (relay.connection) {
    case ObserverConnectionState.idle:
      return SessionsDiscovery.notConnected;
    case ObserverConnectionState.connecting:
      return SessionsDiscovery.connecting;
    case ObserverConnectionState.error:
      return SessionsDiscovery.unavailable;
    case ObserverConnectionState.open:
      final since = relay.openSince;
      return since == null || now.difference(since) < sessionsDiscoveryWindow
          ? SessionsDiscovery.discovering
          : SessionsDiscovery.listening;
  }
}

/// A short description of what one turn is doing now, from its latest
/// transcript item, or null when its frames say nothing yet.
final turnActivityProvider = Provider.autoDispose
    .family<String?, ({String agentPubkey, String turnId})>((ref, key) {
      final frames = ref.watch(
        observerRelayProvider.select(
          (state) => state.framesByAgent[key.agentPubkey.toLowerCase()],
        ),
      );
      if (frames == null) return null;
      return describeTurnActivity(
        buildTranscript([
          for (final frame in frames)
            if (frame.turnId == key.turnId) frame,
        ]),
      );
    });

/// The latest transcript item as a few plain words.
String? describeTurnActivity(List<TranscriptItem> items) {
  for (final item in items.reversed) {
    switch (item) {
      case ToolItem(:final title, :final toolName):
        final label = title.trim().isNotEmpty ? title.trim() : toolName.trim();
        if (label.isNotEmpty) return label;
      case ThoughtItem():
        return 'Thinking';
      case MessageItem(:final role):
        return role == 'assistant' ? 'Writing a reply' : 'Reading the request';
      case LifecycleItem(:final title):
        if (title.trim().isNotEmpty) return title.trim();
      case MetadataItem():
        continue;
    }
  }
  return null;
}

/// Usage per session id for one agent, from the agent's NIP-AM reports of
/// the last [sessionUsageLookback]. Refreshes every [sessionUsageRefresh].
/// A failed read is an error state, never an empty result. Verifying and
/// decrypting the reports runs on a worker isolate ([decodeSessionUsage]).
///
/// The web build has no isolates, so decoding runs on the page's only
/// thread, where one signature check takes about 60 ms. The browser
/// therefore skips it: the relay checks every signature before it stores an
/// event, and a report that decrypts with the owner-agent key was written by
/// the agent. The observer frames on this page are read the same way.
final agentSessionUsageProvider = FutureProvider.autoDispose
    .family<Map<String, SessionUsage>, String>((ref, agentPubkey) async {
      final timer = Timer(sessionUsageRefresh, ref.invalidateSelf);
      ref.onDispose(timer.cancel);

      final privHex = _ownerPrivkey(ref.watch(relayConfigProvider).nsec);
      final owner = nostr.Keys(privHex).public;
      final agent = agentPubkey.toLowerCase();
      final since = DateTime.now().subtract(sessionUsageLookback);
      final events = await ref.read(relaySessionProvider.notifier).queryRelay([
        NostrFilter(
          kinds: const [EventKind.agentTurnMetric],
          authors: [agent],
          tags: {
            '#p': [owner],
          },
          since: since.millisecondsSinceEpoch ~/ 1000,
          limit: _maxUsageReports,
        ),
      ]);

      return compute(
        decodeSessionUsage,
        SessionUsageBatch(
          ownerPrivkeyHex: privHex,
          ownerPubkey: owner,
          agentPubkey: agent,
          events: events,
          verifySignatures: !kIsWeb,
        ),
      );
    });

/// One agent's usage reports to decode, with the owner's key.
@immutable
class SessionUsageBatch {
  final String ownerPrivkeyHex;
  final String ownerPubkey;
  final String agentPubkey;
  final List<NostrEvent> events;

  /// Whether to check each report's signature ([decodeTurnMetric]).
  final bool verifySignatures;

  const SessionUsageBatch({
    required this.ownerPrivkeyHex,
    required this.ownerPubkey,
    required this.agentPubkey,
    required this.events,
    this.verifySignatures = true,
  });
}

/// Verifies, decrypts, and sums [batch]'s reports per session. Derives the
/// conversation key once for the batch. CPU heavy for large batches: run it
/// with `compute`, not on the UI isolate.
Map<String, SessionUsage> decodeSessionUsage(SessionUsageBatch batch) {
  final conversationKey = getConversationKey(
    batch.ownerPrivkeyHex,
    batch.agentPubkey,
  );
  final seen = <String>{};
  final metrics = <TurnMetric>[];
  for (final event in batch.events) {
    if (!seen.add(event.id)) continue;
    final metric = decodeTurnMetric(
      event,
      conversationKey: conversationKey,
      ownerPubkey: batch.ownerPubkey,
      agentPubkey: batch.agentPubkey,
      verifySignature: batch.verifySignatures,
    );
    if (metric != null) metrics.add(metric);
  }
  return sumSessionUsage(metrics);
}

/// Verifies and decrypts one kind 44200 event from [agentPubkey] to the
/// owner. Returns null for anything that fails a check (NIP-AM: ignore
/// events that fail to verify, decrypt, or parse). With [verifySignature]
/// false, the caller relies on the relay's signature check.
TurnMetric? decodeTurnMetric(
  NostrEvent event, {
  required Uint8List conversationKey,
  required String ownerPubkey,
  required String agentPubkey,
  bool verifySignature = true,
}) {
  if (event.kind != EventKind.agentTurnMetric ||
      event.pubkey.toLowerCase() != agentPubkey ||
      event.getTagValue('agent')?.toLowerCase() != agentPubkey ||
      event.getTagValue('p')?.toLowerCase() != ownerPubkey) {
    return null;
  }
  try {
    if (verifySignature) {
      nostr.Event(
        event.id,
        event.pubkey,
        event.createdAt,
        event.kind,
        event.tags,
        event.content,
        event.sig,
      );
    }
    final json = jsonDecode(nip44Decrypt(conversationKey, event.content));
    return json is Map<String, dynamic> ? TurnMetric.fromJson(json) : null;
  } catch (_) {
    return null;
  }
}

/// The agent's answer to one Stop request.
enum StopOutcome {
  /// The runtime signalled the turn to stop.
  sent,

  /// The runtime found no running turn with this ID. The turn may have
  /// ended, or an earlier Stop may still be finishing it (NIP-AO). Only an
  /// ending frame confirms the end.
  noActiveTurn,

  /// The runtime answered with a status this app does not know.
  refused,

  /// No answer arrived in time.
  unconfirmed,
}

/// Sends Stop for exactly one turn and waits for the agent's answer.
final stopTurnProvider = Provider<Future<StopOutcome> Function(ActiveTurn)>(
  (ref) =>
      (turn) => stopActiveTurn(ref, turn),
);

/// Sends `cancel_turn` naming [turn]'s `turnId` and waits for the matching
/// `control_result`. Refuses a turn that did not advertise exact-turn Stop:
/// an older runtime would cancel whatever runs in the channel, which may be
/// a later turn than the one shown.
Future<StopOutcome> stopActiveTurn(
  Ref ref,
  ActiveTurn turn, {
  Duration timeout = stopResultTimeout,
}) async {
  if (!turn.cancelByTurnId) {
    throw StateError('This agent cannot stop a single turn yet.');
  }
  final privHex = _ownerPrivkey(ref.read(relayConfigProvider).nsec);
  final requestId = const Uuid().v4();
  final agent = turn.agentPubkey.toLowerCase();
  final result = Completer<StopOutcome>();

  void check(ObserverRelayState state) {
    if (result.isCompleted) return;
    for (final frame in state.framesByAgent[agent] ?? const []) {
      final payload = frame.payload;
      if (frame.kind == 'control_result' &&
          payload is Map &&
          payload['type'] == 'cancel_turn' &&
          payload['requestId'] == requestId) {
        result.complete(switch (payload['status']) {
          'sent' => StopOutcome.sent,
          'no_active_turn' => StopOutcome.noActiveTurn,
          _ => StopOutcome.refused,
        });
        return;
      }
    }
  }

  // Listen before publishing so a fast answer is not missed.
  final subscription = ref.listen<ObserverRelayState>(
    observerRelayProvider,
    (_, next) => check(next),
  );
  final timer = Timer(timeout, () {
    if (!result.isCompleted) result.complete(StopOutcome.unconfirmed);
  });
  try {
    await ref
        .read(relaySessionProvider.notifier)
        .publish(
          buildObserverControlEvent(
            ownerPrivkeyHex: privHex,
            agentPubkey: agent,
            payload: cancelTurnPayload(
              channelId: turn.channelId,
              turnId: turn.turnId,
              requestId: requestId,
            ),
          ),
        );
    check(ref.read(observerRelayProvider));
    return await result.future;
  } finally {
    timer.cancel();
    subscription.close();
  }
}

String _ownerPrivkey(String? nsec) {
  if (nsec == null || nsec.isEmpty) {
    throw StateError('No signing key for this community.');
  }
  final privHex = nostr.Nip19.decode(payload: nsec).data;
  if (privHex.isEmpty) throw const FormatException('Invalid nsec');
  return privHex;
}
