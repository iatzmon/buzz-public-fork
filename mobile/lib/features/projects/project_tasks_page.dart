import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/projects/project_task_store.dart';
import '../../shared/relay/relay.dart';
import '../../shared/theme/theme.dart';
import 'project_task_compose_page.dart';
import 'project_task_detail_page.dart';

/// Project Tasks, with an explicit repository choice for multi-repo projects.
class ProjectTasksPage extends HookConsumerWidget {
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
    final selected = useState(repositories.keys.firstOrNull);
    final assignedToMe = useState(false);
    final address = repositories.containsKey(selected.value)
        ? selected.value
        : repositories.keys.firstOrNull;
    final config = ref.watch(relayConfigProvider);
    final viewer = ref.watch(myPubkeyProvider);
    final opened = useMemoized(() => (config.baseUrl, viewer));
    if (opened != (config.baseUrl, viewer)) {
      return Scaffold(
        appBar: AppBar(title: const Text('Tasks')),
        body: const Center(
          child: Text(
            'Community or account changed. Reopen Tasks to continue.',
          ),
        ),
      );
    }
    if (address == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Tasks')),
        body: const Center(
          child: Text('Add a repository to this project to use Tasks.'),
        ),
      );
    }
    final state = ref.watch(projectTaskStoreProvider(address));
    final store = ref.read(projectTaskStoreProvider(address).notifier);
    final tasks = state.tasks
        .where((task) => !assignedToMe.value || task.assignees.contains(viewer))
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tasks'),
        actions: [
          IconButton(
            tooltip: 'Refresh tasks',
            onPressed: state.loading ? null : store.refresh,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Create task',
            onPressed: viewer == null
                ? null
                : () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ProjectTaskComposePage(
                        repoAddress: address,
                        channelId: repositoryChannels[address] ?? channelId,
                        scope: config.baseUrl,
                        viewer: viewer,
                      ),
                    ),
                  ),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Grid.gutter),
            child: Column(
              children: [
                if (repositories.length > 1)
                  DropdownButtonFormField<String>(
                    key: ValueKey(address),
                    initialValue: address,
                    decoration: const InputDecoration(labelText: 'Repository'),
                    items: [
                      for (final entry in repositories.entries)
                        DropdownMenuItem(
                          value: entry.key,
                          child: Text(entry.value),
                        ),
                    ],
                    onChanged: (value) => selected.value = value,
                  ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Assigned to me'),
                  value: assignedToMe.value,
                  onChanged: (value) => assignedToMe.value = value ?? false,
                ),
                if (state.error != null)
                  Text(
                    state.error!,
                    style: TextStyle(color: context.colors.error),
                  ),
                if (state.pending.isNotEmpty)
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${state.pending.length} change(s) waiting for confirmation',
                        ),
                      ),
                      TextButton(
                        onPressed: state.sending
                            ? null
                            : () async {
                                try {
                                  await store.retryPending();
                                } catch (_) {
                                  /* Rendered from state. */
                                }
                              },
                        child: const Text('Retry send'),
                      ),
                    ],
                  ),
                if (state.loading) const LinearProgressIndicator(),
                if (state.tasks.length >= 200)
                  const Text(
                    'Showing the latest 200 tasks in this repository.',
                  ),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: store.refresh,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  if (tasks.isEmpty && !state.loading)
                    Padding(
                      padding: const EdgeInsets.all(Grid.gutter),
                      child: Text(
                        state.loaded
                            ? (assignedToMe.value
                                  ? 'No tasks assigned to you.'
                                  : 'No tasks yet.')
                            : 'Tasks are unavailable. Pull to retry.',
                      ),
                    ),
                  for (final task in tasks)
                    ListTile(
                      key: ValueKey(task.id),
                      title: Text(task.title),
                      subtitle: Text(
                        '${task.status} · ${task.assignees.length} assigned',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => ProjectTaskDetailPage(
                            repoAddress: address,
                            taskId: task.id,
                            channelId: repositoryChannels[address] ?? channelId,
                            scope: config.baseUrl,
                            viewer: viewer,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
