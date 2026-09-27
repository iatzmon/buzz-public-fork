import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../shared/projects/projects.dart';
import '../../shared/relay/relay.dart';
import '../../shared/theme/theme.dart';
import '../../shared/widgets/adaptive_workspace.dart';
import '../../shared/widgets/app_list.dart';
import '../../shared/widgets/app_list_card.dart';
import '../../shared/widgets/buzz_loading_indicator.dart';
import '../../shared/widgets/frosted_app_bar.dart';
import '../../shared/widgets/frosted_scaffold.dart';
import '../channels/channel.dart';
import '../channels/channel_detail_page.dart';
import '../channels/channels_provider.dart';
import 'project_activity_section.dart';
import 'project_task_visuals.dart';
import 'project_tasks_page.dart';
import 'project_tasks_view.dart';

/// The channel with [channelId] from the loaded channel list, or null.
Channel? findLoadedChannel(WidgetRef ref, String channelId) {
  final channels = ref.read(channelsProvider).value;
  for (final channel in channels ?? const <Channel>[]) {
    if (channel.id == channelId) return channel;
  }
  return null;
}

/// Opens [project]'s page. Its Channels tab opens the project's channels.
Future<void> openProject(
  BuildContext context,
  WidgetRef ref,
  Project project,
) => AdaptiveWorkspace.open(
  context,
  MaterialPageRoute<void>(
    builder: (_) => ProjectPage(projectAddress: project.projectAddress),
  ),
);

enum _ProjectTab { tasks, activity, channels, repositories }

/// Height of the tab row under the project page's top bar.
const _kProjectTabsHeight = 44.0;

/// A project's tasks, channels, and repositories. Opens on Tasks.
class ProjectPage extends HookConsumerWidget {
  const ProjectPage({super.key, required this.projectAddress});

  /// `30621:<owner>:<dtag>` coordinate of the project.
  final String projectAddress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tab = useState(_ProjectTab.tasks);
    final snapshotAsync = ref.watch(activeProjectsProvider);
    final snapshot = snapshotAsync.value;
    final project = ref.watch(projectByAddressProvider(projectAddress));
    final added = ref
        .watch(projectSidebarMembershipProvider)
        .selectedAddresses
        .contains(projectAddress);
    final viewer = ref.watch(myPubkeyProvider);

    Future<void> retry() async =>
        ref.read(activeProjectsNotifierProvider)?.refresh();

    if (project == null) {
      final Widget body;
      if (snapshotAsync.hasError && !snapshotAsync.isLoading) {
        body = ProjectEmptyState(
          icon: LucideIcons.cloudAlert,
          isError: true,
          message: 'Projects could not be loaded.',
          action: FilledButton.icon(
            key: const ValueKey('project-page-retry'),
            onPressed: retry,
            icon: const Icon(LucideIcons.refreshCcw, size: 16),
            label: const Text('Retry'),
          ),
        );
      } else if (snapshot == null || snapshotAsync.isLoading) {
        body = const BuzzLoadingIndicator(semanticLabel: 'Loading project');
      } else {
        body = const ProjectEmptyState(
          icon: LucideIcons.folderX,
          message: 'This project is not available.',
          detail:
              'It may have been deleted, or it belongs to another community.',
        );
      }
      return FrostedScaffold(
        useUtilitySurfaceTheme: true,
        appBar: const FrostedAppBar(title: Text('Project')),
        body: Center(child: body),
      );
    }

    final channels = ref.watch(channelsProvider).value ?? const <Channel>[];
    final channelsById = {for (final c in channels) c.id: c};
    final boundChannels = listProjectBoundChannels(project);
    final relayOrigin = snapshot?.scope.relayOrigin;
    final repositories = {
      for (final repository in project.repositories)
        repository.repoAddress: repository.name,
    };
    final repositoryChannels = {
      for (final repository in project.repositories)
        repository.repoAddress: ?repository.channelId,
    };
    final repositoryCount =
        project.repositories.length +
        project.unavailableRepositoryAddresses.length;

    Future<void> refresh() =>
        Future.wait([retry(), refreshProjectTasks(ref, repositories.keys)]);

