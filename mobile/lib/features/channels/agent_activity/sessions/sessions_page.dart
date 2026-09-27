import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../shared/profile/user_cache_provider.dart';
import '../../../../shared/theme/theme.dart';
import '../../../../shared/widgets/frosted_app_bar.dart';
import '../../../../shared/widgets/frosted_scaffold.dart';
import '../../channels_provider.dart';
import 'active_turns.dart';
import 'session_usage.dart';
import 'sessions_providers.dart';

part 'sessions_page/session_row.dart';

/// Every agent turn running now across the owner's agents, one row per turn,
/// with run time, tokens so far, and Stop.
class SessionsPage extends ConsumerWidget {
  const SessionsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final turns = ref.watch(activeTurnsProvider);
    final now = ref.watch(sessionsClockProvider).value ?? DateTime.now();
    final channels = ref.watch(channelsProvider).value ?? const [];
    final channelNames = {
      for (final channel in channels) channel.id: channel.name,
    };

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
            style: context.textTheme.bodySmall?.copyWith(
              color: context.colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: Grid.xs),
          if (turns.isEmpty)
            Padding(
              key: const Key('sessions-empty'),
              padding: const EdgeInsets.symmetric(vertical: Grid.md),
              child: Text(
                'No agent is working right now.',
                textAlign: TextAlign.center,
                style: context.textTheme.bodyMedium?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
            )
          else
            for (final turn in turns)
              _SessionRow(
                key: ValueKey('session-row-${turn.agentPubkey}-${turn.turnId}'),
                turn: turn,
                channelName: channelNames[turn.channelId],
                now: now,
              ),
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
