import 'package:buzz/features/channels/agent_activity/sessions/active_turns.dart';
import 'package:buzz/features/channels/agent_activity/sessions/session_usage.dart';
import 'package:buzz/features/channels/agent_activity/sessions/sessions_page.dart';
import 'package:buzz/features/channels/agent_activity/sessions/sessions_providers.dart';
import 'package:buzz/features/channels/channel.dart';
import 'package:buzz/features/channels/channels_provider.dart';
import 'package:buzz/features/channels/notification_destination.dart';
import 'package:buzz/shared/relay/relay.dart';
import 'package:buzz/shared/profile/user_cache_provider.dart';
import 'package:buzz/shared/profile/user_profile.dart';
import 'package:buzz/shared/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

const _agentA =
    'aaaa000000000000000000000000000000000000000000000000000000000000';
const _agentB =
    'bbbb000000000000000000000000000000000000000000000000000000000000';
final _now = DateTime.utc(2026, 9, 27, 12);

ActiveTurn _turn(
  String agent,
  String turnId, {
  String? sessionId,
  bool cancelByTurnId = true,
  List<String> triggeringEventIds = const [],
  Duration quietFor = Duration.zero,
}) => ActiveTurn(
  agentPubkey: agent,
  turnId: turnId,
  channelId: 'chan-1',
  sessionId: sessionId,
  startedAt: _now.subtract(const Duration(minutes: 3, seconds: 5)),
  lastSeenAt: _now.subtract(quietFor),
  cancelByTurnId: cancelByTurnId,
  triggeringEventIds: triggeringEventIds,
);

NostrEvent _message(String id, String content, {String? threadRoot}) =>
    NostrEvent(
      id: id,
      pubkey: 'cccc',
      createdAt: 0,
      kind: 9,
      tags: [
        ['h', 'chan-1'],
        if (threadRoot != null) ...[
          ['e', threadRoot, '', 'root'],
          ['e', threadRoot, '', 'reply'],
        ],
      ],
      content: content,
      sig: '',
    );

Channel _channel() => Channel(
  id: 'chan-1',
  name: 'buzz',
  channelType: 'stream',
  visibility: 'open',
  description: '',
  createdBy: 'x',
  createdAt: DateTime(2025),
  memberCount: 2,
  isMember: true,
);

Future<List<ActiveTurn>> _pump(
  WidgetTester tester, {
  required List<ActiveTurn> turns,
  Map<String, AsyncValue<Map<String, SessionUsage>>> usage = const {},
  StopOutcome stopOutcome = StopOutcome.sent,
  SessionsStatus status = (
    discovery: SessionsDiscovery.listening,
    errorMessage: null,
    droppedTurnCount: 0,
  ),
  Map<String, String> activity = const {},
  Map<String, NostrEvent> messages = const {},
}) async {
  final stopped = <ActiveTurn>[];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        activeTurnsProvider.overrideWithValue(turns),
        sessionsStatusProvider.overrideWithValue(status),
        turnActivityProvider.overrideWith((ref, key) => activity[key.turnId]),
        notificationEventProvider.overrideWith((ref, target) async {
          final message = messages[target.eventId];
          if (message == null) throw StateError('missing');
          return message;
        }),
        sessionsClockProvider.overrideWithValue(AsyncData(_now)),
        channelsProvider.overrideWith(() => _FakeChannels([_channel()])),
        userCacheProvider.overrideWith(
          () => _FakeUserCache({
            _agentA: const UserProfile(pubkey: _agentA, displayName: 'Forge'),
            _agentB: const UserProfile(pubkey: _agentB, displayName: 'Cube'),
          }),
        ),
        agentSessionUsageProvider.overrideWith((ref, agent) {
          final value = usage[agent] ?? const AsyncData({});
          return switch (value) {
            AsyncData(:final value) => value,
            AsyncError(:final error) => throw error,
            _ => Future.any([]),
          };
        }),
        stopTurnProvider.overrideWithValue((turn) async {
          stopped.add(turn);
          return stopOutcome;
        }),
      ],
      child: MaterialApp(theme: AppTheme.light(), home: const SessionsPage()),
    ),
  );
  await tester.pumpAndSettle();
  return stopped;
}