    final Widget content = switch (tab.value) {
      _ProjectTab.tasks =>
        repositories.isEmpty
            ? const ProjectEmptyState(
                icon: LucideIcons.folderGit2,
                message: 'Tasks need a repository in this project.',
              )
            : ProjectTasksSection(
                key: const ValueKey('project-tasks'),
                repositories: repositories,
                channelId: project.projectChannelId,
                repositoryChannels: repositoryChannels,
              ),
      _ProjectTab.activity => ProjectActivitySection(
        key: const ValueKey('project-activity'),
        repositories: repositories,
        channelNames: {
          for (final bound in boundChannels)
            if (channelsById[bound.channelId] case final channel?)
              channel.id: channel.name,
        },
        onOpenChannel: (id) {
          final channel = channelsById[id];
          if (channel == null) return;
          unawaited(
            AdaptiveWorkspace.open(
              context,
              MaterialPageRoute<void>(
                builder: (_) => ChannelDetailPage(channel: channel),
              ),
            ),
          );
        },
        channelId: project.projectChannelId,
        repositoryChannels: repositoryChannels,
      ),
      _ProjectTab.channels =>
        boundChannels.isEmpty
            ? const ProjectEmptyState(
                icon: LucideIcons.hash,
                message: 'This project has no channels.',
              )
            : AppListCard(
                dividerIndent: Grid.xs + 32 + Grid.xs,
                verticalPadding: Grid.xxs,
                children: [
                  for (final bound in boundChannels)
                    _ChannelRow(
                      bound: bound,
                      channel: channelsById[bound.channelId],
                      repositoryName: _repositoryName(
                        project,
                        bound.repositoryId,
                      ),
                    ),
                ],
              ),
      _ProjectTab.repositories =>
        repositoryCount == 0
            ? const ProjectEmptyState(
                icon: LucideIcons.folderGit2,
                message: 'This project has no repositories.',
              )
            : AppListCard(
                dividerIndent: Grid.xs + 32 + Grid.xs,
                verticalPadding: Grid.xxs,
                children: [
                  for (final repository in project.repositories)
                    _RepositoryRow(
                      repository: repository,
                      relayOrigin: relayOrigin,
                    ),
                  if (project.unavailableRepositoryAddresses.isNotEmpty)
                    AppListRowRaw(
                      leading: const _RowIcon(icon: LucideIcons.folderX),
                      title: Text(
                        project.unavailableRepositoryAddresses.length == 1
                            ? '1 repository is not available.'
                            : '${project.unavailableRepositoryAddresses.length} '
                                  'repositories are not available.',
                        style: context.textTheme.bodyMedium?.copyWith(
                          color: context.colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
    };

    return FrostedScaffold(
      useUtilitySurfaceTheme: true,
      appBar: FrostedAppBar(
        title: Text(project.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            key: const ValueKey('project-page-sidebar-toggle'),
            tooltip: added ? 'Remove from list' : 'Add to list',
            icon: Icon(added ? LucideIcons.listMinus : LucideIcons.listPlus),
            onPressed: () {
              final notifier = ref.read(
                projectSidebarMembershipProvider.notifier,
              );
              unawaited(
                added
                    ? notifier.remove(projectAddress)
                    : notifier.add(projectAddress),
              );
            },
          ),
        ],
        bottom: _ProjectTabs(
          selected: tab.value,
          onSelected: (value) => tab.value = value,
        ),
        bottomHeight: _kProjectTabsHeight,
      ),
      floatingActionButton:
          tab.value == _ProjectTab.tasks &&
              viewer != null &&
              repositories.isNotEmpty
          ? NewProjectTaskButton(
              onPressed: () => startProjectTask(
                context,
                ref,
                repositories: repositories,
                repositoryChannels: repositoryChannels,
                channelId: project.projectChannelId,
              ),
            )
          : null,
      body: RefreshIndicator(
        edgeOffset: frostedAppBarHeight(
          context,
          bottomHeight: _kProjectTabsHeight,
        ),
        onRefresh: refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.only(
            top:
                frostedAppBarHeight(
                  context,
                  bottomHeight: _kProjectTabsHeight,
                ) +
                Grid.half,
            bottom: MediaQuery.viewPaddingOf(context).bottom + Grid.xxxl,
          ),
          children: [
            if (snapshotAsync.hasError && !snapshotAsync.isLoading)
              ProjectNotice(
                icon: LucideIcons.cloudAlert,
                text: 'Could not refresh. This may be out of date.',
                actionLabel: 'Retry',
                actionKey: const ValueKey('project-page-retry'),
                onAction: retry,
              )
            else if (snapshot?.fromCache ?? false)
              const ProjectNotice(
                icon: LucideIcons.cloudOff,
                text: 'Saved copy. It may be out of date.',
              ),
            _ProjectSummary(
              project: project,
              channelCount: boundChannels.length,
              repositoryCount: repositoryCount,
            ),
            content,
          ],
        ),
      ),
    );
  }
}

String? _repositoryName(Project project, String? repositoryId) {
  if (repositoryId == null) return null;
  for (final repository in project.repositories) {
    if (repository.id == repositoryId) return repository.name;
  }
  return null;
}

class _ProjectTabs extends StatelessWidget {
  const _ProjectTabs({required this.selected, required this.onSelected});

  final _ProjectTab selected;
  final ValueChanged<_ProjectTab> onSelected;

  static const _items = [
    (tab: _ProjectTab.tasks, label: 'Tasks', icon: LucideIcons.listTodo),
    (tab: _ProjectTab.activity, label: 'Activity', icon: LucideIcons.activity),
    (tab: _ProjectTab.channels, label: 'Channels', icon: LucideIcons.hash),
    (
      tab: _ProjectTab.repositories,
      label: 'Repos',
      icon: LucideIcons.folderGit2,
    ),
  ];

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: Grid.xxs),
    child: LayoutBuilder(
      builder: (context, constraints) {
        // Icons only when every tab has room for icon and label.
        final showIcons = constraints.maxWidth / _items.length >= 104;
        return Row(
          children: [
            for (final item in _items)
              Expanded(
                child: _ProjectTabButton(
                  key: ValueKey('project-tab-${item.tab.name}'),
                  label: item.label,
                  icon: showIcons ? item.icon : null,
                  selected: item.tab == selected,
                  onTap: () => onSelected(item.tab),
                ),
              ),
          ],
        );
      },
    ),
  );
}

