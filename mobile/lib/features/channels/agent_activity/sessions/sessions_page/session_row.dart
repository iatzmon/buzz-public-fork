part of '../sessions_page.dart';

class _SessionRow extends HookConsumerWidget {
  const _SessionRow({
    super.key,
    required this.turn,
    required this.channel,
    required this.now,
  });

  final ActiveTurn turn;
  final Channel? channel;
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
    final channel = this.channel;
    final channelLabel = channel == null ? 'a channel' : '#${channel.name}';
    final stopping = useState(false);
    final usageText = _usageText(
      ref.watch(agentSessionUsageProvider(turn.agentPubkey)),
      turn.sessionId,
    );
    final activity = ref.watch(
      turnActivityProvider((
        agentPubkey: turn.agentPubkey,
        turnId: turn.turnId,
      )),
    );
    final requestId = turn.triggeringEventIds.lastOrNull;
    final quiet = turn.isQuietAt(now);

    void openConversation() {
      if (channel == null || requestId == null) return;
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => NotificationDestination(
            channel: channel,
            link: MessageDeepLink(channelId: channel.id, messageId: requestId),
          ),
        ),
      );
    }

    Future<void> stop() async {
      stopping.value = true;
      final messenger = ScaffoldMessenger.of(context);
      try {
        final outcome = await ref.read(stopTurnProvider)(turn);
        final message = switch (outcome) {
          StopOutcome.sent => 'Stop signal sent to $agentName.',
          StopOutcome.noActiveTurn =>
            '$agentName has no running turn with this ID. It may have '
                'ended, or an earlier Stop may still be finishing.',
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
                    _RequestLine(
                      channel: channel,
                      requestId: requestId,
                      muted: muted,
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
                    if (quiet)
                      Text(
                        'No signal for '
                        '${formatRunTime(now.difference(turn.lastSeenAt))}',
                        key: const Key('session-row-quiet'),
                        style: muted,
                      )
                    else if (activity != null)
                      Text(
                        activity,
                        key: const Key('session-row-activity'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
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
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
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
                  if (channel != null && requestId != null)
                    TextButton(
                      key: const Key('session-row-open'),
                      onPressed: openConversation,
                      child: Semantics(
                        label:
                            'Open the conversation for $agentName in '
                            '$channelLabel',
                        excludeSemantics: true,
                        child: const Text('Open'),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The request that started a turn, so sibling turns of one agent in one
/// channel can be told apart. Says so when the request is not known.
class _RequestLine extends ConsumerWidget {
  const _RequestLine({
    required this.channel,
    required this.requestId,
    required this.muted,
  });

  final Channel? channel;
  final String? requestId;
  final TextStyle? muted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final channel = this.channel;
    final requestId = this.requestId;
    final String text;
    if (requestId == null) {
      text = 'Request not known: this turn started before the app connected.';
    } else if (channel == null) {
      text = 'Request in a channel this app has not loaded.';
    } else {
      final event = ref.watch(
        notificationEventProvider((
          channelId: channel.id,
          eventId: requestId,
          isForum: channel.isForum,
        )),
      );
      text = event.when(
        data: (event) {
          final snippet = event.content.replaceAll(RegExp(r'\s+'), ' ').trim();
          final where = event.threadReference.rootId == null
              ? ''
              : ' (in a thread)';
          return snippet.isEmpty
              ? 'Request has no text$where'
              : 'Request$where: "$snippet"';
        },
        loading: () => 'Loading the request…',
        error: (_, _) => 'Request could not be loaded.',
      );
    }
    return Text(
      text,
      key: const Key('session-row-request'),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: muted,
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
