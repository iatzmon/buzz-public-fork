import 'package:buzz/features/channels/agent_activity/observer_models.dart';
import 'package:buzz/features/channels/agent_activity/sessions/active_turns.dart';
import 'package:flutter_test/flutter_test.dart';

const _agent = 'a1';
final _t0 = DateTime.utc(2026, 9, 27, 12);

ObserverFrame _frame(
  int seq,
  String kind, {
  String? turnId,
  String? channelId = 'c1',
  String? sessionId,
  String? startedAt,
  Object? payload,
  Duration at = Duration.zero,
}) => ObserverFrame(
  seq: seq,
  timestamp: _t0.add(at).toIso8601String(),
  kind: kind,
  channelId: channelId,
  sessionId: sessionId,
  turnId: turnId,
  startedAt: startedAt,
  payload: payload,
);

List<ActiveTurn> _derive(List<ObserverFrame> frames) =>
    deriveActiveTurns({_agent: frames});

void main() {
  test('keeps sibling turns in one channel as separate rows', () {
    final turns = _derive([
      _frame(1, 'turn_started', turnId: 't1', sessionId: 's1'),
      _frame(
        2,
        'turn_started',
        turnId: 't2',
        sessionId: 's2',
        at: const Duration(seconds: 1),
      ),
    ]);
    expect(turns.map((t) => (t.turnId, t.channelId, t.sessionId)), [
      ('t1', 'c1', 's1'),
      ('t2', 'c1', 's2'),
    ]);
  });

  test('reads exact-turn Stop support only from an explicit flag', () {
    final turns = _derive([
      _frame(
        1,
        'turn_started',
        turnId: 't1',
        payload: {'cancelByTurnId': true},
      ),
      _frame(
        2,
        'turn_started',
        turnId: 't2',
        payload: {'cancelByTurnId': 'yes'},
      ),
      _frame(3, 'turn_started', turnId: 't3'),
    ]);
    expect(turns.map((t) => t.cancelByTurnId), [true, false, false]);
  });

  test('liveness refreshes a turn and learns its session and Stop support', () {
    final turns = _derive([
      _frame(1, 'turn_started', turnId: 't1'),
      _frame(
        2,
        'turn_liveness',
        turnId: 't1',
        sessionId: 's1',
        payload: {'cancelByTurnId': true},
        at: const Duration(seconds: 40),
      ),
    ]);
    expect(turns, hasLength(1));
    expect(turns.single.sessionId, 's1');
    expect(turns.single.cancelByTurnId, isTrue);
    expect(turns.single.startedAt, _t0);
  });

  test('ending frames remove a turn, by turn id or by channel', () {
    final turns = _derive([
      _frame(1, 'turn_started', turnId: 't1'),
      _frame(2, 'turn_started', turnId: 't2', channelId: 'c2'),
      _frame(3, 'turn_started', turnId: 't3', channelId: 'c3'),
      _frame(4, 'turn_completed', turnId: 't1'),
      _frame(5, 'turn_error', channelId: 'c2'),
    ]);
    expect(turns.map((t) => t.turnId), ['t3']);
  });

  test(
    'liveness recreates a turn whose start was not seen, from startedAt',
    () {
      final started = _t0.subtract(const Duration(minutes: 5));
      final turns = _derive([
        _frame(
          1,
          'turn_liveness',
          turnId: 't1',
          startedAt: started.toIso8601String(),
        ),
      ]);
      expect(turns.single.startedAt, started);
    },
  );

  test('a start claimed after the frame falls back to the frame time', () {
    final turns = _derive([
      _frame(
        1,
        'turn_liveness',
        turnId: 't1',
        startedAt: _t0.add(const Duration(hours: 1)).toIso8601String(),
      ),
    ]);
    expect(turns.single.startedAt, _t0);
  });

  test('a stale liveness frame does not revive a completed turn', () {
    final turns = _derive([
      _frame(1, 'turn_started', turnId: 't1'),
      _frame(2, 'turn_completed', turnId: 't1', at: const Duration(seconds: 5)),
      _frame(3, 'turn_liveness', turnId: 't1', at: const Duration(seconds: 5)),
    ]);
    expect(turns, isEmpty);
  });

  test('keeps a turn with no recent frame and marks it quiet', () {
    final turn = _derive([_frame(1, 'turn_started', turnId: 't1')]).single;
    expect(turn.isQuietAt(_t0.add(activeTurnStaleAfter)), isFalse);
    expect(
      turn.isQuietAt(
        _t0.add(activeTurnStaleAfter + const Duration(seconds: 1)),
      ),
      isTrue,
    );
  });

  test('keeps the messages that started a turn, in order', () {
    final turns = _derive([
      _frame(
        1,
        'turn_started',
        turnId: 't1',
        payload: {
          'triggeringEventIds': ['e1', '', 7, 'e2'],
        },
      ),
      _frame(2, 'turn_liveness', turnId: 't1', at: const Duration(seconds: 10)),
      _frame(3, 'turn_liveness', turnId: 't2'),
    ]);
    expect(turns.map((t) => t.triggeringEventIds), [
      ['e1', 'e2'],
      isEmpty,
    ]);
  });

  test('stream activity keeps a turn from going quiet', () {
    final turns = _derive([
      _frame(1, 'turn_started', turnId: 't1'),
      _frame(2, 'acp_write', turnId: 't1', at: const Duration(seconds: 50)),
    ]);
    expect(
      turns.single.isQuietAt(_t0.add(const Duration(seconds: 60))),
      isFalse,
    );
  });

  test(
    'a late start frame fills in the request of a turn seen by liveness',
    () {
      final ledger = ActiveTurnLedger(_agent)
        ..apply(
          _frame(
            2,
            'turn_liveness',
            turnId: 't1',
            at: const Duration(seconds: 10),
          ),
        )
        ..apply(
          _frame(
            1,
            'turn_started',
            turnId: 't1',
            payload: {
              'triggeringEventIds': ['e1'],
            },
          ),
        );
      final turn = ledger.turns.single;
      expect(turn.triggeringEventIds, ['e1']);
      expect(turn.startedAt, _t0);
      expect(turn.lastSeenAt, _t0.add(const Duration(seconds: 10)));
    },
  );

  test('a late start frame does not revive a turn that ended after it', () {
    final ledger = ActiveTurnLedger(_agent)
      ..apply(
        _frame(
          2,
          'turn_completed',
          turnId: 't1',
          at: const Duration(seconds: 5),
        ),
      )
      ..apply(_frame(1, 'turn_started', turnId: 't1'));
    expect(ledger.turns, isEmpty);
  });

  test('counts turns dropped for the per-agent limit', () {
    final ledger = ActiveTurnLedger(_agent);
    for (var i = 0; i <= maxActiveTurnsPerAgent; i++) {
      ledger.apply(
        _frame(
          i,
          'turn_started',
          turnId: 't$i',
          at: Duration(seconds: i),
        ),
      );
    }
    expect(ledger.turns, hasLength(maxActiveTurnsPerAgent));
    expect(ledger.turns.map((t) => t.turnId), isNot(contains('t0')));
    expect(ledger.droppedTurnCount, 1);
  });
}
