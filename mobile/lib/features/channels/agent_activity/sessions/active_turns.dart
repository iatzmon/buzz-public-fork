import 'package:flutter/foundation.dart';

import '../observer_models.dart';

/// A turn with no frame for this long has lost its signal. The harness sends
/// `turn_liveness` about every 10 s; the margin also absorbs clock skew
/// between the agent host and this device. A lost signal does not prove the
/// turn ended, so such a turn stays listed and is shown as quiet.
const activeTurnStaleAfter = Duration(seconds: 45);

/// One agent turn that has started and has not reported an end.
@immutable
class ActiveTurn {
  final String agentPubkey;
  final String turnId;
  final String channelId;

  /// ACP session id; known once the harness resolves the session.
  final String? sessionId;

  /// Start of the turn, on the agent host's clock.
  final DateTime startedAt;

  /// Time of the newest frame for this turn, on the agent host's clock.
  final DateTime lastSeenAt;

  /// The runtime honors `cancel_turn` with this exact `turnId`.
  final bool cancelByTurnId;

  /// Channel messages that started this turn, oldest first, from
  /// `turn_started`. Empty when only liveness was seen (the app connected
  /// mid-turn), because liveness does not carry them.
  final List<String> triggeringEventIds;

  const ActiveTurn({
    required this.agentPubkey,
    required this.turnId,
    required this.channelId,
    required this.sessionId,
    required this.startedAt,
    required this.lastSeenAt,
    required this.cancelByTurnId,
    this.triggeringEventIds = const [],
  });

  /// No frame for this turn arrived within [activeTurnStaleAfter] of [now].
  bool isQuietAt(DateTime now) =>
      now.difference(lastSeenAt) > activeTurnStaleAfter;

  ActiveTurn copyWith({
    String? sessionId,
    DateTime? lastSeenAt,
    bool? cancelByTurnId,
  }) => ActiveTurn(
    agentPubkey: agentPubkey,
    turnId: turnId,
    channelId: channelId,
    sessionId: sessionId ?? this.sessionId,
    startedAt: startedAt,
    lastSeenAt: lastSeenAt ?? this.lastSeenAt,
    cancelByTurnId: cancelByTurnId ?? this.cancelByTurnId,
    triggeringEventIds: triggeringEventIds,
  );

  @override
  bool operator ==(Object other) =>
      other is ActiveTurn &&
      other.agentPubkey == agentPubkey &&
      other.turnId == turnId &&
      other.channelId == channelId &&
      other.sessionId == sessionId &&
      other.startedAt == startedAt &&
      other.lastSeenAt == lastSeenAt &&
      other.cancelByTurnId == cancelByTurnId &&
      listEquals(other.triggeringEventIds, triggeringEventIds);

  @override
  int get hashCode => Object.hash(
    agentPubkey,
    turnId,
    channelId,
    sessionId,
    startedAt,
    lastSeenAt,
    cancelByTurnId,
    Object.hashAll(triggeringEventIds),
  );
}

/// Most turns kept per agent. Matches the harness's upper bound for parallel
/// agent processes (`BUZZ_ACP_AGENTS` accepts 1..=32), so it only guards
/// against unbounded growth. A turn dropped for this limit is counted in
/// [ActiveTurnLedger.droppedTurnCount] so the page can say the list is
/// incomplete.
const maxActiveTurnsPerAgent = 32;

/// Most ended turn IDs remembered per agent, so a late frame cannot revive a
/// turn that already ended.
const _maxEndedTurnsPerAgent = 256;

/// Every running turn across agents, oldest first, derived from each agent's
/// time-ordered observer frames. Sibling turns in one channel stay separate.
/// Quiet turns ([ActiveTurn.isQuietAt]) are kept: only an ending frame
/// removes a turn.
List<ActiveTurn> deriveActiveTurns(
  Map<String, List<ObserverFrame>> framesByAgent,
) {
  final ledgers = <ActiveTurnLedger>[
    for (final entry in framesByAgent.entries)
      ActiveTurnLedger(entry.key)..applyAll(entry.value),
  ];
  return sortActiveTurns([for (final ledger in ledgers) ...ledger.turns]);
}

/// [turns] oldest first, ties broken by turn ID.
List<ActiveTurn> sortActiveTurns(Iterable<ActiveTurn> turns) =>
    List.unmodifiable(
      turns.toList()..sort((a, b) {
        final byStart = a.startedAt.compareTo(b.startedAt);
        return byStart != 0 ? byStart : a.turnId.compareTo(b.turnId);
      }),
    );

/// One agent's turn lifecycle, updated frame by frame as frames arrive.
///
/// It is kept apart from the observer's transcript buffer, which drops old
/// frames. So a busy sibling turn cannot push a quiet turn, or a turn's
/// request IDs, out of the list: only an ending frame removes a turn.
///
/// Mirrors desktop `activeAgentTurnsStore.ts`: `turn_started` opens a turn,
/// `turn_completed` / `turn_error` / `agent_panic` end it, and
/// `turn_liveness` refreshes it or recreates one whose start frame was not
/// seen (for example, the app opened mid-turn). A turn that ended is never
/// recreated by an older or same-time frame. Frames may arrive out of order,
/// so times only move forward and a late `turn_started` fills in what
/// liveness could not carry.
class ActiveTurnLedger {
  ActiveTurnLedger(this.agentPubkey);

