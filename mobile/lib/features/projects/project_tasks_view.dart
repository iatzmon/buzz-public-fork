import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../shared/projects/project_task.dart';
import '../../shared/projects/project_task_store.dart';
import '../../shared/relay/relay.dart';
import '../../shared/theme/theme.dart';
import '../../shared/widgets/app_list_card.dart';
import '../../shared/widgets/buzz_loading_indicator.dart';
import '../../shared/widgets/filter_chip_bar.dart';
import '../../shared/widgets/modal_presentation.dart';
import '../channels/date_formatters.dart';
import 'project_task_compose_page.dart';
import 'project_task_detail_page.dart';
import 'project_task_visuals.dart';

enum _TaskFilter { open, mine, closed }

/// A task with the repository it belongs to.
typedef _RepoTask = ({String repoAddress, ProjectTask task});

/// Refreshes the task lists of [repositories].
Future<void> refreshProjectTasks(
  WidgetRef ref,
  Iterable<String> repositories,
) => Future.wait([
  for (final address in repositories)
    ref.read(projectTaskStoreProvider(address).notifier).refresh(),
]);

/// Opens the new-task page. Asks for the repository first when the project
/// has more than one.
Future<void> startProjectTask(
  BuildContext context,
  WidgetRef ref, {
  required Map<String, String> repositories,
  required Map<String, String> repositoryChannels,
  String? channelId,
}) async {
  final viewer = ref.read(myPubkeyProvider);
  final scope = ref.read(relayConfigProvider).baseUrl;
  if (viewer == null || repositories.isEmpty) return;
  var address = repositories.keys.first;
  if (repositories.length > 1) {
    final picked = await showBuzzModalBottomSheet<String>(
      context: context,
      title: 'New task in',
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final entry in repositories.entries)
              ListTile(
                key: ValueKey('project-task-repository-${entry.key}'),
                leading: const Icon(LucideIcons.folderGit2),
                title: Text(entry.value),
                onTap: () => Navigator.of(sheetContext).pop(entry.key),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    address = picked;
  }
  // The sheet can close after a community or account change.
  if (!context.mounted ||
      ref.read(relayConfigProvider).baseUrl != scope ||
      ref.read(myPubkeyProvider) != viewer) {
    return;
  }
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ProjectTaskComposePage(
        repoAddress: address,
        repositoryName: repositories[address],
        channelId: repositoryChannels[address] ?? channelId,
        scope: scope,
        viewer: viewer,
      ),
    ),
  );
}

/// The tasks of every repository in a project, grouped by status. It is not
/// scrollable itself: place it in a list.
class ProjectTasksSection extends HookConsumerWidget {
  const ProjectTasksSection({
    super.key,
    required this.repositories,
    this.channelId,
    this.repositoryChannels = const {},
  });

  /// NIP-34 repository address to display name; grouping does not grant access.
  final Map<String, String> repositories;
  final String? channelId;
  final Map<String, String> repositoryChannels;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = useState(_TaskFilter.open);
    final config = ref.watch(relayConfigProvider);
    final viewer = ref.watch(myPubkeyProvider);
    final opened = useMemoized(() => (config.baseUrl, viewer));
    if (opened != (config.baseUrl, viewer)) {
      return const ProjectEmptyState(
        icon: LucideIcons.userRoundX,
        message: 'Community or account changed. Reopen Tasks to continue.',
      );
    }
    if (repositories.isEmpty) {
      return const ProjectEmptyState(
        icon: LucideIcons.folderGit2,
        message: 'Add a repository to this project to use Tasks.',
      );
    }

