import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../shared/projects/projects.dart';
import '../../shared/theme/theme.dart';
import '../../shared/widgets/adaptive_workspace.dart';
import '../channels/channel.dart';
import '../channels/channel_detail_page.dart';
import '../channels/channels_provider.dart';

/// The channel with [channelId] from the loaded channel list, or null.
Channel? findLoadedChannel(WidgetRef ref, String channelId) {
  final channels = ref.read(channelsProvider).value;
  for (final channel in channels ?? const <Channel>[]) {
    if (channel.id == channelId) return channel;
  }
  return null;
}

/// Opens [project]'s home channel. Falls back to [ProjectPage] when the home
/// channel is not in the loaded channel list (for example, a private home
/// the viewer cannot see).
Future<void> openProject(
  BuildContext context,
  WidgetRef ref,
  Project project,
) async {
  final homeId = project.projectChannelId;
  final home = homeId == null ? null : findLoadedChannel(ref, homeId);
  final route = MaterialPageRoute<void>(
    builder: (_) => home == null
        ? ProjectPage(projectAddress: project.projectAddress)
        : ChannelDetailPage(channel: home),
  );
  await AdaptiveWorkspace.open(context, route);
}

/// A project's channels and repositories.
class ProjectPage extends ConsumerWidget {
  const ProjectPage({super.key, required this.projectAddress});

  /// `30621:<owner>:<dtag>` coordinate of the project.
  final String projectAddress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshotAsync = ref.watch(activeProjectsProvider);
    final snapshot = snapshotAsync.value;
    final project = ref.watch(projectByAddressProvider(projectAddress));
    final added = ref
        .watch(projectSidebarMembershipProvider)
        .selectedAddresses
        .contains(projectAddress);

    if (project == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Project')),
        body: Center(
          child: snapshot == null && snapshotAsync.isLoading
              ? const CircularProgressIndicator()
              : const Padding(
                  padding: EdgeInsets.all(Grid.gutter),
                  child: Text(
                    'This project is not available. It may have been '
                    'deleted, or it belongs to another community.',
                    textAlign: TextAlign.center,
                  ),
                ),
        ),
      );
    }

    final channels = ref.watch(channelsProvider).value ?? const <Channel>[];
    final channelsById = {for (final c in channels) c.id: c};
    final boundChannels = listProjectBoundChannels(project);
    final relayOrigin = snapshot?.scope.relayOrigin;

    return Scaffold(
      appBar: AppBar(
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
      ),
      body: RefreshIndicator(
        onRefresh: () async =>
            ref.read(activeProjectsNotifierProvider)?.refresh(),
        child: ListView(
          padding: const EdgeInsets.only(bottom: Grid.lg),
          children: [
            if (snapshot?.fromCache ?? false)
              _Notice(
                icon: LucideIcons.cloudOff,
                text: 'Saved copy. It may be out of date.',
              ),
            if (project.description.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Grid.gutter,
                  Grid.xs,
                  Grid.gutter,
                  Grid.xxs,
                ),
                child: Text(
                  project.description.trim(),
                  style: context.textTheme.bodyMedium,
                ),
              ),
            const _SectionTitle('Channels'),
            if (boundChannels.isEmpty)
              const _EmptyRow('This project has no channels.')
            else
              for (final bound in boundChannels)
                _ChannelRow(
                  bound: bound,
                  channel: channelsById[bound.channelId],
                  repositoryName: _repositoryName(project, bound.repositoryId),
                ),
            const _SectionTitle('Repositories'),
            if (project.repositories.isEmpty &&
                project.unavailableRepositoryAddresses.isEmpty)
              const _EmptyRow('This project has no repositories.')
            else ...[
              for (final repository in project.repositories)
                _RepositoryRow(
                  repository: repository,
                  relayOrigin: relayOrigin,
                ),
              if (project.unavailableRepositoryAddresses.isNotEmpty)
                _EmptyRow(
                  project.unavailableRepositoryAddresses.length == 1
                      ? '1 repository is not available.'
                      : '${project.unavailableRepositoryAddresses.length} '
                            'repositories are not available.',
                ),
            ],
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

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      Grid.gutter,
      Grid.sm,
      Grid.gutter,
      Grid.xxs,
    ),
    child: Semantics(
      header: true,
      child: Text(
        label,
        style: context.textTheme.titleSmall?.copyWith(
          color: context.colors.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  );
}

class _EmptyRow extends StatelessWidget {
  const _EmptyRow(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: Grid.gutter,
      vertical: Grid.xxs,
    ),
    child: Text(
      text,
      style: context.textTheme.bodyMedium?.copyWith(
        color: context.colors.onSurfaceVariant,
      ),
    ),
  );
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(Grid.gutter, Grid.xs, Grid.gutter, 0),
    child: Row(
      children: [
        Icon(icon, size: 16, color: context.colors.onSurfaceVariant),
        const SizedBox(width: Grid.xxs),
        Expanded(
          child: Text(
            text,
            style: context.textTheme.bodySmall?.copyWith(
              color: context.colors.onSurfaceVariant,
            ),
          ),
        ),
      ],
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

    return ListTile(
      key: ValueKey('project-channel-${bound.channelId}'),
      enabled: channel != null,
      leading: Icon(
        channel == null ? LucideIcons.hash : channelIcon(channel),
        size: 20,
      ),
      title: Text(
        channel == null ? 'Unavailable channel' : channel.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: subtitle.isEmpty ? null : Text(subtitle),
      onTap: channel == null
          ? null
          : () => AdaptiveWorkspace.open(
              context,
              MaterialPageRoute<void>(
                builder: (_) => ChannelDetailPage(channel: channel),
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

    return ListTile(
      key: ValueKey('project-repository-${repository.repoAddress}'),
      leading: const Icon(LucideIcons.folderGit2, size: 20),
      title: Text(
        repository.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        [?path, hostLabel].join('\n'),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      isThreeLine: path != null,
      trailing: externalUrl == null
          ? null
          : TextButton(
              key: ValueKey('project-repository-open-${repository.dtag}'),
              onPressed: () => _openExternal(context, externalUrl),
              child: Text('Open on ${_shortHost(hostName)}'),
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