  final String agentPubkey;
  final Map<String, ActiveTurn> _turns = {};
  final Map<String, DateTime> _endedAt = {};
  int _dropped = 0;

  /// This agent's turns that started and have not reported an end.
  Iterable<ActiveTurn> get turns => _turns.values;

  /// Turns removed only because of [maxActiveTurnsPerAgent], not by an
  /// ending frame.
  int get droppedTurnCount => _dropped;

  void applyAll(Iterable<ObserverFrame> frames) {
    for (final frame in frames) {
      apply(frame);
    }
  }

  /// Applies one frame. Returns whether the turn list changed.
  bool apply(ObserverFrame frame) {
    final at = DateTime.tryParse(frame.timestamp);
    if (at == null) return false;
    final turnId = frame.turnId;

    switch (frame.kind) {
      case 'turn_started':
        final channelId = frame.channelId;
        if (channelId == null) return false;
        final id = turnId ?? 'seq-${frame.seq}';
        if (_endedAfterOrAt(id, at)) return false;
        _endedAt.remove(id);
        final existing = _turns[id];
        _put(
          ActiveTurn(
            agentPubkey: agentPubkey,
            turnId: id,
            channelId: channelId,
            sessionId: existing?.sessionId ?? frame.sessionId,
            startedAt: existing == null || at.isBefore(existing.startedAt)
                ? at
                : existing.startedAt,
            lastSeenAt: _later(existing?.lastSeenAt, at),
            cancelByTurnId:
                (existing?.cancelByTurnId ?? false) || _cancelByTurnId(frame),
            triggeringEventIds: _triggeringEventIds(frame),
          ),
        );
        return true;
      case 'turn_completed' || 'turn_error' || 'agent_panic':
        final String? id;
        if (turnId != null) {
          id = turnId;
        } else if (frame.channelId != null) {
          id = _turns.values
              .where(
                (turn) =>
                    turn.channelId == frame.channelId &&
                    !turn.startedAt.isAfter(at),
              )
              .firstOrNull
              ?.turnId;
        } else {
          id = null;
        }
        if (id == null) return false;
        _endedAt[id] = _later(_endedAt.remove(id), at);
        if (_endedAt.length > _maxEndedTurnsPerAgent) {
          _endedAt.remove(_endedAt.keys.first);
        }
        return _turns.remove(id) != null;
      case 'turn_liveness':
        if (turnId == null) return false;
        final existing = _turns[turnId];
        if (existing != null) {
          _turns[turnId] = existing.copyWith(
            sessionId: frame.sessionId,
            lastSeenAt: _later(existing.lastSeenAt, at),
            cancelByTurnId: _cancelByTurnId(frame),
          );
          return true;
        }
        final channelId = frame.channelId;
        if (channelId == null || _endedAfterOrAt(turnId, at)) return false;
        final claimedStart = DateTime.tryParse(frame.startedAt ?? '');
        _put(
          ActiveTurn(
            agentPubkey: agentPubkey,
            turnId: turnId,
            channelId: channelId,
            sessionId: frame.sessionId,
            startedAt: claimedStart != null && !claimedStart.isAfter(at)
                ? claimedStart
                : at,
            lastSeenAt: at,
            cancelByTurnId: _cancelByTurnId(frame),
          ),
        );
        return true;
      default:
        // Stream activity keeps a quiet turn alive and may carry its session.
        final existing = turnId == null ? null : _turns[turnId];
        if (existing == null) return false;
        _turns[turnId!] = existing.copyWith(
          sessionId: frame.sessionId,
          lastSeenAt: _later(existing.lastSeenAt, at),
        );
        return true;
    }
  }

  bool _endedAfterOrAt(String turnId, DateTime at) {
    final ended = _endedAt[turnId];
    return ended != null && !at.isAfter(ended);
  }

  void _put(ActiveTurn turn) {
    _turns[turn.turnId] = turn;
    while (_turns.length > maxActiveTurnsPerAgent) {
      final oldest = _turns.values.reduce(
        (a, b) => b.lastSeenAt.isBefore(a.lastSeenAt) ? b : a,
      );
      _turns.remove(oldest.turnId);
      _dropped += 1;
    }
  }
}

DateTime _later(DateTime? a, DateTime b) => a == null || b.isAfter(a) ? b : a;

List<String> _triggeringEventIds(ObserverFrame frame) {
  final payload = frame.payload;
  final ids = payload is Map ? payload['triggeringEventIds'] : null;
  if (ids is! List) return const [];
  return List.unmodifiable(
    ids.whereType<String>().where((id) => id.isNotEmpty),
  );
}

bool _cancelByTurnId(ObserverFrame frame) {
  final payload = frame.payload;
  return payload is Map && payload['cancelByTurnId'] == true;
}
