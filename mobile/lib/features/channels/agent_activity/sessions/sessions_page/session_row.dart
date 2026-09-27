part of '../sessions_page.dart';

class _SessionRow extends HookConsumerWidget {
  const _SessionRow({
    super.key,
    required this.turn,
    required this.channelName,
    required this.now,
  });

  final ActiveTurn turn;
  final String? channelName;
  final DateTime now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(
      userCacheProvider.select((cache) => cache[turn.agentPubkey]),
    );
    useEffect(() {
      if (profile == null) {
        Future.microtask(
          () => ref.read(userCacheProvider.notifier).get(turn.agentPubkey),
        );
      }
      return null;
    }, [turn.agentPubkey]);
    final agentName = profile?.displayName?.trim().isNotEmpty == true
        ? profile!.displayName!.trim()
        : 'Agent ${turn.agentPubkey.substring(0, 8)}';
    final channelLabel = channelName == null ? 'a channel' : '#$channelName';
    final stopping = useState(false);
    final usageText = _usageText(
      ref.watch(agentSessionUsageProvider(turn.agentPubkey)),
      turn.sessionId,
    );

    Future<void> stop() async {
      stopping.value = true;
      final messenger = ScaffoldMessenger.of(context);
      try {
        final outcome = await ref.read(stopTurnProvider)(turn);
        final message = switch (outcome) {
          StopOutcome.sent => 'Stop signal sent to $agentName.',
          StopOutcome.noActiveTurn => 'This turn has already ended.',
          StopOutcome.refused => '$agentName did not accept the stop.',
          StopOutcome.unconfirmed =>
            'Stop requested, but $agentName has not confirmed it.',
        };
        // Keep "Stopping…" after a sent signal until the turn ends.
        if (outcome != StopOutcome.sent && context.mounted) {
          stopping.value = false;
        }
        messenger.showSnackBar(SnackBar(content: Text(message)));
      } catch (error) {
        if (context.mounted) stopping.value = false;
        messenger.showSnackBar(
          SnackBar(content: Text('Could not stop $agentName: $error')),
        );
      }
    }

    final muted = context.textTheme.bodySmall?.copyWith(
      color: context.colors.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: Grid.xxs),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: context.colors.outlineVariant),
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        child: Padding(
          padding: const EdgeInsets.all(Grid.twelve),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$agentName in $channelLabel',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: Grid.quarter),
                    Text(
                      stopping.value
                          ? 'Stopping…'
                          : 'Running for '
                                '${formatRunTime(now.difference(turn.startedAt))}',
                      key: const Key('session-row-runtime'),
                      style: muted,
                    ),
                    Text(
                      usageText,
                      key: const Key('session-row-usage'),
                      style: muted,
                    ),
                    if (!turn.cancelByTurnId)
                      Text(
                        'Update $agentName to stop a single turn from here.',
                        key: const Key('session-row-stop-unavailable'),
                        style: muted,
                      ),
                  ],
                ),
              ),
              const SizedBox(width: Grid.xxs),
              OutlinedButton.icon(
                key: const Key('session-row-stop'),
                onPressed: turn.cancelByTurnId && !stopping.value
                    ? () => stop()
                    : null,
                icon: const Icon(LucideIcons.octagon, size: 16),
                label: Semantics(
                  label: 'Stop $agentName in $channelLabel',
                  excludeSemantics: true,
                  child: const Text('Stop'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Usage line for a row. A failed read never reads as "no usage".
String _usageText(
  AsyncValue<Map<String, SessionUsage>> usage,
  String? sessionId,
) {
  final known = sessionId == null ? null : usage.value?[sessionId];
  final formatted = formatSessionUsage(known);
  if (usage.hasError) {
    return formatted == null
        ? 'Usage unavailable'
        : '$formatted (may be out of date)';
  }
  if (formatted != null) return formatted;
  return usage.isLoading && !usage.hasValue
      ? 'Loading usage…'
      : 'No usage reported yet';
}
