import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'project_event_set.dart';
import 'project_home.dart' as home;
import 'project_models.dart';

/// The community and identity a project collection belongs to.
///
/// Records compare structurally, so a scope change keys a fresh collection
/// and cache entry and never leaks one community's projects into another.
typedef ProjectScope = ({
  String relayBaseUrl,
  String? relayOrigin,
  String viewerPubkey,
});

/// One complete project collection for a scope.
@immutable
class ProjectsSnapshot {
  final ProjectScope scope;

  /// Explicit and legacy projects, newest first.
  final List<Project> projects;

  /// When the underlying events were fetched from the relay.
  final DateTime fetchedAt;

  /// True when restored from the device cache rather than fetched in this
  /// session. The UI may flag it as possibly out of date.
  final bool fromCache;

  const ProjectsSnapshot({
    required this.scope,
    required this.projects,
    required this.fetchedAt,
    this.fromCache = false,
  });

  /// Folds [events] for [scope].
  factory ProjectsSnapshot.fromEvents(
    ProjectScope scope,
    ProjectEventSet events, {
    required DateTime fetchedAt,
    bool fromCache = false,
  }) => ProjectsSnapshot(
    scope: scope,
    projects: events.buildProjects(
      relayOrigin: scope.relayOrigin,
      viewerPubkey: scope.viewerPubkey,
    ),
    fetchedAt: fetchedAt,
    fromCache: fromCache,
  );

  /// The relay origin used for clone-URL derivation and host classification.
  String? get relayOrigin => scope.relayOrigin;

  /// The canonical project whose home is [channelId] (stream or forum).
  Project? projectHomeForChannel(String? channelId) =>
      home.findProjectHomeByChannelId(channelId, projects);

  /// Whether any project authoritatively claims [channelId] as its home.
  bool isProjectHomeChannel(String? channelId) =>
      home.isProjectHomeChannel(channelId, projects);

  /// The project with [projectAddress], or null.
  Project? projectByAddress(String projectAddress) {
    for (final project in projects) {
      if (project.projectAddress == projectAddress) return project;
    }
    return null;
  }
}

const _cacheKeyBase = 'buzz.projects.snapshot.v1';
const _cacheVersion = 1;

/// Collections larger than this stay in memory only.
const maxCachedProjectEvents = 5000;

/// The device-cache key for [scope]'s last-good project events.
String projectSnapshotCacheKey(ProjectScope scope) =>
    '$_cacheKeyBase:${scope.relayBaseUrl}:${scope.viewerPubkey}';

/// The last-good snapshot cached for [scope], or null when none is usable.
ProjectsSnapshot? readCachedProjectsSnapshot(
  SharedPreferences prefs,
  ProjectScope scope,
) {
  final raw = prefs.getString(projectSnapshotCacheKey(scope));
  if (raw == null || raw.isEmpty) return null;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map || decoded['version'] != _cacheVersion) return null;
    final fetchedAtMs = decoded['fetchedAt'];
    final events = ProjectEventSet.fromJson(decoded['events']);
    if (fetchedAtMs is! int || events == null) return null;
    return ProjectsSnapshot.fromEvents(
      scope,
      events,
      fetchedAt: DateTime.fromMillisecondsSinceEpoch(fetchedAtMs),
      fromCache: true,
    );
  } on FormatException {
    return null;
  }
}

/// Caches [events] (compacted) as [scope]'s last-good snapshot. Resolves to
/// whether it was written; the cache is derived data, so failure only costs
/// the next cold start its instant paint.
Future<bool> writeCachedProjectEvents(
  SharedPreferences prefs,
  ProjectScope scope,
  ProjectEventSet events,
  DateTime fetchedAt,
) async {
  final compact = events.compact();
  final key = projectSnapshotCacheKey(scope);
  if (compact.length > maxCachedProjectEvents) {
    debugPrint('[projects] collection too large to cache: ${compact.length}');
    await prefs.remove(key);
    return false;
  }
  return prefs.setString(
    key,
    jsonEncode({
      'version': _cacheVersion,
      'fetchedAt': fetchedAt.millisecondsSinceEpoch,
      'events': compact.toJson(),
    }),
  );
}
