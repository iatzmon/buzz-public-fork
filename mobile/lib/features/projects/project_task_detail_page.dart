import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/profile/user_cache_provider.dart';
import '../../shared/projects/project_task_store.dart';
import '../../shared/projects/project_task.dart';
import '../../shared/relay/relay.dart';
import '../../shared/theme/theme.dart';

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
    final task = state.tasks.where((t) => t.id == taskId).firstOrNull;
    final profiles = ref.watch(userCacheProvider);
    final memberState = channelId == null
        ? const AsyncData<List<String>>([])
        : ref.watch(_taskMembersProvider(channelId!));
    final error = useState<String?>(null);
    final candidate = useState<String?>(null);
    final keys = <String>{...?memberState.value, ...?task?.assignees, ?viewer};
    useEffect(() {
      unawaited(ref.read(userCacheProvider.notifier).preload(keys.toList()));
      return null;
    }, [keys.join(',')]);
    String label(String key) =>
        profiles[key]?.label ??
        (key.length <= 8 ? key : '${key.substring(0, 8)}…');
    Future<void> change(String key, bool assign) async {
      if (!sameContext || task == null) return;
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

    return Scaffold(
      appBar: AppBar(
        title: const Text('Task'),
        actions: [
          IconButton(
            tooltip: 'Refresh task',
            onPressed: state.loading ? null : store.refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: !sameContext
          ? const Center(
              child: Text(
                'Community or account changed. Reopen Tasks to continue.',
              ),
            )
          : task == null
          ? const Center(
              child: Text('Task is unavailable. Refresh the task list.'),
            )
          : ListView(
              padding: const EdgeInsets.all(Grid.gutter),
              children: [
                Text(task.title, style: context.textTheme.headlineSmall),
                Text(task.status, style: context.textTheme.labelLarge),
                const SizedBox(height: Grid.xs),
                if (task.root.content.isNotEmpty)
                  GptMarkdown(task.root.content),
                const SizedBox(height: Grid.sm),
                Text('Assignees', style: context.textTheme.titleMedium),
                if (task.assignees.isEmpty) const Text('Unassigned'),
                for (final key in task.assignees)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(label(key)),
                    subtitle: SelectableText(key),
                    trailing:
                        viewer != null &&
                            (task.canManage(viewer!) || key == viewer)
                        ? IconButton(
                            tooltip: 'Unassign ${label(key)}',
                            onPressed: state.sending
                                ? null
                                : () => change(key, false),
                            icon: const Icon(Icons.person_remove_outlined),
                          )
                        : null,
                  ),
                if (viewer != null && !task.assignees.contains(viewer))
                  TextButton(
                    onPressed: state.sending
                        ? null
                        : () => change(viewer!, true),
                    child: const Text('Assign to me'),
                  ),
                if (viewer != null && task.canManage(viewer!)) ...[
                  if (memberState.hasError)
                    TextButton(
                      onPressed: () =>
                          ref.invalidate(_taskMembersProvider(channelId!)),
                      child: const Text('Could not load members. Retry'),
                    ),
                  DropdownButtonFormField<String>(
                    key: ValueKey(task.assignees.join(',')),
                    decoration: const InputDecoration(
                      labelText: 'Assign a member',
                    ),
                    items: [
                      for (final key in keys.where(
                        (key) => !task.assignees.contains(key),
                      ))
                        DropdownMenuItem(value: key, child: Text(label(key))),
                    ],
                    onChanged: state.sending
                        ? null
                        : (value) => candidate.value = value,
                  ),
                  TextButton(
                    onPressed:
                        state.sending ||
                            candidate.value == null ||
                            task.assignees.contains(candidate.value)
                        ? null
                        : () => change(candidate.value!, true),
                    child: const Text('Assign member'),
                  ),
                ] else
                  const Text(
                    'Only the task author or repository owner can assign other people. You can change your own assignment.',
                  ),
                if (error.value != null || state.error != null)
                  Text(
                    error.value ?? state.error!,
                    style: TextStyle(color: context.colors.error),
                  ),
                if (state.pending.isNotEmpty)
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
                    child: const Text('Retry pending change'),
                  ),
                const SizedBox(height: Grid.sm),
                Text('Activity', style: context.textTheme.titleMedium),
                for (final comment in task.comments)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: Grid.xxs),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label(comment.pubkey),
                          style: context.textTheme.labelLarge,
                        ),
                        GptMarkdown(comment.content),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}