Finder _inRow(String agent, String turnId, Finder finder) => find.descendant(
  of: find.byKey(ValueKey('session-row-$agent-$turnId')),
  matching: finder,
);

void main() {
  testWidgets('shows an empty state only once the page is listening', (
    tester,
  ) async {
    await _pump(tester, turns: const []);
    expect(find.byKey(const Key('sessions-empty')), findsOneWidget);
    expect(find.byKey(const Key('sessions-status')), findsNothing);
  });

  for (final (discovery, text) in [
    (SessionsDiscovery.notConnected, 'Not connected.'),
    (SessionsDiscovery.connecting, 'Connecting to agent activity'),
    (SessionsDiscovery.unavailable, 'Agent activity is unavailable (offline)'),
    (SessionsDiscovery.discovering, 'Looking for running turns.'),
  ]) {
    testWidgets('never claims no agent is working while ${discovery.name}', (
      tester,
    ) async {
      await _pump(
        tester,
        turns: const [],
        status: (
          discovery: discovery,
          errorMessage: 'offline',
          droppedTurnCount: 0,
        ),
      );
      expect(find.byKey(const Key('sessions-empty')), findsNothing);
      expect(find.textContaining(text), findsOneWidget);
    });
  }

  testWidgets('says when turns were dropped for the per-agent limit', (
    tester,
  ) async {
    await _pump(
      tester,
      turns: [_turn(_agentA, 't1')],
      status: (
        discovery: SessionsDiscovery.listening,
        errorMessage: null,
        droppedTurnCount: 2,
      ),
    );
    expect(
      find.textContaining('2 older turns were dropped from this list'),
      findsOneWidget,
    );
  });

  testWidgets('keeps a quiet turn listed apart, not as ended', (tester) async {
    await _pump(
      tester,
      turns: [
        _turn(_agentA, 't1'),
        _turn(_agentA, 't2', quietFor: const Duration(minutes: 2)),
      ],
    );
    expect(find.byKey(const Key('sessions-quiet-header')), findsOneWidget);
    expect(
      _inRow(_agentA, 't1', find.byKey(const Key('session-row-quiet'))),
      findsNothing,
    );
    expect(
      _inRow(_agentA, 't2', find.text('No signal for 2m 0s')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('sessions-empty')), findsNothing);
  });

  testWidgets('tells two runs of one agent in one channel apart', (
    tester,
  ) async {
    await _pump(
      tester,
      turns: [
        _turn(_agentA, 't1', triggeringEventIds: ['e1']),
        _turn(_agentA, 't2', triggeringEventIds: ['e0', 'e2']),
        _turn(_agentA, 't3'),
      ],
      activity: {'t1': 'Read file'},
      messages: {
        'e1': _message('e1', 'Fix the\n login   bug'),
        'e2': _message('e2', 'Write the release notes', threadRoot: 'r1'),
      },
    );

    expect(
      _inRow(_agentA, 't1', find.text('Request: "Fix the login bug"')),
      findsOneWidget,
    );
    expect(
      _inRow(
        _agentA,
        't2',
        find.text('Request (in a thread): "Write the release notes"'),
      ),
      findsOneWidget,
    );
    expect(_inRow(_agentA, 't1', find.text('Read file')), findsOneWidget);
    expect(
      _inRow(_agentA, 't1', find.byKey(const Key('session-row-open'))),
      findsOneWidget,
    );
    expect(
      _inRow(
        _agentA,
        't3',
        find.text(
          'Request not known: this turn started before the app connected.',
        ),
      ),
      findsOneWidget,
    );
    expect(
      _inRow(_agentA, 't3', find.byKey(const Key('session-row-open'))),
      findsNothing,
    );
  });

  testWidgets('Open shows the conversation that started the turn', (
    tester,
  ) async {
    // The request fails to load here, so the destination stops at its own
    // error screen instead of building the full channel page.
    await _pump(
      tester,
      turns: [
        _turn(_agentA, 't1', triggeringEventIds: ['e1']),
      ],
    );
    expect(
      _inRow(_agentA, 't1', find.text('Request could not be loaded.')),
      findsOneWidget,
    );
    await tester.tap(
      _inRow(_agentA, 't1', find.byKey(const Key('session-row-open'))),
    );
    await tester.pumpAndSettle();
    final destination = tester.widget<NotificationDestination>(
      find.byType(NotificationDestination),
    );
    expect(destination.channel.id, 'chan-1');
    expect(destination.link.messageId, 'e1');
  });

  testWidgets('a Stop with no running turn does not claim it ended', (
    tester,
  ) async {
    await _pump(
      tester,
      turns: [_turn(_agentA, 't1')],
      stopOutcome: StopOutcome.noActiveTurn,
    );
    await tester.tap(
      _inRow(_agentA, 't1', find.byKey(const Key('session-row-stop'))),
    );
    await tester.pump();
    expect(find.textContaining('already ended'), findsNothing);
    expect(
      find.text(
        'Forge has no running turn with this ID. It may have ended, or an '
        'earlier Stop may still be finishing.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('lists each turn with run time and session usage', (
    tester,
  ) async {
    await _pump(
      tester,
      turns: [
        _turn(_agentA, 't1', sessionId: 's1'),
        _turn(_agentA, 't2', sessionId: 's2'),
      ],
      usage: {
        _agentA: const AsyncData({
          's1': SessionUsage(
            inputTokens: UsageTotal(1200),
            outputTokens: UsageTotal(300),
            totalTokens: UsageTotal(null),
            costUsd: UsageTotal(0.5),
          ),
        }),
      },
    );

    expect(_inRow(_agentA, 't1', find.text('Forge in #buzz')), findsOneWidget);
    expect(
      _inRow(_agentA, 't1', find.text('Running for 3m 5s')),
      findsOneWidget,
    );
    expect(
      _inRow(_agentA, 't1', find.text('1.2k in · 300 out · \$0.50')),
      findsOneWidget,
    );
    expect(
      _inRow(_agentA, 't2', find.text('No usage reported yet')),
      findsOneWidget,
    );
  });

  testWidgets('a failed usage read shows as unavailable', (tester) async {
    await _pump(
      tester,
      turns: [_turn(_agentB, 't1', sessionId: 's1')],
      usage: {_agentB: AsyncError(StateError('offline'), StackTrace.empty)},
    );
    expect(
      _inRow(_agentB, 't1', find.text('Usage unavailable')),
      findsOneWidget,
    );
  });

  testWidgets('Stop sends this exact turn and shows Stopping', (tester) async {
    final turn = _turn(_agentA, 't1');
    final stopped = await _pump(tester, turns: [turn]);

    await tester.tap(
      _inRow(_agentA, 't1', find.byKey(const Key('session-row-stop'))),
    );
    await tester.pump();

    expect(stopped, [turn]);
    expect(_inRow(_agentA, 't1', find.text('Stopping…')), findsOneWidget);
    expect(find.text('Stop signal sent to Forge.'), findsOneWidget);
  });

  testWidgets('Stop is disabled and explained without exact-turn support', (
    tester,
  ) async {
    final stopped = await _pump(
      tester,
      turns: [_turn(_agentB, 't1', cancelByTurnId: false)],
    );

    final stop = tester.widget<ButtonStyleButton>(
      _inRow(_agentB, 't1', find.byKey(const Key('session-row-stop'))),
    );
    expect(stop.onPressed, isNull);
    expect(
      _inRow(
        _agentB,
        't1',
        find.text('Update Cube to stop a single turn from here.'),
      ),
      findsOneWidget,
    );
    await tester.tap(
      _inRow(_agentB, 't1', find.byKey(const Key('session-row-stop'))),
      warnIfMissed: false,
    );
    expect(stopped, isEmpty);
  });
}

class _FakeChannels extends ChannelsNotifier {
  _FakeChannels(this.channels);

  final List<Channel> channels;

  @override
  Future<List<Channel>> build() async => channels;
}

class _FakeUserCache extends UserCacheNotifier {
  _FakeUserCache(this.users);

  final Map<String, UserProfile> users;

  @override
  Map<String, UserProfile> build() => users;
}
