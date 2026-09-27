import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../shared/profile/user_cache_provider.dart';
import '../../shared/projects/project_task_store.dart';
import '../../shared/projects/project_task.dart';
import '../../shared/relay/relay.dart';
import '../../shared/theme/theme.dart';
import '../../shared/widgets/app_list.dart';
import '../../shared/widgets/app_list_card.dart';
import '../../shared/widgets/buzz_loading_indicator.dart';
import '../../shared/widgets/frosted_app_bar.dart';
import '../../shared/widgets/frosted_scaffold.dart';
import '../../shared/widgets/modal_presentation.dart';
import '../channels/date_formatters.dart';
import 'project_task_visuals.dart';

final _taskMembersProvider = FutureProvider.autoDispose
    .family<List<String>, String>((ref, channel) async {
      ref.watch(relayConfigProvider);
      final transport = ref.watch(projectTaskTransportProvider);
      final events = await transport.query(
        NostrFilters.channelMembers(channel),
      );
      final keys = <String>{};
      for (final event in events.where(
        (e) => e.kind == 39002 && e.getTagValue('d') == channel,
      )) {
        for (final tag in event.tags) {
          if (tag.length > 1 && tag[0] == 'p' && isProjectTaskPubkey(tag[1])) {
            keys.add(tag[1].toLowerCase());
          }
        }
      }
      return keys.toList();
    });

/// Task body, trusted assignees and readable task discussion.
class ProjectTaskDetailPage extends HookConsumerWidget {
  const ProjectTaskDetailPage({
    super.key,
    required this.repoAddress,
    required this.taskId,
    required this.scope,
    required this.viewer,
    this.channelId,
  });
  final String repoAddress;
  final String taskId;
  final String scope;
  final String? viewer;
  final String? channelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(relayConfigProvider);
    final current = ref.watch(myPubkeyProvider);
    final sameContext = config.baseUrl == scope && current == viewer;
    final state = ref.watch(projectTaskStoreProvider(repoAddress));
    final store = ref.read(projectTaskStoreProvider(repoAddress).notifier);
    final owners = ref.watch(projectTaskCommunityOwnersProvider);
    final task = state
        .tasksWith(owners)
        .where((t) => t.id == taskId)
        .firstOrNull;
    final profiles = ref.watch(userCacheProvider);
    final memberState = channelId == null
        ? const AsyncData<List<String>>([])
        : ref.watch(_taskMembersProvider(channelId!));
    final error = useState<String?>(null);
    // People who can be assigned: channel members, assignees, and the viewer.
    final candidates = <String>{
      ...?memberState.value,
      ...?task?.assignees,
      ?viewer,
    };
    // Load names for them and for everyone shown in the activity.
    final keys = <String>{
      ...candidates,
      ...?task?.comments.map((c) => c.pubkey.toLowerCase()),
      ?task?.root.pubkey.toLowerCase(),
    };
    useEffect(() {
      unawaited(ref.read(userCacheProvider.notifier).preload(keys.toList()));
      return null;
    }, [keys.join(',')]);
    String label(String key) =>
        profiles[key]?.label ??
        (key.length <= 8 ? key : '${key.substring(0, 8)}…');
    // Read live: a sheet can close after a community or account change.
    bool stillSameContext() =>
        context.mounted &&
        ref.read(relayConfigProvider).baseUrl == scope &&
        ref.read(myPubkeyProvider) == viewer;
    Future<void> change(String key, bool assign) async {
      if (!sameContext || task == null || !stillSameContext()) return;
      error.value = null;
      try {
        await store.assign(
          task,
          key,
          assign: assign,
          assigneeLabel: label(key),
        );
      } catch (e) {
        if (context.mounted) error.value = '$e';
      }
    }

    Future<void> pickMember() async {
      if (task == null) return;
      final picked = await showBuzzModalBottomSheet<String>(
        context: context,
        title: 'Assign a member',
        showDragHandle: true,
        isScrollControlled: true,
        builder: (_) => _MemberPicker(
          channelId: channelId,
          viewer: viewer,
          exclude: task.assignees,
          extra: candidates,
          label: label,
        ),
      );
      if (picked != null) await change(picked, true);
    }

