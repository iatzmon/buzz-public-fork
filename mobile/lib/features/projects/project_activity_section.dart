import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../shared/profile/user_cache_provider.dart';
import '../../shared/projects/project_task_store.dart';
import '../../shared/relay/relay.dart';
import '../../shared/theme/theme.dart';
import '../../shared/widgets/app_list_card.dart';
import '../../shared/widgets/buzz_loading_indicator.dart';
import '../channels/date_formatters.dart';
import 'project_activity.dart';
import 'project_task_detail_page.dart';
import 'project_task_visuals.dart';

/// Items shown per page of the Activity feed.
const projectActivityPageSize = 40;

/// A project's recent task changes and channel messages, newest first. It is
/// not scrollable itself: place it in a list.
class ProjectActivitySection extends HookConsumerWidget {
  const ProjectActivitySection({
    super.key,
    required this.repositories,
    required this.channelNames,
    required this.onOpenChannel,
    this.channelId,
    this.repositoryChannels = const {},
  });

  /// Repository address to display name.
  final Map<String, String> repositories;

  /// Linked channels the viewer can open: channel id to name.
  final Map<String, String> channelNames;

  /// Opens a linked channel.
  final void Function(String channelId) onOpenChannel;
  final String? channelId;
  final Map<String, String> repositoryChannels;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final limit = useState(projectActivityPageSize);
    final config = ref.watch(relayConfigProvider);
    final viewer = ref.watch(myPubkeyProvider);
    final opened = useMemoized(() => (config.baseUrl, viewer));
    if (opened != (config.baseUrl, viewer)) {
      return const ProjectEmptyState(
        icon: LucideIcons.userRoundX,
        message: 'Community or account changed. Reopen the project.',
      );
    }

    final owners = ref.watch(projectTaskCommunityOwnersProvider);
    final taskStates = {
      for (final address in repositories.keys)
        address: ref.watch(projectTaskStoreProvider(address)),
    };
    final messageKey = projectChannelActivityKey(
      channelNames.keys,
      limit.value,
    );
    final messagesAsync = ref.watch(projectChannelActivityProvider(messageKey));
    final messageEvents = messagesAsync.value ?? const <NostrEvent>[];

