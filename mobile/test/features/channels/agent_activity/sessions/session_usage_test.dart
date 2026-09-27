import 'package:buzz/features/channels/agent_activity/sessions/session_usage.dart';
import 'package:flutter_test/flutter_test.dart';

TurnMetric _metric(
  String session,
  int seq, {
  int? turnTotal,
  int? cumulativeTotal,
  int? turnInput,
  int? turnOutput,
  double? turnCost,
  bool deltaReliable = true,
}) => TurnMetric(
  sessionId: session,
  turnSeq: seq,
  totalTokens: UsageCounter(turn: turnTotal, cumulative: cumulativeTotal),
  inputTokens: UsageCounter(turn: turnInput),
  outputTokens: UsageCounter(turn: turnOutput),
  costUsd: UsageCounter(turn: turnCost),
  deltaReliable: deltaReliable,
);

void main() {
  group('sumSessionUsage', () {
    test('diffs cumulative counters within a session, like desktop', () {
      // s1: first turn has no baseline (turn value 30), second diffs 450-300.
      final usage = sumSessionUsage([
        _metric('s1', 1, turnTotal: 30, cumulativeTotal: 300),
        _metric('s1', 2, turnTotal: 999, cumulativeTotal: 450),
        _metric('s2', 1, turnTotal: 900, cumulativeTotal: 900),
      ]);
      expect(usage['s1']!.totalTokens, const UsageTotal<int>(180));
      expect(usage['s2']!.totalTokens, const UsageTotal<int>(900));
    });

    test('a decreasing counter makes that turn unknown, not negative', () {
      final usage = sumSessionUsage([
        _metric('s1', 1, turnTotal: 100, cumulativeTotal: 500),
        _metric('s1', 2, turnTotal: 40, cumulativeTotal: 200),
      ]);
      expect(
        usage['s1']!.totalTokens,
        const UsageTotal<int>(100, incomplete: true),
      );
    });

    test('an unreliable delta without a baseline is unknown', () {
      final usage = sumSessionUsage([
        _metric('s1', 5, turnTotal: 70, deltaReliable: false),
        _metric('s1', 7, turnTotal: 20),
      ]);
      expect(
        usage['s1']!.totalTokens,
        const UsageTotal<int>(20, incomplete: true),
      );
    });

    test('keeps the first report for a duplicate turnSeq', () {
      final usage = sumSessionUsage([
        _metric('s1', 1, turnTotal: 10),
        _metric('s1', 1, turnTotal: 99),
      ]);
      expect(usage['s1']!.totalTokens, const UsageTotal<int>(10));
    });

    test('sums input, output, and cost independently of the total', () {
      final usage = sumSessionUsage([
        _metric('s1', 1, turnInput: 1000, turnOutput: 100, turnCost: 0.25),
        _metric('s1', 2, turnInput: 200, turnOutput: 200, turnCost: 0.25),
      ])['s1']!;
      expect(usage.totalTokens, const UsageTotal<int>(null));
      expect(usage.inputTokens, const UsageTotal<int>(1200));
      expect(usage.outputTokens, const UsageTotal<int>(300));
      expect(usage.costUsd, const UsageTotal<double>(0.5));
    });
  });

  group('TurnMetric.fromJson', () {
    test('reads counters and rejects negative or wrong-typed values', () {
      final metric = TurnMetric.fromJson({
        'sessionId': 's1',
        'turnSeq': 3,
        'turn': {'inputTokens': 5, 'outputTokens': -1, 'costUsd': 0.1},
        'cumulative': {'totalTokens': '10'},
        'deltaReliable': false,
      })!;
      expect(metric.inputTokens.turn, 5);
      expect(metric.outputTokens.turn, isNull);
      expect(metric.totalTokens.cumulative, isNull);
      expect(metric.costUsd.turn, 0.1);
      expect(metric.deltaReliable, isFalse);
    });

    test('needs a session id and turnSeq', () {
      expect(TurnMetric.fromJson({'turnSeq': 1}), isNull);
      expect(TurnMetric.fromJson({'sessionId': 's1'}), isNull);
    });
  });

  group('formatSessionUsage', () {
    SessionUsage usage({
      int? total,
      int? input,
      int? output,
      double? cost,
      bool totalIncomplete = false,
      bool costIncomplete = false,
    }) => SessionUsage(
      totalTokens: UsageTotal(total, incomplete: totalIncomplete),
      inputTokens: UsageTotal(input),
      outputTokens: UsageTotal(output),
      costUsd: UsageTotal(cost, incomplete: costIncomplete),
    );

    test('shows the total and cost', () {
      expect(
        formatSessionUsage(usage(total: 1500, cost: 0.12)),
        '1.5k tokens · \$0.12',
      );
    });

    test('shows input and output when no total is reported', () {
      expect(
        formatSessionUsage(usage(input: 1200, output: 300, cost: 0.5)),
        '1.2k in · 300 out · \$0.50',
      );
    });

    test('shows cost alone when no token field is known', () {
      expect(formatSessionUsage(usage(cost: 0.5)), '\$0.50');
    });

    test('marks lower bounds', () {
      expect(
        formatSessionUsage(
          usage(
            total: 2000,
            cost: 1,
            totalIncomplete: true,
            costIncomplete: true,
          ),
        ),
        '≥ 2.0k tokens · ≥ \$1.00',
      );
    });

    test('returns null when nothing is known', () {
      expect(formatSessionUsage(null), isNull);
      expect(formatSessionUsage(usage()), isNull);
    });

    test('compacts token counts', () {
      expect(formatTokenCount(999), '999');
      expect(formatTokenCount(250000), '250k');
      expect(formatTokenCount(1200000), '1.2M');
    });
  });
}
