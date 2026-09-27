import 'dart:async';
import 'dart:convert';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:nostr/nostr.dart' as nostr;
import 'package:uuid/uuid.dart';

import '../../../../shared/crypto/nip44.dart';
import '../../../../shared/relay/observer_control.dart';
import '../../../../shared/relay/relay.dart';
import '../observer_subscription.dart';
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

/// Every running turn across the owner's agents, oldest first.
final activeTurnsProvider = Provider.autoDispose<List<ActiveTurn>>((ref) {
  final frames = ref.watch(observerRelayProvider).framesByAgent;
  final now = ref.watch(sessionsClockProvider).value ?? DateTime.now();
  return deriveActiveTurns(frames, now);
});

/// Usage per session id for one agent, from the agent's NIP-AM reports of
/// the last [sessionUsageLookback]. Refreshes every [sessionUsageRefresh].
/// A failed read is an error state, never an empty result.
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

      final seen = <String>{};
      final metrics = <TurnMetric>[];
      for (final event in events) {
        if (!seen.add(event.id)) continue;
        final metric = decodeTurnMetric(
          event,
          ownerPrivkeyHex: privHex,
          ownerPubkey: owner,
          agentPubkey: agent,
        );
        if (metric != null) metrics.add(metric);
      }
      return sumSessionUsage(metrics);
    });

/// Verifies and decrypts one kind 44200 event from [agentPubkey] to the
/// owner. Returns null for anything that fails a check (NIP-AM: ignore
/// events that fail to verify, decrypt, or parse).
TurnMetric? decodeTurnMetric(
  NostrEvent event, {
  required String ownerPrivkeyHex,
  required String ownerPubkey,
  required String agentPubkey,
}) {
  if (event.kind != EventKind.agentTurnMetric ||
      event.pubkey.toLowerCase() != agentPubkey ||
      event.getTagValue('agent')?.toLowerCase() != agentPubkey ||
      event.getTagValue('p')?.toLowerCase() != ownerPubkey) {
    return null;
  }
  try {
    nostr.Event(
      event.id,
      event.pubkey,
      event.createdAt,
      event.kind,
      event.tags,
      event.content,
      event.sig,
    );
    final key = getConversationKey(ownerPrivkeyHex, agentPubkey);
    final json = jsonDecode(nip44Decrypt(key, event.content));
    return json is Map<String, dynamic> ? TurnMetric.fromJson(json) : null;
  } catch (_) {
    return null;
  }
}

/// The agent's answer to one Stop request.
enum StopOutcome {
  /// The runtime signalled the turn to stop.
  sent,

  /// The turn had already ended.
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
