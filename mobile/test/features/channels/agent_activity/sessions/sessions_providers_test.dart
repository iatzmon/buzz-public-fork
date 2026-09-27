import 'dart:async';
import 'dart:convert';

import 'package:buzz/features/channels/agent_activity/observer_subscription.dart';
import 'package:buzz/features/channels/agent_activity/sessions/active_turns.dart';
import 'package:buzz/features/channels/agent_activity/sessions/session_usage.dart';
import 'package:buzz/features/channels/agent_activity/sessions/sessions_providers.dart';
import 'package:buzz/shared/crypto/nip44.dart';
import 'package:buzz/shared/relay/relay.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:nostr/nostr.dart' as nostr;

final _owner = nostr.Keys.generate();
final _agent = nostr.Keys.generate();

ActiveTurn _turn({bool cancelByTurnId = true}) => ActiveTurn(
  agentPubkey: _agent.public,
  turnId: 'turn-1',
  channelId: 'chan-1',
  sessionId: 'sess-1',
  startedAt: DateTime.utc(2026),
  lastSeenAt: DateTime.utc(2026),
  cancelByTurnId: cancelByTurnId,
);

NostrEvent _agentEvent({
  required int kind,
  required Map<String, Object?> payload,
  required List<List<String>> tags,
}) {
  final key = getConversationKey(_agent.secret, _owner.public);
  final event = nostr.Event.from(
    kind: kind,
    content: nip44Encrypt(key, jsonEncode(payload)),
    tags: tags,
    secretKey: _agent.secret,
    verify: false,
  );
  return NostrEvent.fromJson(event.toMap());
}

NostrEvent _controlResult(String requestId, String status) => _agentEvent(
  kind: EventKind.agentObserverFrame,
  payload: {
    'seq': 9,
    'timestamp': DateTime.now().toUtc().toIso8601String(),
    'kind': 'control_result',
    'channelId': 'chan-1',
    'payload': {
      'type': 'cancel_turn',
      'status': status,
      'requestId': requestId,
    },
  },
  tags: [
    ['p', _owner.public],
    ['agent', _agent.public],
    ['frame', 'telemetry'],
  ],
);

NostrEvent _metricEvent({String? pTag, Map<String, Object?>? payload}) =>
    _agentEvent(
      kind: EventKind.agentTurnMetric,
      payload:
          payload ??
          {
            'harness': 'claude',
            'timestamp': '2026-09-27T12:00:00Z',
            'sessionId': 'sess-1',
            'turnSeq': 1,
            'turn': {'inputTokens': 1200, 'outputTokens': 300, 'costUsd': 0.5},
          },
      tags: [
        ['p', pTag ?? _owner.public],
        ['agent', _agent.public],
      ],
    );

