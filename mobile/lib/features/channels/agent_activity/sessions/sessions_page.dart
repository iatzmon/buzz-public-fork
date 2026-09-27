import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../shared/deeplink/deep_link.dart';
import '../../../../shared/profile/user_cache_provider.dart';
import '../../../../shared/theme/theme.dart';
import '../../../../shared/widgets/frosted_app_bar.dart';
import '../../../../shared/widgets/frosted_scaffold.dart';
import '../../channel.dart';
import '../../channels_provider.dart';
import '../../notification_destination.dart';
import 'active_turns.dart';
import 'session_usage.dart';
import 'sessions_providers.dart';

part 'sessions_page/session_row.dart';
part 'sessions_page/sessions_status_banner.dart';

/// Every agent turn running now across the owner's agents, one row per turn,
/// with run time, current activity, the request that started it, tokens so
/// far, and Stop. Turns that lost their signal are listed apart as quiet;
/// only an ending frame removes a turn.
class SessionsPage extends ConsumerWidget {
  const SessionsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final turns = ref.watch(activeTurnsProvider);
    final status = ref.watch(sessionsStatusProvider);
    final now = ref.watch(sessionsClockProvider).value ?? DateTime.now();
    final channels = ref.watch(channelsProvider).value ?? const <Channel>[];
    final channelsById = {for (final channel in channels) channel.id: channel};
    final running = [
      for (final turn in turns)
        if (!turn.isQuietAt(now)) turn,
    ];
    final quiet = [
      for (final turn in turns)
        if (turn.isQuietAt(now)) turn,
    ];
    final muted = context.textTheme.bodySmall?.copyWith(
      color: context.colors.onSurfaceVariant,
    );

    Widget row(ActiveTurn turn) => _SessionRow(
      key: ValueKey('session-row-${turn.agentPubkey}-${turn.turnId}'),
      turn: turn,
      channel: channelsById[turn.channelId],
      now: now,
    );

    return FrostedScaffold(
      useUtilitySurfaceTheme: true,
      appBar: const FrostedAppBar(centerTitle: true, title: Text('Sessions')),
      body: ListView(
        key: const Key('sessions-page-list'),
        padding: EdgeInsets.fromLTRB(
          Grid.gutter,
          frostedAppBarHeight(context) + Grid.xs,
          Grid.gutter,
          Grid.lg,
        ),
        children: [
          Text(
            'Agent turns running now. Tokens come from the usage reports of '
            'the last 7 days; the current turn is added when it ends.',
            style: muted,
          ),
          const SizedBox(height: Grid.xs),
          _SessionsStatusBanner(status: status),
          if (turns.isEmpty && status.discovery == SessionsDiscovery.listening)
            Padding(
              key: const Key('sessions-empty'),
              padding: const EdgeInsets.symmetric(vertical: Grid.md),
              child: Text(
                'No agent has reported a running turn.',
                textAlign: TextAlign.center,
                style: context.textTheme.bodyMedium?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
            ),
          for (final turn in running) row(turn),
          if (quiet.isNotEmpty) ...[
            const SizedBox(height: Grid.xs),
            Semantics(
              header: true,
              child: Text(
                'No recent signal',
                key: const Key('sessions-quiet-header'),
                style: context.textTheme.titleSmall,
              ),
            ),
            Text(
              'These turns have not reported for over '
              '${activeTurnStaleAfter.inSeconds} seconds. They may have '
              'ended, or their agent may have lost its connection.',
              style: muted,
            ),
            const SizedBox(height: Grid.xxs),
            for (final turn in quiet) row(turn),
          ],
        ],
      ),
    );
  }
}

/// Run time as "42s", "3m 5s", or "1h 2m 3s".
String formatRunTime(Duration elapsed) {
  final seconds = elapsed.isNegative ? 0 : elapsed.inSeconds;
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  if (h > 0) return '${h}h ${m}m ${s}s';
  if (m > 0) return '${m}m ${s}s';
  return '${s}s';
}