    final Widget body;
    if (!sameContext) {
      body = const ProjectEmptyState(
        icon: LucideIcons.userRoundX,
        message: 'Community or account changed. Reopen Tasks to continue.',
      );
    } else if (task == null) {
      body = ProjectEmptyState(
        icon: LucideIcons.fileQuestion,
        message: state.loading
            ? 'Loading task…'
            : 'Task is unavailable. Refresh the task list.',
      );
    } else {
      final canManage = viewer != null && task.canManage(viewer!);
      final assignees = task.assignees.toList()..sort();
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TaskHeader(task: task, authorLabel: label(task.root.pubkey)),
          if (task.root.content.trim().isNotEmpty)
            _DescriptionCard(content: task.root.content),
          if (error.value ?? state.error case final message?)
            ProjectNotice(
              icon: LucideIcons.circleAlert,
              isError: true,
              text: message,
            ),
          if (state.pending.isNotEmpty)
            ProjectNotice(
              icon: LucideIcons.cloudUpload,
              text: 'A change is waiting to send.',
              actionLabel: 'Retry pending change',
              onAction: state.sending
                  ? null
                  : () async {
                      try {
                        await store.retryPending();
                      } catch (_) {
                        /* Rendered from state. */
                      }
                    },
            ),
          AppListCard(
            key: const ValueKey('project-task-assignees'),
            label: 'Assignees',
            dividerIndent: Grid.xs + 32 + Grid.xs,
            verticalPadding: Grid.twelve,
            children: [
              if (assignees.isEmpty)
                AppListRowRaw(
                  leading: _RoundIcon(
                    icon: LucideIcons.userRound,
                    color: context.colors.onSurfaceVariant,
                  ),
                  title: Text(
                    'Unassigned',
                    style: context.textTheme.bodyLarge?.copyWith(
                      color: context.colors.onSurfaceVariant,
                    ),
                  ),
                  verticalPadding: Grid.xxs,
                ),
              for (final key in assignees)
                AppListRowRaw(
                  key: ValueKey('project-task-assignee-$key'),
                  leading: ProjectPersonAvatar(pubkey: key),
                  title: Text(
                    label(key),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.textTheme.bodyLarge,
                  ),
                  subtitle: key == viewer
                      ? Text(
                          'You',
                          style: context.textTheme.bodySmall?.copyWith(
                            color: context.colors.onSurfaceVariant,
                          ),
                        )
                      : null,
                  trailing: viewer != null && (canManage || key == viewer)
                      ? IconButton(
                          tooltip: 'Unassign ${label(key)}',
                          onPressed: state.sending
                              ? null
                              : () => change(key, false),
                          icon: const Icon(
                            LucideIcons.userRoundMinus,
                            size: 20,
                          ),
                          color: context.colors.onSurfaceVariant,
                        )
                      : null,
                  verticalPadding: Grid.half,
                ),
              if (viewer != null && !task.assignees.contains(viewer))
                _ActionRow(
                  key: const ValueKey('project-task-assign-me'),
                  icon: LucideIcons.userRoundCheck,
                  label: 'Assign to me',
                  onTap: state.sending ? null : () => change(viewer!, true),
                ),
              if (canManage)
                _ActionRow(
                  key: const ValueKey('project-task-assign-member'),
                  icon: LucideIcons.userRoundPlus,
                  label: 'Assign a member',
                  onTap: state.sending ? null : pickMember,
                ),
            ],
          ),
          if (!canManage)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Grid.gutter + Grid.half,
                0,
                Grid.gutter,
                Grid.xxs,
              ),
              child: Text(
                'Only the task author, the repository owner, or a community '
                'owner can assign other people. You can change your own '
                'assignment.',
                style: context.textTheme.bodySmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
            ),
          _Activity(task: task, label: label),
        ],
      );
    }

    return FrostedScaffold(
      useUtilitySurfaceTheme: true,
      appBar: const FrostedAppBar(title: Text('Task')),
      body: RefreshIndicator(
        edgeOffset: frostedAppBarHeight(context),
        onRefresh: store.refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.only(
            top: frostedAppBarHeight(context) + Grid.half,
            bottom: MediaQuery.viewPaddingOf(context).bottom + Grid.lg,
          ),
          children: [body],
        ),
      ),
    );
  }
}