    final all = [
      for (final entry in taskStates.entries)
        ...projectTaskActivity(entry.key, entry.value, communityOwners: owners),
      ...projectMessageActivity(
        messageEvents,
      ).where((item) => channelNames.containsKey(item.channelId)),
    ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final shown = all.take(limit.value).toList();
    // More history may exist when either source filled its window.
    final canLoadMore =
        all.length > shown.length || messageEvents.length >= limit.value;

    final people = {
      for (final item in shown) ...[item.actor, ...item.targets],
    };
    useEffect(() {
      unawaited(ref.read(userCacheProvider.notifier).preload(people.toList()));
      return null;
    }, [people.join(',')]);
    final profiles = ref.watch(userCacheProvider);
    String label(String key) =>
        profiles[key]?.label ??
        (key.length <= 8 ? key : '${key.substring(0, 8)}…');

    final tasksLoading =
        taskStates.values.any((s) => s.loading) &&
        taskStates.values.every((s) => s.tasks.isEmpty);
    final Widget body;
    if (shown.isEmpty && (messagesAsync.isLoading || tasksLoading)) {
      body = const Padding(
        padding: EdgeInsets.all(Grid.lg),
        child: Center(
          child: BuzzLoadingIndicator(semanticLabel: 'Loading activity'),
        ),
      );
    } else if (shown.isEmpty) {
      body = const ProjectEmptyState(
        icon: LucideIcons.activity,
        message: 'No activity yet.',
        detail: 'Task changes and channel messages show here.',
      );
    } else {
      body = AppListCard(
        verticalPadding: Grid.half,
        dividerIndent: Grid.xs + 32 + Grid.twelve,
        children: [
          for (final item in shown)
            _ActivityRow(
              key: ValueKey('project-activity-${item.id}'),
              item: item,
              label: label,
              repositoryName: repositories.length > 1
                  ? repositories[item.repoAddress]
                  : null,
              channelName: channelNames[item.channelId],
              onTap: () {
                if (item.channelId case final channel?) {
                  onOpenChannel(channel);
                } else if (item.task case final task?) {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ProjectTaskDetailPage(
                        repoAddress: item.repoAddress!,
                        taskId: task.id,
                        channelId:
                            repositoryChannels[item.repoAddress] ?? channelId,
                        scope: config.baseUrl,
                        viewer: viewer,
                      ),
                    ),
                  );
                }
              },
            ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (messagesAsync.hasError && !messagesAsync.isLoading)
          ProjectNotice(
            icon: LucideIcons.cloudAlert,
            isError: true,
            text: 'Channel messages could not be loaded.',
            actionLabel: 'Retry',
            onAction: () =>
                ref.invalidate(projectChannelActivityProvider(messageKey)),
          ),
        body,
        if (shown.isNotEmpty && canLoadMore)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Grid.xxs),
            child: Center(
              child: TextButton(
                key: const ValueKey('project-activity-more'),
                onPressed: messagesAsync.isLoading
                    ? null
                    : () => limit.value += projectActivityPageSize,
                child: const Text('Load more'),
              ),
            ),
          ),
      ],
    );
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({
    super.key,
    required this.item,
    required this.label,
    required this.repositoryName,
    required this.channelName,
    required this.onTap,
  });

  final ProjectActivityItem item;
  final String Function(String) label;
  final String? repositoryName;
  final String? channelName;
  final VoidCallback onTap;

  String _action() {
    final targets = item.targets
        .map((key) => key == item.actor ? 'themselves' : label(key))
        .join(', ');
    return switch (item.kind) {
      ProjectActivityKind.taskCreated => 'created a task',
      ProjectActivityKind.taskStatus => 'moved a task to ${item.status}',
      ProjectActivityKind.taskAssigned => 'assigned $targets',
      ProjectActivityKind.taskUnassigned => 'unassigned $targets',
      ProjectActivityKind.taskComment => 'commented',
      ProjectActivityKind.message => 'in #${channelName ?? 'channel'}',
    };
  }

  @override
  Widget build(BuildContext context) {
    final muted = context.textTheme.bodySmall?.copyWith(
      color: context.colors.onSurfaceVariant,
    );
    final isMessage = item.kind == ProjectActivityKind.message;
    final title = item.task?.title;
    final preview = item.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final actor = label(item.actor);
    final action = _action();
    final time = relativeTime(item.createdAt);
    final context2 = [?title, ?repositoryName].join(' · ');
    return Semantics(
      button: true,
      excludeSemantics: true,
      onTap: onTap,
      label: [
        '$actor $action',
        if (context2.isNotEmpty) context2,
        if (preview.isNotEmpty) preview,
        time,
      ].join(', '),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Grid.xs,
            vertical: Grid.twelve,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  ProjectPersonAvatar(pubkey: item.actor),
                  Positioned(
                    right: -4,
                    bottom: -4,
                    child: _KindBadge(item: item),
                  ),
                ],
              ),
              const SizedBox(width: Grid.twelve),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: actor,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          TextSpan(text: ' $action'),
                        ],
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: context.textTheme.bodyMedium,
                    ),
                    if (context2.isNotEmpty) ...[
                      const SizedBox(height: Grid.quarter),
                      Text(
                        context2,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                    if (preview.isNotEmpty) ...[
                      const SizedBox(height: Grid.quarter),
                      Text(
                        preview,
                        maxLines: isMessage ? 3 : 2,
                        overflow: TextOverflow.ellipsis,
                        style: context.textTheme.bodyMedium?.copyWith(
                          color: context.colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                    const SizedBox(height: Grid.quarter),
                    Text(time, style: muted),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _KindBadge extends StatelessWidget {
  const _KindBadge({required this.item});

  final ProjectActivityItem item;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (item.kind) {
      ProjectActivityKind.taskStatus => (
        projectTaskStatusStyle(context, item.status ?? '').icon,
        projectTaskStatusStyle(context, item.status ?? '').color,
      ),
      ProjectActivityKind.taskCreated => (
        LucideIcons.circlePlus,
        context.colors.onSurfaceVariant,
      ),
      ProjectActivityKind.taskAssigned => (
        LucideIcons.userRoundPlus,
        context.colors.onSurfaceVariant,
      ),
      ProjectActivityKind.taskUnassigned => (
        LucideIcons.userRoundMinus,
        context.colors.onSurfaceVariant,
      ),
      ProjectActivityKind.taskComment => (
        LucideIcons.messageSquare,
        context.colors.onSurfaceVariant,
      ),
      ProjectActivityKind.message => (
        LucideIcons.hash,
        context.colors.onSurfaceVariant,
      ),
    };
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: context.colors.surfaceContainerHighest,
        shape: BoxShape.circle,
      ),
      child: Icon(icon, size: 12, color: color),
    );
  }
}