    final states = {
      for (final address in repositories.keys)
        address: ref.watch(projectTaskStoreProvider(address)),
    };
    final all = <_RepoTask>[
      for (final entry in states.entries)
        for (final task in entry.value.tasks)
          (repoAddress: entry.key, task: task),
    ];
    bool isMine(_RepoTask t) => t.task.assignees.contains(viewer);
    final counts = {
      _TaskFilter.open: all
          .where((t) => !isProjectTaskClosed(t.task.status))
          .length,
      _TaskFilter.mine: all.where(isMine).length,
      _TaskFilter.closed: all
          .where((t) => isProjectTaskClosed(t.task.status))
          .length,
    };
    final shown = all.where(
      (t) => switch (filter.value) {
        _TaskFilter.open => !isProjectTaskClosed(t.task.status),
        _TaskFilter.mine => isMine(t),
        _TaskFilter.closed => isProjectTaskClosed(t.task.status),
      },
    );
    final groups = {
      for (final status in projectTaskStatusOrder)
        status: [
          for (final t in shown)
            if (t.task.status == status) t,
        ],
    }..removeWhere((_, tasks) => tasks.isEmpty);

    final loaded = states.values.any((s) => s.loaded);
    final pending = states.values.fold(0, (n, s) => n + s.pending.length);
    final sending = states.values.any((s) => s.sending);
    final multiRepo = repositories.length > 1;

    Future<void> retryPending() async {
      for (final entry in states.entries) {
        if (entry.value.pending.isEmpty) continue;
        try {
          await ref
              .read(projectTaskStoreProvider(entry.key).notifier)
              .retryPending();
        } catch (_) {
          /* Rendered from state. */
        }
      }
    }

    final errors = [
      for (final entry in states.entries)
        if (entry.value.error case final error?)
          (address: entry.key, error: error),
    ];
    // Nothing to show and a load failed: the error replaces the list.
    final failed = all.isEmpty && !loaded && errors.isNotEmpty;

    final Widget body;
    if (failed) {
      body = ProjectEmptyState(
        icon: LucideIcons.cloudAlert,
        isError: true,
        message: 'Tasks could not be loaded.',
        detail: errors.first.error,
        action: FilledButton.icon(
          key: const ValueKey('project-tasks-retry'),
          onPressed: () =>
              unawaited(refreshProjectTasks(ref, repositories.keys)),
          icon: const Icon(LucideIcons.refreshCcw, size: 16),
          label: const Text('Retry'),
        ),
      );
    } else if (all.isEmpty && !loaded) {
      body = const Padding(
        padding: EdgeInsets.all(Grid.lg),
        child: Center(
          child: BuzzLoadingIndicator(semanticLabel: 'Loading tasks'),
        ),
      );
    } else if (groups.isEmpty) {
      body = ProjectEmptyState(
        icon: switch (filter.value) {
          _TaskFilter.open => LucideIcons.listTodo,
          _TaskFilter.mine => LucideIcons.userRoundCheck,
          _TaskFilter.closed => LucideIcons.circleCheck,
        },
        message: switch (filter.value) {
          _TaskFilter.open when all.isEmpty => 'No tasks yet.',
          _TaskFilter.open => 'No open tasks.',
          _TaskFilter.mine => 'No tasks assigned to you.',
          _TaskFilter.closed => 'No finished tasks.',
        },
        detail: filter.value == _TaskFilter.open && viewer != null
            ? 'Tap + to add one.'
            : null,
      );
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final group in groups.entries)
            _TaskGroup(
              status: group.key,
              tasks: group.value,
              repositories: multiRepo ? repositories : null,
              onOpen: (t) => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ProjectTaskDetailPage(
                    repoAddress: t.repoAddress,
                    taskId: t.task.id,
                    channelId: repositoryChannels[t.repoAddress] ?? channelId,
                    scope: config.baseUrl,
                    viewer: viewer,
                  ),
                ),
              ),
            ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilterChipBar<_TaskFilter>(
          key: const ValueKey('project-tasks-filter'),
          items: [
            FilterChipItem(
              id: _TaskFilter.open,
              label: 'Open',
              count: counts[_TaskFilter.open],
            ),
            FilterChipItem(
              id: _TaskFilter.mine,
              label: 'Assigned to me',
              count: counts[_TaskFilter.mine],
            ),
            FilterChipItem(
              id: _TaskFilter.closed,
              label: 'Finished',
              count: counts[_TaskFilter.closed],
            ),
          ],
          selected: filter.value,
          onSelected: (value) => filter.value = value,
        ),
        if (!failed)
          for (final e in errors)
            ProjectNotice(
              icon: LucideIcons.cloudAlert,
              isError: true,
              text: multiRepo
                  ? '${repositories[e.address]}: ${e.error}'
                  : e.error,
              actionLabel: 'Retry',
              onAction: () => unawaited(
                ref
                    .read(projectTaskStoreProvider(e.address).notifier)
                    .refresh(),
              ),
            ),
        if (pending > 0)
          ProjectNotice(
            icon: LucideIcons.cloudUpload,
            text: pending == 1
                ? '1 change is waiting to send.'
                : '$pending changes are waiting to send.',
            actionLabel: 'Retry send',
            onAction: sending ? null : () => unawaited(retryPending()),
          ),
        if (states.values.any((s) => s.tasks.length >= 200))
          const ProjectNotice(
            icon: LucideIcons.info,
            text: 'Showing the latest 200 tasks in each repository.',
          ),
        body,
      ],
    );
  }
}

