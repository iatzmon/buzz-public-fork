import 'package:flutter/foundation.dart';

import '../observer_models.dart';

/// A turn with no frame for this long is treated as ended. The harness sends
/// `turn_liveness` about every 10 s; the margin also absorbs clock skew
/// between the agent host and this device.
const activeTurnStaleAfter = Duration(seconds: 45);

/// One agent turn that is running now.
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

  const ActiveTurn({
    required this.agentPubkey,
    required this.turnId,
    required this.channelId,
    required this.sessionId,
    required this.startedAt,
    required this.lastSeenAt,
    required this.cancelByTurnId,
  });

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
      other.cancelByTurnId == cancelByTurnId;

  @override
  int get hashCode => Object.hash(
    agentPubkey,
    turnId,
    channelId,
    sessionId,
    startedAt,
    lastSeenAt,
    cancelByTurnId,
  );
}

/// Every running turn across agents, oldest first, derived from each agent's
/// time-ordered observer frames. Sibling turns in one channel stay separate.
///
/// Mirrors desktop `activeAgentTurnsStore.ts`: `turn_started` opens a turn,
/// `turn_completed` / `turn_error` / `agent_panic` end it, and
/// `turn_liveness` refreshes it or recreates one whose start frame was not
/// seen (for example, the app opened mid-turn). A turn that ended is never
/// recreated by an older or same-time frame.
List<ActiveTurn> deriveActiveTurns(
  Map<String, List<ObserverFrame>> framesByAgent,
  DateTime now,
) {
  final result = <ActiveTurn>[];
  for (final entry in framesByAgent.entries) {
    final turns = _foldAgentFrames(entry.key, entry.value);
    for (final turn in turns) {
      if (now.difference(turn.lastSeenAt) <= activeTurnStaleAfter) {
        result.add(turn);
      }
    }
  }
  result.sort((a, b) {
    final byStart = a.startedAt.compareTo(b.startedAt);
    return byStart != 0 ? byStart : a.turnId.compareTo(b.turnId);
  });
  return result;
}

Iterable<ActiveTurn> _foldAgentFrames(
  String agentPubkey,
  List<ObserverFrame> frames,
) {
  final turns = <String, ActiveTurn>{};
  final endedAt = <String, DateTime>{};

  for (final frame in frames) {
    final at = DateTime.tryParse(frame.timestamp);
    if (at == null) continue;
    final turnId = frame.turnId;

    switch (frame.kind) {
      case 'turn_started':
        final channelId = frame.channelId;
        if (channelId == null) break;
        final id = turnId ?? 'seq-${frame.seq}';
        endedAt.remove(id);
        turns[id] = ActiveTurn(
          agentPubkey: agentPubkey,
          turnId: id,
          channelId: channelId,
          sessionId: frame.sessionId,
          startedAt: at,
          lastSeenAt: at,
          cancelByTurnId: _cancelByTurnId(frame),
        );
      case 'turn_completed' || 'turn_error' || 'agent_panic':
        if (turnId != null) {
          turns.remove(turnId);
          endedAt[turnId] = at;
        } else if (frame.channelId != null) {
          final match = turns.values
              .where((turn) => turn.channelId == frame.channelId)
              .firstOrNull;
          if (match != null) {
            turns.remove(match.turnId);
            endedAt[match.turnId] = at;
          }
        }
      case 'turn_liveness':
        if (turnId == null) break;
        final existing = turns[turnId];
        if (existing != null) {
          turns[turnId] = existing.copyWith(
            sessionId: frame.sessionId,
            lastSeenAt: at,
            cancelByTurnId: _cancelByTurnId(frame),
          );
          break;
        }
        final channelId = frame.channelId;
        final ended = endedAt[turnId];
        if (channelId == null || (ended != null && !at.isAfter(ended))) {
          break;
        }
        final claimedStart = DateTime.tryParse(frame.startedAt ?? '');
        turns[turnId] = ActiveTurn(
          agentPubkey: agentPubkey,
          turnId: turnId,
          channelId: channelId,
          sessionId: frame.sessionId,
          startedAt: claimedStart != null && !claimedStart.isAfter(at)
              ? claimedStart
              : at,
          lastSeenAt: at,
          cancelByTurnId: _cancelByTurnId(frame),
        );
      default:
        // Stream activity keeps a quiet turn alive and may carry its session.
        final existing = turnId == null ? null : turns[turnId];
        if (existing != null) {
          turns[turnId!] = existing.copyWith(
            sessionId: frame.sessionId,
            lastSeenAt: at,
          );
        }
    }
  }
  return turns.values;
}

bool _cancelByTurnId(ObserverFrame frame) {
  final payload = frame.payload;
  return payload is Map && payload['cancelByTurnId'] == true;
}
