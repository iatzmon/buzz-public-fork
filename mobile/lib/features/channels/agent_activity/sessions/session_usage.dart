import 'package:flutter/foundation.dart';

/// One usage counter of a turn metric: this turn's value and the session's
/// cumulative value at the end of this turn. Null means not reported.
@immutable
class UsageCounter<T extends num> {
  final T? turn;
  final T? cumulative;

  const UsageCounter({this.turn, this.cumulative});
}

/// One decrypted NIP-AM turn metric (kind 44200), reduced to the fields the
/// Sessions page needs.
@immutable
class TurnMetric {
  final String sessionId;
  final int turnSeq;
  final UsageCounter<int> inputTokens;
  final UsageCounter<int> outputTokens;
  final UsageCounter<int> totalTokens;
  final UsageCounter<double> costUsd;
  final bool deltaReliable;

  const TurnMetric({
    required this.sessionId,
    required this.turnSeq,
    this.inputTokens = const UsageCounter(),
    this.outputTokens = const UsageCounter(),
    this.totalTokens = const UsageCounter(),
    this.costUsd = const UsageCounter(),
    this.deltaReliable = true,
  });

  /// Parses a decrypted payload. Returns null when it cannot be placed in a
  /// session series (no `sessionId` or `turnSeq`).
  static TurnMetric? fromJson(Map<String, dynamic> json) {
    final sessionId = json['sessionId'];
    final turnSeq = json['turnSeq'];
    if (sessionId is! String || sessionId.isEmpty || turnSeq is! int) {
      return null;
    }
    final turn = json['turn'];
    final cumulative = json['cumulative'];
    UsageCounter<int> tokens(String key) => UsageCounter(
      turn: _count(turn, key),
      cumulative: _count(cumulative, key),
    );
    return TurnMetric(
      sessionId: sessionId,
      turnSeq: turnSeq,
      inputTokens: tokens('inputTokens'),
      outputTokens: tokens('outputTokens'),
      totalTokens: tokens('totalTokens'),
      costUsd: UsageCounter(
        turn: _cost(turn, 'costUsd'),
        cumulative: _cost(cumulative, 'costUsd'),
      ),
      deltaReliable: json['deltaReliable'] != false,
    );
  }

  static int? _count(Object? object, String key) {
    final value = object is Map ? object[key] : null;
    return value is int && value >= 0 ? value : null;
  }

  static double? _cost(Object? object, String key) {
    final value = object is Map ? object[key] : null;
    return value is num && value.isFinite && value >= 0
        ? value.toDouble()
        : null;
  }
}

/// A summed usage field. [value] is null when no turn reported it;
/// [incomplete] means some turn's value was unknown, so [value] is a lower
/// bound.
@immutable
class UsageTotal<T extends num> {
  final T? value;
  final bool incomplete;

  const UsageTotal(this.value, {this.incomplete = false});

  @override
  bool operator ==(Object other) =>
      other is UsageTotal<T> &&
      other.value == value &&
      other.incomplete == incomplete;

  @override
  int get hashCode => Object.hash(value, incomplete);

  @override
  String toString() => 'UsageTotal($value, incomplete: $incomplete)';
}

/// Tokens and cost from the available usage reports of one session.
@immutable
class SessionUsage {
  final UsageTotal<int> inputTokens;
  final UsageTotal<int> outputTokens;
  final UsageTotal<int> totalTokens;
  final UsageTotal<double> costUsd;

  const SessionUsage({
    required this.inputTokens,
    required this.outputTokens,
    required this.totalTokens,
    required this.costUsd,
  });

  @override
  bool operator ==(Object other) =>
      other is SessionUsage &&
      other.inputTokens == inputTokens &&
      other.outputTokens == outputTokens &&
      other.totalTokens == totalTokens &&
      other.costUsd == costUsd;

  @override
  int get hashCode =>
      Object.hash(inputTokens, outputTokens, totalTokens, costUsd);
}

