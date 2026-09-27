import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/projects/project_task.dart';
import '../../shared/projects/project_task_store.dart';
import '../../shared/relay/relay.dart';

/// What happened in a project activity item.
enum ProjectActivityKind {
  taskCreated,
  taskStatus,
  taskAssigned,
  taskUnassigned,
  taskComment,
  message,
}

/// One entry in a project's Activity feed.
class ProjectActivityItem {
  const ProjectActivityItem({
    required this.kind,
    required this.id,
    required this.actor,
    required this.createdAt,
    this.task,
    this.repoAddress,
    this.status,
    this.targets = const [],
    this.text = '',
    this.channelId,
  });

  final ProjectActivityKind kind;

  /// Id of the event this item shows.
  final String id;

  /// Signer of the event.
  final String actor;
  final int createdAt;

  /// The task, for task items.
  final ProjectTask? task;
  final String? repoAddress;

  /// The new status, for [ProjectActivityKind.taskStatus].
  final String? status;

  /// Assignees changed, for assignment items.
  final List<String> targets;

  /// Comment or message text.
  final String text;

  /// The channel, for [ProjectActivityKind.message].
  final String? channelId;
}

/// Kinds of the task status events.
const _statusKinds = {1630, 1631, 1632, 1633};

String _statusLabel(int kind) => switch (kind) {
  1631 => 'Done',
  1632 => 'Closed',
  1633 => 'Triage',
  _ => 'Open',
};

bool _hasLabel(NostrEvent event, String label) =>
    event.tags.any((tag) => tag.length > 1 && tag[0] == 't' && tag[1] == label);

/// Activity items from one repository's task events. Only operations the task
/// state trusts are shown: status changes by someone who may manage the task,
/// and assignment changes the reducer applied.
List<ProjectActivityItem> projectTaskActivity(
  String repoAddress,
  ProjectTaskState state, {
  Set<String> communityOwners = const {},
}) {
  final items = <ProjectActivityItem>[];
  for (final task in state.tasksWith(communityOwners)) {
    final root = task.root;
    items.add(
      ProjectActivityItem(
        kind: ProjectActivityKind.taskCreated,
        id: root.id,
        actor: root.pubkey.toLowerCase(),
        createdAt: root.createdAt,
        task: task,
        repoAddress: repoAddress,
      ),
    );
    for (final event in state.events) {
      if (!_statusKinds.contains(event.kind)) continue;
      final targetsRoot = event.tags.any(
        (tag) => tag.length > 1 && tag[0] == 'e' && tag[1] == root.id,
      );
      if (!targetsRoot || !task.canManage(event.pubkey)) continue;
      items.add(
        ProjectActivityItem(
          kind: ProjectActivityKind.taskStatus,
          id: event.id,
          actor: event.pubkey.toLowerCase(),
          createdAt: event.createdAt,
          task: task,
          repoAddress: repoAddress,
          status: _statusLabel(event.kind),
        ),
      );
    }
    for (final event in task.comments) {
      final isAssignment =
          _hasLabel(event, 'assignment') || _hasLabel(event, 'unassignment');
      if (isAssignment) {
        if (!task.appliedAssignmentIds.contains(event.id)) continue;
        items.add(
          ProjectActivityItem(
            kind: _hasLabel(event, 'assignment')
                ? ProjectActivityKind.taskAssigned
                : ProjectActivityKind.taskUnassigned,
            id: event.id,
            actor: event.pubkey.toLowerCase(),
            createdAt: event.createdAt,
            task: task,
            repoAddress: repoAddress,
            targets: [
              for (final tag in event.tags)
                if (tag.length > 1 && tag[0] == 'p') tag[1].toLowerCase(),
            ],
          ),
        );
      } else {
        items.add(
          ProjectActivityItem(
            kind: ProjectActivityKind.taskComment,
            id: event.id,
            actor: event.pubkey.toLowerCase(),
            createdAt: event.createdAt,
            task: task,
            repoAddress: repoAddress,
            text: event.content,
          ),
        );
      }
    }
  }
  return items;
}

/// Event kinds read for channel messages in the Activity feed.
const projectMessageKinds = [
  ...EventKind.channelMessageEventKinds,
  EventKind.deletion,
  EventKind.nip29DeleteEvent,
  EventKind.streamMessageEdit,
];

/// Activity items from channel events. Hides any message that a deletion
/// event names, and shows the author's latest edit.
List<ProjectActivityItem> projectMessageActivity(List<NostrEvent> events) {
  final deleted = <String>{};
  for (final event in events) {
    if (event.kind != EventKind.deletion &&
        event.kind != EventKind.nip29DeleteEvent) {
      continue;
    }
    for (final tag in event.tags) {
      if (tag.length > 1 && tag[0] == 'e') deleted.add(tag[1]);
    }
  }
  final messages = {
    for (final event in events)
      if (EventKind.channelMessageEventKinds.contains(event.kind) &&
          !deleted.contains(event.id))
        event.id: event,
  };
  final edits = <String, NostrEvent>{};
  for (final event in events) {
    if (event.kind != EventKind.streamMessageEdit ||
        deleted.contains(event.id)) {
      continue;
    }
    String? target;
    for (final tag in event.tags) {
      if (tag.length > 1 && tag[0] == 'e') target = tag[1];
    }
    final original = messages[target];
    if (original == null || original.pubkey != event.pubkey) continue;
    final existing = edits[target];
    if (existing == null || event.createdAt > existing.createdAt) {
      edits[target!] = event;
    }
  }
  return [
    for (final message in messages.values)
      if (message.getTagValue('h') case final channelId?)
        ProjectActivityItem(
          kind: ProjectActivityKind.message,
          id: message.id,
          actor: message.pubkey.toLowerCase(),
          createdAt: message.createdAt,
          channelId: channelId,
          text: (edits[message.id] ?? message).content,
        ),
  ];
}

/// Recent events in the project's channels, verified before use. The key is
/// the sorted channel ids joined by commas, then `|` and the event limit.
final projectChannelActivityProvider = FutureProvider.autoDispose
    .family<List<NostrEvent>, String>((ref, key) async {
      ref.watch(relayConfigProvider);
      final transport = ref.watch(projectTaskTransportProvider);
      final parts = key.split('|');
      final channels = parts.first
          .split(',')
          .where((id) => id.isNotEmpty)
          .toList();
      if (channels.isEmpty) return const [];
      return transport.query(
        NostrFilter(
          kinds: projectMessageKinds,
          tags: {'#h': channels},
          limit: int.parse(parts.last),
        ),
      );
    });

/// The provider key for [channelIds] and [limit].
String projectChannelActivityKey(Iterable<String> channelIds, int limit) =>
    '${(channelIds.toList()..sort()).join(',')}|$limit';
