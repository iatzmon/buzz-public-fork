import 'project_models.dart';

/// Whether [project]'s `buzz-channel` home binding is authoritative: at least
/// one member repository is bound to the same channel and authorizes the
/// project owner (signer or maintainer).
///
/// Mirrors `hasAuthoritativeHomeBinding` in
/// `desktop/src/features/projects/lib/projectHomeSelection.ts`.
bool hasAuthoritativeHomeBinding(Project project) {
  final channelId = project.projectChannelId;
  if (channelId == null) return false;
  return project.repositories.any(
    (repository) =>
        repository.channelId == channelId &&
        repository.authorizes(project.owner),
  );
}

/// The canonical visible project whose home is [channelId], or null.
///
/// Home channels may be streams or forums; matching is by channel id only.
/// Among several explicit projects with an authoritative binding, the oldest
/// listed one wins, else the oldest unlisted one.
Project? findProjectHomeByChannelId(
  String? channelId,
  Iterable<Project> projects,
) {
  if (channelId == null || channelId.isEmpty) return null;
  final matching = [
    for (final project in projects)
      if (!project.legacy &&
          project.projectChannelId == channelId &&
          hasAuthoritativeHomeBinding(project))
        project,
  ];
  if (matching.isEmpty) return null;
  // Oldest first; ties keep input order (Desktop's stable sort).
  final indexed = [for (var i = 0; i < matching.length; i++) (i, matching[i])]
    ..sort((a, b) {
      final byTime = a.$2.createdAt.compareTo(b.$2.createdAt);
      return byTime != 0 ? byTime : a.$1.compareTo(b.$1);
    });
  for (final (_, project) in indexed) {
    if (project.visibility != ProjectVisibility.unlisted) return project;
  }
  return indexed.first.$2;
}

/// Whether any project authoritatively claims [channelId] as its home.
bool isProjectHomeChannel(String? channelId, Iterable<Project> projects) {
  if (channelId == null || channelId.isEmpty) return false;
  return projects.any(
    (project) =>
        project.projectChannelId == channelId &&
        hasAuthoritativeHomeBinding(project),
  );
}