/// Sums each session's per-turn usage, keyed by session id.
///
/// Follows NIP-AM: within one session, a turn's usage is the difference from
/// the previous turn's cumulative counter when that turn is present;
/// otherwise the reported `turn` value, unless `deltaReliable` is false. A
/// decreasing counter or a missing value makes that turn unknown, and the
/// field is marked incomplete rather than counting it as zero. Duplicate
/// `turnSeq` values keep the first report. Only reports passed in are
/// counted; turns without a report do not appear at all.
Map<String, SessionUsage> sumSessionUsage(Iterable<TurnMetric> metrics) {
  final bySession = <String, Map<int, TurnMetric>>{};
  for (final metric in metrics) {
    bySession
        .putIfAbsent(metric.sessionId, () => {})
        .putIfAbsent(metric.turnSeq, () => metric);
  }

  return {
    for (final entry in bySession.entries) entry.key: _sumSeries(entry.value),
  };
}

SessionUsage _sumSeries(Map<int, TurnMetric> bySeq) {
  final seqs = bySeq.keys.toList()..sort();
  UsageTotal<T> sum<T extends num>(
    UsageCounter<T> Function(TurnMetric) field,
    T zero,
  ) {
    T? total;
    var missing = false;
    for (final seq in seqs) {
      final metric = bySeq[seq]!;
      final previous = bySeq[seq - 1];
      final current = field(metric).cumulative;
      final baseline = previous == null ? null : field(previous).cumulative;
      T? delta;
      if (current != null && baseline != null) {
        final difference = (current - baseline) as T;
        delta = difference >= 0 ? difference : null;
      } else if (metric.deltaReliable) {
        delta = field(metric).turn;
      }
      if (delta == null) {
        missing = true;
      } else {
        total = ((total ?? zero) + delta) as T;
      }
    }
    return UsageTotal<T>(total, incomplete: total != null && missing);
  }

  return SessionUsage(
    inputTokens: sum<int>((m) => m.inputTokens, 0),
    outputTokens: sum<int>((m) => m.outputTokens, 0),
    totalTokens: sum<int>((m) => m.totalTokens, 0),
    costUsd: sum<double>((m) => m.costUsd, 0),
  );
}

/// Compact token count ("950", "1.5k", "1.2M").
String formatTokenCount(int count) {
  if (count < 1000) return '$count';
  String trim(double value) =>
      value >= 100 ? value.round().toString() : value.toStringAsFixed(1);
  if (count < 1000000) return '${trim(count / 1000)}k';
  if (count < 1000000000) return '${trim(count / 1000000)}M';
  return '${trim(count / 1000000000)}B';
}

/// Session usage as one short line, or null when nothing is known yet.
///
/// Shows the reported total when there is one. Some harnesses (Claude Code)
/// report input and output but no total; then each known field is shown on
/// its own, never summed into an invented total. Cost is independent of the
/// token fields. An incomplete field is a lower bound ("≥").
String? formatSessionUsage(SessionUsage? usage) {
  if (usage == null) return null;
  String? tokens(UsageTotal<int> field) {
    final value = field.value;
    if (value == null) return null;
    return '${field.incomplete ? '≥ ' : ''}${formatTokenCount(value)}';
  }

  final parts = <String>[];
  final total = tokens(usage.totalTokens);
  if (total != null) {
    parts.add('$total tokens');
  } else {
    final input = tokens(usage.inputTokens);
    final output = tokens(usage.outputTokens);
    if (input != null) parts.add('$input in');
    if (output != null) parts.add('$output out');
  }
  final cost = usage.costUsd.value;
  if (cost != null) {
    final bound = usage.costUsd.incomplete ? '≥ ' : '';
    parts.add('$bound\$${cost.toStringAsFixed(2)}');
  }
  return parts.isEmpty ? null : parts.join(' · ');
}
