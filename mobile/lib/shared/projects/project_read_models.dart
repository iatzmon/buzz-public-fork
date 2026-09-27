import '../relay/nostr_models.dart';
import 'project_event_parsing.dart';
import 'project_models.dart';

/// Folds project, repository, and deletion events into project read models.
///
/// Mirrors Desktop's `buildProjectReadModels` followed by
/// `absorbStandaloneProjectRepositories`:
/// - addressable events are deduplicated to the newest head per coordinate;
/// - a kind:5 tombstone `a`-tagging a coordinate hides every head of that
///   coordinate created at or before the tombstone;
/// - unlisted projects are only kept for their owner ([viewerPubkey]);
/// - a repository is *claimed* by an explicit project that lists it when the
///   project owner signs the repository or is one of its maintainers;
///   unclaimed visible repositories become legacy projects;
/// - a legacy repository bound to an explicit project's home channel (or with
///   the same owner and d-tag) is absorbed into that project instead.
///
/// Results are sorted newest first.
List<Project> buildProjectReadModels({
  required List<NostrEvent> projectEvents,
  required List<NostrEvent> repositoryEvents,
  List<NostrEvent> deletionEvents = const [],
  String? relayOrigin,
  Set<String> hiddenAddresses = const {},
  String? viewerPubkey,
}) {
  final thresholds = buildDeletionThresholds(deletionEvents);
  bool isDeleted(NostrEvent event) {
    final coordinate = eventCoordinate(event);
    if (coordinate == null) return false;
    final threshold = thresholds[coordinate];
    return threshold != null && event.createdAt <= threshold;
  }

  final repositories = [
    for (final event in latestAddressableHeads(repositoryEvents))
      if (!isDeleted(event)) ?repositoryFromEvent(event, relayOrigin),
  ];
  final repositoriesByAddress = {
    for (final repository in repositories) repository.repoAddress: repository,
  };
  final visibleRepositories = [
    for (final repository in repositories)
      if (!hiddenAddresses.contains(repository.repoAddress)) repository,
  ];
  final visibleRepositoriesByAddress = {
    for (final repository in visibleRepositories)
      repository.repoAddress: repository,
  };

  final viewer = viewerPubkey?.trim().toLowerCase();
  final explicitProjects = <Project>[];
  for (final event in latestAddressableHeads(projectEvents)) {
    if (isDeleted(event)) continue;
    final project = explicitProjectFromEvent(
      event,
      repositoriesByAddress,
      visibleRepositoriesByAddress,
    );
    if (project == null) continue;
    final listingEligible =
        project.visibility != ProjectVisibility.unlisted ||
        (viewer != null && viewer.isNotEmpty && project.owner == viewer);
    if (!listingEligible || hiddenAddresses.contains(project.projectAddress)) {
      continue;
    }
    explicitProjects.add(project);
  }

  final claimed = <String>{
    for (final project in explicitProjects)
      for (final address in project.repositoryAddresses)
        if (repositoriesByAddress[address]?.authorizes(project.owner) ?? false)
          address,
  };
  final legacyProjects = [
    for (final repository in visibleRepositories)
      if (!claimed.contains(repository.repoAddress))
        legacyProjectFromRepository(repository),
  ];

  final folded = _stableSortedNewestFirst([
    ...explicitProjects,
    ...legacyProjects,
  ]);
  return List.unmodifiable(
    _stableSortedNewestFirst(absorbStandaloneProjectRepositories(folded)),
  );
}

/// Maps each `a`-tagged coordinate to its newest kind:5 tombstone time.
///
/// The relay has already verified that each tombstone's signer controls the
/// coordinate (including NIP-OA owner delegation), as Desktop assumes.
Map<String, int> buildDeletionThresholds(List<NostrEvent> deletionEvents) {
  final thresholds = <String, int>{};
  for (final event in deletionEvents) {
    if (event.kind != EventKind.deletion) continue;
    for (final tag in event.tags) {
      if (tag.length < 2 || tag[0] != 'a' || tag[1].isEmpty) continue;
      final existing = thresholds[tag[1]];
      if (existing == null || event.createdAt > existing) {
        thresholds[tag[1]] = event.createdAt;
      }
    }
  }
  return thresholds;
}

/// Keeps a legacy repository card off the list when an explicit project
/// already hosts it: bound to that project's home channel (by a repository
/// that authorizes the project owner), or same owner and d-tag.
List<Project> absorbStandaloneProjectRepositories(List<Project> projects) {
  var explicit = [
    for (final project in projects)
      if (!project.legacy) project,
  ];
  if (explicit.isEmpty) return projects;

  final absorbed = <String>{};
  for (final card in projects) {
    if (!card.legacy || card.repositories.isEmpty) continue;
    final repository = card.repositories.first;
    final host = _hostForStandaloneRepository(explicit, repository);
    if (host == null) continue;
    absorbed.add(card.projectAddress);
    explicit = [
      for (final project in explicit)
        project.projectAddress == host.projectAddress
            ? project.withAbsorbedRepository(repository)
            : project,
    ];
  }
  if (absorbed.isEmpty) return projects;
  return [
    ...explicit,
    for (final project in projects)
      if (project.legacy && !absorbed.contains(project.projectAddress)) project,
  ];
}

Project? _hostForStandaloneRepository(
  List<Project> explicitProjects,
  ProjectRepository repository,
) {
  final channelId = repository.channelId;
  if (channelId != null) {
    for (final project in explicitProjects) {
      if (project.projectChannelId == channelId &&
          repository.authorizes(project.owner)) {
        return project;
      }
    }
  }
  for (final project in explicitProjects) {
    if (project.owner == repository.owner && project.dtag == repository.dtag) {
      return project;
    }
  }
  return null;
}

/// `kind:owner:dtag` coordinate of an addressable event (first `d` tag), or
/// null without a non-empty `d` tag.
String? eventCoordinate(NostrEvent event) {
  for (final tag in event.tags) {
    if (tag.isNotEmpty && tag[0] == 'd') {
      if (tag.length < 2 || tag[1].isEmpty) return null;
      return '${event.kind}:${event.pubkey.toLowerCase()}:${tag[1]}';
    }
  }
  return null;
}

/// Newest head per coordinate; ties break toward the lexically lower id.
List<NostrEvent> latestAddressableHeads(List<NostrEvent> events) {
  final latest = <String, NostrEvent>{};
  for (final event in events) {
    final key = eventCoordinate(event);
    if (key == null) continue;
    final current = latest[key];
    if (current == null ||
        event.createdAt > current.createdAt ||
        (event.createdAt == current.createdAt &&
            event.id.compareTo(current.id) < 0)) {
      latest[key] = event;
    }
  }
  return latest.values.toList(growable: false);
}

/// Dart's [List.sort] is not stable; Desktop relies on a stable sort.
List<Project> _stableSortedNewestFirst(List<Project> projects) {
  final indexed = [for (var i = 0; i < projects.length; i++) (i, projects[i])];
  indexed.sort((left, right) {
    final byTime = right.$2.createdAt.compareTo(left.$2.createdAt);
    return byTime != 0 ? byTime : left.$1.compareTo(right.$1);
  });
  return [for (final entry in indexed) entry.$2];
}
