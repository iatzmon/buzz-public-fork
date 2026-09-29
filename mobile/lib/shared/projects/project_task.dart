import '../relay/nostr_models.dart';

/// A NIP-34 task and its trusted lifecycle and assignment history.
class ProjectTask {
  const ProjectTask({
    required this.root,
    required this.status,
    required this.assignees,
    required this.assignmentHeads,
    required this.comments,
    this.statusNotes = const [],
    this.appliedAssignmentIds = const {},
    this.communityOwners = const {},
  });

  final NostrEvent root;
  final String status;
  final Set<String> assignees;
  final Map<String, String> assignmentHeads;

  /// Ids of the assignment operations that changed [assignees]. Activity
  /// shows only these, so it never reports a change the state ignored.
  final Set<String> appliedAssignmentIds;
  final List<NostrEvent> comments;

  /// Status events that carry a note, from any signer. The note is shown
  /// even when the signer cannot change the status.
  final List<NostrEvent> statusNotes;

  /// Comments and status notes, oldest first.
  List<NostrEvent> get activity =>
      [...comments, ...statusNotes]..sort(compareEvents);

  /// Community owners (lowercase hex) who may manage every task.
  final Set<String> communityOwners;

  String get id => root.id;
  String get repoAddress => root.getTagValue('a') ?? '';
  String get repoOwner => repoAddress.split(':').elementAtOrNull(1) ?? '';
  String get title =>
      root.getTagValue('subject') ??
      (root.content.isEmpty ? 'Untitled task' : root.content.split('\n').first);
  bool canManage(String pubkey) =>
      projectTaskCanManage(root, pubkey, communityOwners: communityOwners);

  /// Match Desktop's deterministic ordering within a signed timestamp.
  static int compareEvents(NostrEvent a, NostrEvent b) {
    final time = a.createdAt.compareTo(b.createdAt);
    return time == 0 ? a.id.compareTo(b.id) : time;
  }

  /// Notification recipients on the root never imply task assignment.
  ///
  /// [communityOwners] come from the relay's signed community member list.
  factory ProjectTask.fromEvents(
    NostrEvent root,
    List<NostrEvent> related, {
    Set<String> communityOwners = const {},
  }) {
    bool canManage(String pubkey) =>
        projectTaskCanManage(root, pubkey, communityOwners: communityOwners);
    bool targets(NostrEvent e) => e.tags.any(
      (tag) =>
          tag.length > 1 && tag[0].toLowerCase() == 'e' && tag[1] == root.id,
    );
    final events = related.where(targets).toList()..sort(compareEvents);
    final statuses = related.where(
      (e) =>
          e.tags.any(
            (tag) => tag.length > 1 && tag[0] == 'e' && tag[1] == root.id,
          ) &&
          e.kind >= 1630 &&
          e.kind <= 1633 &&
          canManage(e.pubkey),
    );
    NostrEvent? latest;
    for (final event in statuses) {
      if (latest == null || event.createdAt > latest.createdAt) latest = event;
    }
    final labels = _tags(root, 't').map((v) => v.toLowerCase()).toSet();
    final status = switch (latest?.kind) {
      1631 => 'Done',
      1632 => 'Closed',
      1633 => 'Triage',
      _ when labels.contains('in-review') || labels.contains('review') =>
        'In Review',
      _ when labels.contains('in-progress') || labels.contains('active') =>
        'In Progress',
      _ when labels.contains('triage') => 'Triage',
      _ => 'Backlog',
    };
    final comments = events
        .where((e) => e.kind == 1 || e.kind == 1111)
        .toList();
    // Same target rule as [statuses], so an action label is never shown for
    // a status event this task ignored.
    final statusNotes = events
        .where(
          (e) =>
              e.kind >= 1630 &&
              e.kind <= 1633 &&
              e.content.trim().isNotEmpty &&
              e.tags.any(
                (tag) => tag.length > 1 && tag[0] == 'e' && tag[1] == root.id,
              ),
        )
        .toList();
    final self = <NostrEvent>[];
    final authority = <NostrEvent>[];
    final causal = <NostrEvent>[];
    for (final event in comments.where(
      (e) =>
          e.kind == 1 &&
          e.tags.any(
            (tag) => tag.length > 1 && tag[0] == 'e' && tag[1] == root.id,
          ),
    )) {
      final labels = _tags(event, 't');
      if (labels.contains('assignment') == labels.contains('unassignment')) {
        continue;
      }
      final keys = _tags(event, 'p').map((v) => v.toLowerCase()).toList();
      if (keys.isEmpty ||
          keys.any((key) => !isProjectTaskPubkey(key)) ||
          event.tags.any(
            (tag) =>
                tag.isNotEmpty &&
                tag[0] == 'p' &&
                (tag.length < 2 || !isProjectTaskPubkey(tag[1])),
          )) {
        continue;
      }
      final signer = event.pubkey.toLowerCase();
      if (canManage(signer)) {
        authority.add(event);
      } else if (keys.length == 1 && keys.single == signer) {
        final priors = event.tags
            .where((t) => t.isNotEmpty && t[0] == 'prior')
            .toList();
        if (priors.isEmpty) {
          self.add(event);
        } else if (priors.length == 1 &&
            priors.single.length > 1 &&
            RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(priors.single[1])) {
          causal.add(event);
        }
      }
    }
    final assignees = <String>{};
    final heads = <String, String>{};
    final applied = <String>{};
    for (final event in [...self, ...authority, ...causal]) {
      final keys = _tags(event, 'p').map((v) => v.toLowerCase()).toList();
      if (causal.contains(event) &&
          heads[keys.single] != event.getTagValue('prior')?.toLowerCase()) {
        continue;
      }
      for (final key in keys) {
        if (_tags(event, 't').contains('assignment')) {
          assignees.add(key);
        } else {
          assignees.remove(key);
        }
        heads[key] = event.id.toLowerCase();
      }
      applied.add(event.id);
    }
    return ProjectTask(
      root: root,
      status: status,
      assignees: Set.unmodifiable(assignees),
      assignmentHeads: Map.unmodifiable(heads),
      appliedAssignmentIds: Set.unmodifiable(applied),
      communityOwners: communityOwners,
      comments: List.unmodifiable(comments),
      statusNotes: List.unmodifiable(statusNotes),
    );
  }