class _TaskHeader extends StatelessWidget {
  const _TaskHeader({required this.task, required this.authorLabel});

  final ProjectTask task;
  final String authorLabel;

  @override
  Widget build(BuildContext context) {
    final muted = context.textTheme.bodySmall?.copyWith(
      color: context.colors.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Grid.gutter,
        Grid.xxs,
        Grid.gutter,
        Grid.xxs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ProjectTaskStatusPill(status: task.status),
              const SizedBox(width: Grid.xxs),
              Text('#${task.id.substring(0, 8)}', style: muted),
            ],
          ),
          const SizedBox(height: Grid.twelve),
          Text(
            task.title,
            style: context.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w600,
              height: 1.2,
            ),
          ),
          const SizedBox(height: Grid.xxs),
          Row(
            children: [
              ProjectPersonAvatar(pubkey: task.root.pubkey, radius: 10),
              const SizedBox(width: Grid.half + Grid.quarter),
              Flexible(
                child: Text(
                  '$authorLabel opened this ${relativeTime(task.root.createdAt)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: muted,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DescriptionCard extends StatelessWidget {
  const _DescriptionCard({required this.content});

  final String content;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      Grid.gutter,
      Grid.xxs,
      Grid.gutter,
      Grid.xxs,
    ),
    child: Container(
      padding: const EdgeInsets.all(Grid.xs),
      decoration: BoxDecoration(
        color: context.colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.container),
      ),
      child: GptMarkdown(content, style: context.textTheme.bodyMedium),
    ),
  );
}

class _RoundIcon extends StatelessWidget {
  const _RoundIcon({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 32,
    height: 32,
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      shape: BoxShape.circle,
    ),
    child: Icon(icon, size: 16, color: color),
  );
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = onTap == null
        ? context.colors.onSurfaceVariant
        : context.colors.primary;
    return Semantics(
      button: true,
      enabled: onTap != null,
      excludeSemantics: true,
      label: label,
      onTap: onTap,
      child: AppListRowRaw(
        leading: _RoundIcon(icon: icon, color: color),
        title: Text(
          label,
          style: context.textTheme.bodyLarge?.copyWith(
            color: color,
            fontWeight: FontWeight.w500,
          ),
        ),
        onTap: onTap,
        verticalPadding: Grid.twelve,
      ),
    );
  }
}

class _MemberPicker extends ConsumerWidget {
  const _MemberPicker({
    required this.channelId,
    required this.viewer,
    required this.exclude,
    required this.extra,
    required this.label,
  });

  final String? channelId;
  final String? viewer;
  final Set<String> exclude;
  final Set<String> extra;
  final String Function(String) label;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final memberState = channelId == null
        ? const AsyncData<List<String>>([])
        : ref.watch(_taskMembersProvider(channelId!));
    ref.watch(userCacheProvider);
    final keys =
        {
          ...?memberState.value,
          ...extra,
        }.where((key) => !exclude.contains(key)).toList()..sort(
          (a, b) => label(a).toLowerCase().compareTo(label(b).toLowerCase()),
        );
    final Widget body;
    if (memberState.isLoading && keys.isEmpty) {
      body = const Padding(
        padding: EdgeInsets.all(Grid.sm),
        child: Center(
          child: BuzzLoadingIndicator(semanticLabel: 'Loading members'),
        ),
      );
    } else {
      body = Flexible(
        child: ListView(
          shrinkWrap: true,
          children: [
            if (memberState.hasError)
              ProjectNotice(
                icon: LucideIcons.cloudAlert,
                isError: true,
                text: 'Could not load members.',
                actionLabel: 'Retry',
                onAction: () =>
                    ref.invalidate(_taskMembersProvider(channelId!)),
              ),
            if (keys.isEmpty)
              const ProjectEmptyState(
                icon: LucideIcons.users,
                message: 'Everyone here is already assigned.',
              ),
            for (final key in keys)
              ListTile(
                key: ValueKey('project-task-member-$key'),
                leading: ProjectPersonAvatar(pubkey: key),
                title: Text(label(key)),
                subtitle: key == viewer ? const Text('You') : null,
                onTap: () => Navigator.of(context).pop(key),
              ),
          ],
        ),
      );
    }
    return SafeArea(
      top: false,
      child: Column(mainAxisSize: MainAxisSize.min, children: [body]),
    );
  }
}

