import 'dart:math' as math;

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

/// Items shown per page of the Activity feed, and channel messages read per
/// page.
const projectActivityPageSize = 40;

/// Event kinds that change or remove a channel message.
const projectMessageChangeKinds = [
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

/// One page of channel messages for the Activity feed.
class ProjectMessagePage {
  const ProjectMessagePage({
    this.messages = const [],
    this.changes = const [],
    this.full = false,
    this.oldest,
  });

  /// Channel messages in this page.
  final List<NostrEvent> messages;

  /// Edits and deletions that name [messages].
  final List<NostrEvent> changes;

  /// The relay returned a whole page, so older messages may exist.
  final bool full;

  /// Oldest timestamp the relay returned for this page.
  final int? oldest;
}

/// The page key: [channels] are the sorted channel ids joined by commas.
/// `until` is the newest timestamp to read (inclusive); null reads the newest.
typedef ProjectMessagePageKey = ({String channels, int? until});

/// The page key for [channelIds], starting at [until].
ProjectMessagePageKey projectMessagePageKey(
  Iterable<String> channelIds, {
  int? until,
}) => (channels: (channelIds.toList()..sort()).join(','), until: until);

/// One page of messages in the project's channels, with the edits and
/// deletions that name them. Pages read only message kinds, so edits and
/// deletions never fill a page and hide older messages.
final projectMessagePageProvider = FutureProvider.autoDispose
    .family<ProjectMessagePage, ProjectMessagePageKey>((ref, key) async {
      ref.watch(relayConfigProvider);
      final transport = ref.watch(projectTaskTransportProvider);
      final channels = key.channels
          .split(',')
          .where((id) => id.isNotEmpty)
          .toList();
      if (channels.isEmpty) return const ProjectMessagePage();
      final returned = await transport.query(
        NostrFilter(
          kinds: EventKind.channelMessageEventKinds,
          tags: {'#h': channels},
          limit: projectActivityPageSize,
          until: key.until,
        ),
      );
      final messages = [
        for (final event in returned)
          if (EventKind.channelMessageEventKinds.contains(event.kind)) event,
      ];
      final changes = messages.isEmpty
          ? const <NostrEvent>[]
          : [
              for (final event in await transport.query(
                NostrFilter(
                  kinds: projectMessageChangeKinds,
                  tags: {
                    '#h': channels,
                    '#e': [for (final m in messages) m.id],
                  },
                  limit: 500,
                ),
              ))
                if (projectMessageChangeKinds.contains(event.kind)) event,
            ];
      return ProjectMessagePage(
        messages: messages,
        changes: changes,
        full: returned.length >= projectActivityPageSize,
        oldest: returned.isEmpty
            ? null
            : returned.map((e) => e.createdAt).reduce(math.min),
      );
    });