class _ProjectTabButton extends StatelessWidget {
  const _ProjectTabButton({
    super.key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData? icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected
        ? context.colors.onSurface
        : context.colors.onSurfaceVariant;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.md),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Grid.twelve - 1),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (icon case final icon?) ...[
                    Icon(icon, size: 16, color: color),
                    const SizedBox(width: Grid.half + Grid.quarter),
                  ],
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.textTheme.labelLarge?.copyWith(
                        color: color,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              height: 2,
              margin: const EdgeInsets.symmetric(horizontal: Grid.xs),
              decoration: BoxDecoration(
                color: selected ? context.colors.onSurface : Colors.transparent,
                borderRadius: BorderRadius.circular(Radii.full),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One line of project description and counts. Tap to show all of it.
class _ProjectSummary extends HookWidget {
  const _ProjectSummary({
    required this.project,
    required this.channelCount,
    required this.repositoryCount,
  });

  final Project project;
  final int channelCount;
  final int repositoryCount;

  @override
  Widget build(BuildContext context) {
    final expanded = useState(false);
    final description = project.description.trim();
    final counts = [
      channelCount == 1 ? '1 channel' : '$channelCount channels',
      repositoryCount == 1 ? '1 repository' : '$repositoryCount repositories',
    ].join(' · ');
    final muted = context.textTheme.bodySmall?.copyWith(
      color: context.colors.onSurfaceVariant,
    );
    final collapsedText = description.isEmpty
        ? counts
        : '$description · $counts';
    return Semantics(
      button: true,
      expanded: expanded.value,
      label: expanded.value ? null : 'Project details',
      onTap: () => expanded.value = !expanded.value,
      child: InkWell(
        key: const ValueKey('project-summary'),
        onTap: () => expanded.value = !expanded.value,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            Grid.gutter,
            Grid.half,
            Grid.xs,
            Grid.half,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: expanded.value
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (description.isNotEmpty) ...[
                            Text(
                              description,
                              style: context.textTheme.bodyMedium,
                            ),
                            const SizedBox(height: Grid.half),
                          ],
                          Text(counts, style: muted),
                        ],
                      )
                    : Text(
                        collapsedText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: muted,
                      ),
              ),
              const SizedBox(width: Grid.half),
              Icon(
                expanded.value
                    ? LucideIcons.chevronUp
                    : LucideIcons.chevronDown,
                size: 16,
                color: context.colors.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RowIcon extends StatelessWidget {
  const _RowIcon({required this.icon, this.enabled = true});

  final IconData icon;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Container(
    width: 32,
    height: 32,
    decoration: BoxDecoration(
      color: context.colors.onSurface.withValues(alpha: 0.07),
      borderRadius: BorderRadius.circular(Radii.md),
    ),
    child: Icon(
      icon,
      size: 16,
      color: enabled
          ? context.colors.onSurface
          : context.colors.onSurfaceVariant,
    ),
  );
}

class _ChannelRow extends ConsumerWidget {
  const _ChannelRow({
    required this.bound,
    required this.channel,
    required this.repositoryName,
  });

  final ProjectBoundChannel bound;
  final Channel? channel;
  final String? repositoryName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final channel = this.channel;
    final isHome = bound.role == ProjectChannelRole.home;
    final kind = channel == null
        ? null
        : channel.isForum
        ? 'Forum'
        : 'Chat';
    final subtitle = [
      if (isHome) kind == null ? 'Project home' : 'Project home · $kind',
      if (!isHome && repositoryName != null) repositoryName!,
      if (channel == null) 'Not available to you',
      if (channel != null && !channel.isMember && channel.canJoin) 'Open',
    ].join(' · ');
    final muted = context.textTheme.bodySmall?.copyWith(
      color: context.colors.onSurfaceVariant,
    );

    return KeyedSubtree(
      key: ValueKey('project-channel-${bound.channelId}'),
      child: AppListRowRaw(
        leading: _RowIcon(
          icon: channel == null ? LucideIcons.hash : channelIcon(channel),
          enabled: channel != null,
        ),
        title: Text(
          channel == null ? 'Unavailable channel' : channel.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.textTheme.bodyLarge?.copyWith(
            color: channel == null ? context.colors.onSurfaceVariant : null,
          ),
        ),
        subtitle: subtitle.isEmpty ? null : Text(subtitle, style: muted),
        trailing: channel == null
            ? null
            : Icon(
                LucideIcons.chevronRight,
                size: 18,
                color: context.colors.onSurfaceVariant,
              ),
        verticalPadding: Grid.twelve,
        onTap: channel == null
            ? null
            : () => AdaptiveWorkspace.open(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => ChannelDetailPage(channel: channel),
                ),
              ),
      ),
    );
  }
}

class _RepositoryRow extends StatelessWidget {
  const _RepositoryRow({required this.repository, required this.relayOrigin});

  final ProjectRepository repository;
  final String? relayOrigin;

  @override
  Widget build(BuildContext context) {
    final presentation = projectRepoPresentation(repository, relayOrigin);
    final path = repositoryDisplayPath(repository, relayOrigin);
    final host = presentation.host;
    final externalUrl = presentation.externalUrl;
    final String hostLabel = switch (host) {
      BuzzRepoHost() => 'Hosted in this community',
      ExternalRepoHost(:final host) => 'Hosted on $host',
      UnresolvedRepoHost() => 'Location unknown',
    };
    final hostName = host is ExternalRepoHost ? host.host : null;
    final muted = context.textTheme.bodySmall?.copyWith(
      color: context.colors.onSurfaceVariant,
    );

    return KeyedSubtree(
      key: ValueKey('project-repository-${repository.repoAddress}'),
      child: AppListRowRaw(
        leading: const _RowIcon(icon: LucideIcons.folderGit2),
        title: Text(
          repository.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.textTheme.bodyLarge,
        ),
        subtitle: Text(
          [?path, hostLabel].join('\n'),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: muted,
        ),
        trailing: externalUrl == null
            ? null
            : TextButton.icon(
                key: ValueKey('project-repository-open-${repository.dtag}'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () => _openExternal(context, externalUrl),
                icon: const Icon(LucideIcons.externalLink, size: 14),
                label: Text('Open on ${_shortHost(hostName)}'),
              ),
        verticalPadding: Grid.twelve,
      ),
    );
  }
}

String _shortHost(String? host) {
  if (host == null) return 'web';
  return host == 'github.com' || host == 'www.github.com' ? 'GitHub' : host;
}

Future<void> _openExternal(BuildContext context, String url) async {
  final uri = Uri.tryParse(url);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final opened =
      uri != null &&
      await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      ).catchError((Object _) => false);
  if (!opened) {
    messenger?.showSnackBar(
      const SnackBar(content: Text('Could not open the link')),
    );
  }
}