class _Activity extends StatelessWidget {
  const _Activity({required this.task, required this.label});

  final ProjectTask task;
  final String Function(String) label;

  @override
  Widget build(BuildContext context) {
    final muted = context.textTheme.bodySmall?.copyWith(
      color: context.colors.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(Grid.gutter, Grid.xs, Grid.gutter, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: Grid.half, bottom: Grid.xxs),
            child: Semantics(
              header: true,
              child: Text(
                'Activity',
                style: context.textTheme.labelMedium?.copyWith(
                  color: context.colors.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          if (task.comments.isEmpty)
            Padding(
              padding: const EdgeInsets.only(left: Grid.half),
              child: Text('No activity yet.', style: muted),
            ),
          for (final comment in task.comments)
            if (_isAssignmentOperation(comment))
              if (_appliedAssignmentChange(task, comment) case final change?)
                _AssignmentLine(
                  icon: change.assign
                      ? LucideIcons.userRoundPlus
                      : LucideIcons.userRoundMinus,
                  text: _assignmentText(comment, change, label),
                  time: relativeTime(comment.createdAt),
                )
              else
                const SizedBox.shrink()
            else
              _CommentEntry(
                pubkey: comment.pubkey,
                author: label(comment.pubkey),
                time: relativeTime(comment.createdAt),
                content: comment.content,
              ),
        ],
      ),
    );
  }
}

List<String> _labels(NostrEvent event) => [
  for (final tag in event.tags)
    if (tag.length > 1 && tag[0] == 't') tag[1],
];

/// Whether [event] is tagged as an assignment change, valid or not.
bool _isAssignmentOperation(NostrEvent event) {
  final labels = _labels(event);
  return labels.contains('assignment') || labels.contains('unassignment');
}

/// The assignment change in [event], when the task state applied it.
({bool assign, List<String> targets})? _appliedAssignmentChange(
  ProjectTask task,
  NostrEvent event,
) {
  if (!task.appliedAssignmentIds.contains(event.id)) return null;
  return (
    assign: _labels(event).contains('assignment'),
    targets: [
      for (final tag in event.tags)
        if (tag.length > 1 && tag[0] == 'p') tag[1].toLowerCase(),
    ],
  );
}

String _assignmentText(
  NostrEvent event,
  ({bool assign, List<String> targets}) change,
  String Function(String) label,
) {
  final signer = event.pubkey.toLowerCase();
  final targets = change.targets
      .map((key) => key == signer ? 'themselves' : label(key))
      .join(', ');
  return '${label(signer)} ${change.assign ? 'assigned' : 'unassigned'} '
      '$targets';
}

class _AssignmentLine extends StatelessWidget {
  const _AssignmentLine({
    required this.icon,
    required this.text,
    required this.time,
  });

  final IconData icon;
  final String text;
  final String time;

  @override
  Widget build(BuildContext context) {
    final muted = context.textTheme.bodySmall?.copyWith(
      color: context.colors.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Grid.half),
      child: MergeSemantics(
        child: Row(
          children: [
            SizedBox(
              width: 32,
              child: Icon(
                icon,
                size: 14,
                color: context.colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: Grid.xxs),
            Expanded(child: Text('$text · $time', style: muted)),
          ],
        ),
      ),
    );
  }
}

class _CommentEntry extends StatelessWidget {
  const _CommentEntry({
    required this.pubkey,
    required this.author,
    required this.time,
    required this.content,
  });

  final String pubkey;
  final String author;
  final String time;
  final String content;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: Grid.xxs),
    child: MergeSemantics(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ProjectPersonAvatar(pubkey: pubkey),
          const SizedBox(width: Grid.xxs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        author,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: Grid.half),
                    Text(
                      time,
                      style: context.textTheme.labelSmall?.copyWith(
                        color: context.colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Grid.quarter),
                GptMarkdown(content, style: context.textTheme.bodyMedium),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
