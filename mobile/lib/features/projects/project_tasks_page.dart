import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../shared/relay/relay.dart';
import '../../shared/theme/theme.dart';
import '../../shared/widgets/frosted_app_bar.dart';
import '../../shared/widgets/frosted_scaffold.dart';
import 'project_tasks_view.dart';

/// Project Tasks on their own page, for every repository in [repositories].
class ProjectTasksPage extends ConsumerWidget {
  const ProjectTasksPage({
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
    final viewer = ref.watch(myPubkeyProvider);
    return FrostedScaffold(
      useUtilitySurfaceTheme: true,
      appBar: const FrostedAppBar(title: Text('Tasks')),
      floatingActionButton: viewer == null || repositories.isEmpty
          ? null
          : NewProjectTaskButton(
              onPressed: () => startProjectTask(
                context,
                ref,
                repositories: repositories,
                repositoryChannels: repositoryChannels,
                channelId: channelId,
              ),
            ),
      body: RefreshIndicator(
        edgeOffset: frostedAppBarHeight(context),
        onRefresh: () => refreshProjectTasks(ref, repositories.keys),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.only(
            top: frostedAppBarHeight(context) + Grid.half,
            bottom: MediaQuery.viewPaddingOf(context).bottom + Grid.xxxl,
          ),
          children: [
            ProjectTasksSection(
              repositories: repositories,
              channelId: channelId,
              repositoryChannels: repositoryChannels,
            ),
          ],
        ),
      ),
    );
  }
}

/// The floating button that creates a task.
class NewProjectTaskButton extends StatelessWidget {
  const NewProjectTaskButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => FloatingActionButton(
    key: const ValueKey('project-tasks-new'),
    heroTag: 'project-task-fab',
    tooltip: 'Create task',
    shape: const CircleBorder(),
    onPressed: onPressed,
    child: const Icon(LucideIcons.plus),
  );
}