class _TaskGroup extends StatelessWidget {
  const _TaskGroup({
    required this.status,
    required this.tasks,
    required this.repositories,
    required this.onOpen,
  });

  final String status;
  final List<_RepoTask> tasks;

  /// Repository names, shown on each row when the project has several.
  final Map<String, String>? repositories;
  final ValueChanged<_RepoTask> onOpen;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(
          Grid.gutter + Grid.half,
          Grid.xs,
          Grid.gutter,
          Grid.xxs,
        ),
        child: Semantics(
          header: true,
          child: Row(
            children: [
              ProjectTaskStatusIcon(status: status, size: 14),
              const SizedBox(width: Grid.half + Grid.quarter),
              Text(
                status,
                style: context.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: Grid.half + Grid.quarter),
              Text(
                '${tasks.length}',
                style: context.textTheme.labelLarge?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
      AppListCard(
        verticalPadding: 0,
        dividerIndent: Grid.xs + 18 + Grid.twelve,
        children: [
          for (final t in tasks)
            _TaskRow(
              key: ValueKey(t.task.id),
              task: t.task,
              repositoryName: repositories?[t.repoAddress],
              onTap: () => onOpen(t),
            ),
        ],
      ),
    ],
  );
}

/// Discussion comments, without assignment changes.
int projectTaskCommentCount(ProjectTask task) => task.comments
    .where(
      (e) => !e.tags.any(
        (tag) =>
            tag.length > 1 &&
            tag[0] == 't' &&
            (tag[1] == 'assignment' || tag[1] == 'unassignment'),
      ),
    )
    .length;

class _TaskRow extends StatelessWidget {
  const _TaskRow({
    super.key,
    required this.task,
    required this.repositoryName,
    required this.onTap,
  });

  final ProjectTask task;
  final String? repositoryName;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final comments = projectTaskCommentCount(task);
    final meta = context.textTheme.labelSmall?.copyWith(
      color: context.colors.onSurfaceVariant,
    );
    final assignees = task.assignees.toList()..sort();
    return Semantics(
      button: true,
      label:
          '${task.title}, ${task.status}'
          '${assignees.isEmpty ? ', unassigned' : ', ${assignees.length} assigned'}'
          '${comments == 0 ? '' : ', $comments comments'}',
      excludeSemantics: true,
      onTap: onTap,
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
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: ProjectTaskStatusIcon(status: task.status),
              ),
              const SizedBox(width: Grid.twelve),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: context.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w500,
                        height: 1.25,
                      ),
                    ),
                    const SizedBox(height: Grid.half),
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            [
                              ?repositoryName,
                              relativeTime(task.root.createdAt),
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: meta,
                          ),
                        ),
                        if (comments > 0) ...[
                          const SizedBox(width: Grid.xxs),
                          Icon(
                            LucideIcons.messageSquare,
                            size: 12,
                            color: meta?.color,
                          ),
                          const SizedBox(width: Grid.quarter),
                          Text('$comments', style: meta),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              if (assignees.isNotEmpty) ...[
                const SizedBox(width: Grid.xxs),
                ProjectAssigneeFacepile(pubkeys: assignees),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
