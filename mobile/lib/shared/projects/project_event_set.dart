import 'package:flutter/foundation.dart';

import '../relay/nostr_models.dart';
import 'project_models.dart';
import 'project_read_models.dart';

/// The relay events a project collection is derived from.
///
/// Read models are always folded from events, so a persisted set can be
/// discarded and re-fetched at any time.
@immutable
class ProjectEventSet {
  final List<NostrEvent> projectEvents;
  final List<NostrEvent> repositoryEvents;
  final List<NostrEvent> deletionEvents;

  const ProjectEventSet({
    required this.projectEvents,
    required this.repositoryEvents,
    required this.deletionEvents,
  });

  /// Total number of events in the set.
  int get length =>
      projectEvents.length + repositoryEvents.length + deletionEvents.length;

  /// Folds the set into read models (see [buildProjectReadModels]).
  List<Project> buildProjects({
    required String? relayOrigin,
    required String? viewerPubkey,
  }) => buildProjectReadModels(
    projectEvents: projectEvents,
    repositoryEvents: repositoryEvents,
    deletionEvents: deletionEvents,
    relayOrigin: relayOrigin,
    viewerPubkey: viewerPubkey,
  );

  /// The newest head per coordinate plus only the tombstones addressing those
  /// coordinates; folds to the same read models with fewer events.
  ProjectEventSet compact() {
    final projects = latestAddressableHeads(projectEvents);
    final repositories = latestAddressableHeads(repositoryEvents);
    final coordinates = {
      for (final event in [...projects, ...repositories])
        ?eventCoordinate(event),
    };
    return ProjectEventSet(
      projectEvents: projects,
      repositoryEvents: repositories,
      deletionEvents: [
        for (final event in deletionEvents)
          if (event.tags.any(
            (tag) =>
                tag.length > 1 && tag[0] == 'a' && coordinates.contains(tag[1]),
          ))
            event,
      ],
    );
  }

  /// JSON form for the local snapshot cache.
  Map<String, Object> toJson() => {
    'projects': [for (final event in projectEvents) event.toJson()],
    'repositories': [for (final event in repositoryEvents) event.toJson()],
    'deletions': [for (final event in deletionEvents) event.toJson()],
  };

  /// Parses [toJson] output; null for anything malformed (the cache is
  /// discardable). Events of unexpected kinds are dropped.
  static ProjectEventSet? fromJson(Object? json) {
    if (json is! Map) return null;
    try {
      List<NostrEvent> events(String key, int kind) => [
        for (final event in json[key] as List)
          NostrEvent.fromJson(Map<String, dynamic>.from(event as Map)),
      ].where((event) => event.kind == kind).toList(growable: false);
      return ProjectEventSet(
        projectEvents: events('projects', EventKind.projectAnnouncement),
        repositoryEvents: events('repositories', EventKind.repoAnnouncement),
        deletionEvents: events('deletions', EventKind.deletion),
      );
    } on Object {
      return null;
    }
  }
}