void main() {
  group('stopActiveTurn', () {
    test('publishes an owner-signed control naming the exact turn', () async {
      final session = _FakeRelaySession(answerStatus: 'sent');
      final container = _container(session);
      container.read(observerRelayProvider);
      await pumpEventQueue();

      final outcome = await container.read(stopTurnProvider)(_turn());

      expect(outcome, StopOutcome.sent);
      final event = session.published.single;
      expect(event.kind, EventKind.agentObserverFrame);
      expect(event.pubkey, _owner.public);
      expect(event.tags, [
        ['p', _agent.public],
        ['agent', _agent.public],
        ['frame', 'control'],
      ]);
      final payload = session.decrypt(event);
      expect(payload, {
        'type': 'cancel_turn',
        'channelId': 'chan-1',
        'turnId': 'turn-1',
        'requestId': isA<String>(),
      });
    });

    test('reports an ended turn', () async {
      final session = _FakeRelaySession(answerStatus: 'no_active_turn');
      final container = _container(session);
      container.read(observerRelayProvider);
      await pumpEventQueue();

      expect(
        await container.read(stopTurnProvider)(_turn()),
        StopOutcome.noActiveTurn,
      );
    });

    test('ignores an answer to a different request', () async {
      final session = _FakeRelaySession(
        answerStatus: 'sent',
        answerRequestId: 'someone-else',
      );
      final container = _container(session);
      container.read(observerRelayProvider);
      await pumpEventQueue();

      final ref = container.read(_refProvider);
      expect(
        await stopActiveTurn(
          ref,
          _turn(),
          timeout: const Duration(milliseconds: 50),
        ),
        StopOutcome.unconfirmed,
      );
    });

    test('refuses a turn without exact-turn Stop and sends nothing', () async {
      final session = _FakeRelaySession(answerStatus: 'sent');
      final container = _container(session);

      await expectLater(
        container.read(stopTurnProvider)(_turn(cancelByTurnId: false)),
        throwsStateError,
      );
      expect(session.published, isEmpty);
    });
  });

  group('agentSessionUsageProvider', () {
    test('sums verified reports for the agent by session', () async {
      final session = _FakeRelaySession(queryResult: [_metricEvent()]);
      final container = _container(session);

      final usage = await container.read(
        agentSessionUsageProvider(_agent.public).future,
      );

      expect(usage['sess-1']!.inputTokens, const UsageTotal<int>(1200));
      expect(usage['sess-1']!.costUsd, const UsageTotal<double>(0.5));
      final filter = session.queries.single.single;
      expect(filter.kinds, [EventKind.agentTurnMetric]);
      expect(filter.authors, [_agent.public]);
      expect(filter.tags['#p'], [_owner.public]);
    });

    test('a failed read is an error, not empty usage', () async {
      final session = _FakeRelaySession(queryError: StateError('offline'));
      final container = _container(session);
      final sub = container.listen(
        agentSessionUsageProvider(_agent.public),
        (_, _) {},
      );
      addTearDown(sub.close);
      await pumpEventQueue();

      expect(sub.read().hasError, isTrue);
      expect(sub.read().value, isNull);
    });
  });

  group('decodeTurnMetric', () {
    TurnMetric? decode(NostrEvent event) => decodeTurnMetric(
      event,
      ownerPrivkeyHex: _owner.secret,
      ownerPubkey: _owner.public,
      agentPubkey: _agent.public,
    );

    test('accepts a signed report to this owner', () {
      expect(decode(_metricEvent())?.sessionId, 'sess-1');
    });

    test('rejects a report addressed to another owner', () {
      expect(decode(_metricEvent(pTag: nostr.Keys.generate().public)), isNull);
    });

    test('rejects a report with a broken signature', () {
      final event = _metricEvent();
      final forged = NostrEvent(
        id: event.id,
        pubkey: event.pubkey,
        createdAt: event.createdAt + 1,
        kind: event.kind,
        tags: event.tags,
        content: event.content,
        sig: event.sig,
      );
      expect(decode(forged), isNull);
    });
  });
}

final _refProvider = Provider<Ref>((ref) => ref);

ProviderContainer _container(_FakeRelaySession session) {
  final container = ProviderContainer(
    overrides: [
      relaySessionProvider.overrideWith(() => session),
      relayConfigProvider.overrideWith(_FakeRelayConfigNotifier.new),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

class _FakeRelaySession extends RelaySessionNotifier {
  _FakeRelaySession({
    this.answerStatus,
    this.answerRequestId,
    this.queryResult = const [],
    this.queryError,
  });

  final String? answerStatus;
  final String? answerRequestId;
  final List<NostrEvent> queryResult;
  final Object? queryError;
  final List<NostrEvent> published = [];
  final List<List<NostrFilter>> queries = [];
  final List<void Function(NostrEvent)> _listeners = [];

  @override
  SessionState build() => const SessionState(status: SessionStatus.connected);

  @override
  Future<void Function()> subscribe(
    NostrFilter filter,
    void Function(NostrEvent) onEvent, {
    void Function(String message)? onClosed,
  }) async {
    _listeners.add(onEvent);
    return () => _listeners.remove(onEvent);
  }

  Map<String, Object?> decrypt(NostrEvent event) {
    final key = getConversationKey(_agent.secret, _owner.public);
    return (jsonDecode(nip44Decrypt(key, event.content)) as Map)
        .cast<String, Object?>();
  }

  @override
  Future<NostrEvent> publish(
    NostrEvent event, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    published.add(event);
    final status = answerStatus;
    if (status != null) {
      final requestId =
          answerRequestId ?? decrypt(event)['requestId']! as String;
      scheduleMicrotask(() {
        for (final listener in List.of(_listeners)) {
          listener(_controlResult(requestId, status));
        }
      });
    }
    return event;
  }

  @override
  Future<List<NostrEvent>> queryRelay(
    List<NostrFilter> filters, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    queries.add(filters);
    final error = queryError;
    if (error != null) throw error;
    return queryResult;
  }
}

class _FakeRelayConfigNotifier extends RelayConfigNotifier {
  @override
  RelayConfig build() => RelayConfig(
    baseUrl: 'http://localhost:3000',
    nsec: nostr.Nip19.encode(
      prefix: nostr.Nip19Prefix.nsec,
      data: _owner.secret,
    ),
  );
}