  /// Avoid same-second local writes being reordered by the event-id tie break.
  int nextOperationTime(String signer, int now) => comments
      .where((e) => e.pubkey.toLowerCase() == signer.toLowerCase())
      .fold(
        now,
        (time, event) => event.createdAt >= time ? event.createdAt + 1 : time,
      );
}

List<String> _tags(NostrEvent event, String name) => [
  for (final tag in event.tags)
    if (tag.length > 1 && tag[0] == name && tag[1].isNotEmpty) tag[1],
];

/// Wire tags shared by Desktop, CLI, and mobile task creation.
List<List<String>> projectTaskTags({
  required String repoAddress,
  required String title,
}) {
  if (!RegExp(r'^30617:[a-fA-F0-9]{64}:.+$').hasMatch(repoAddress)) {
    throw ArgumentError('A valid repository is required.');
  }
  final subject = title.trim();
  if (subject.isEmpty || subject.length > 256) {
    throw ArgumentError('Task title must be between 1 and 256 characters.');
  }
  return [
    ['a', repoAddress],
    ['p', repoAddress.split(':')[1].toLowerCase()],
    ['subject', subject],
  ];
}

/// Only authors/owners assign others; everyone can assign/unassign themselves.
List<List<String>> projectTaskAssignmentTags({
  required ProjectTask task,
  required String signer,
  required String assignee,
  required bool assign,
}) {
  final key = assignee.toLowerCase();
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(key) ||
      (!task.canManage(signer) && signer.toLowerCase() != key)) {
    throw ArgumentError(
      'You can only change your own assignment on this task.',
    );
  }
  final prior = key == signer.toLowerCase() ? task.assignmentHeads[key] : null;
  return [
    ['e', task.id, '', 'root'],
    ['a', task.repoAddress],
    ['p', key],
    ['t', assign ? 'assignment' : 'unassignment'],
    if (prior != null) ['prior', prior],
  ];
}

/// Shared authority rule for reads and writes: the task author, the
/// repository owner, or a community owner. Agent ownership alone is not
/// signing authority.
bool projectTaskCanManage(
  NostrEvent root,
  String pubkey, {
  Set<String> communityOwners = const {},
}) {
  final owner = (root.getTagValue('a') ?? '').split(':').elementAtOrNull(1);
  final signer = pubkey.toLowerCase();
  return signer == root.pubkey.toLowerCase() ||
      signer == owner?.toLowerCase() ||
      communityOwners.contains(signer);
}

/// Assignee identity tags must contain a complete Nostr public key.
bool isProjectTaskPubkey(String key) =>
    RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(key);
