import 'project_models.dart';

/// How a channel is bound to a project.
enum ProjectChannelRole { home, related }

/// One channel bound to a project.
typedef ProjectBoundChannel = ({
  String channelId,
  String? repositoryId,
  ProjectChannelRole role,
});

String? _trimmedChannelId(String? value) {
  final channelId = value?.trim() ?? '';
  return channelId.isEmpty ? null : channelId;
}

/// Unique channels bound to [project]: the home channel first, then related
/// channels, then each repository channel not already listed.
///
/// Mirrors `listProjectBoundChannels` in
/// `desktop/src/features/projects/lib/projectRelatedChannels.ts`.
List<ProjectBoundChannel> listProjectBoundChannels(Project project) {
  final channels = <ProjectBoundChannel>[];
  final seen = <String>{};
  final homeChannelId = _trimmedChannelId(project.projectChannelId);
  if (homeChannelId != null) {
    channels.add((
      channelId: homeChannelId,
      repositoryId: null,
      role: ProjectChannelRole.home,
    ));
    seen.add(homeChannelId);
  }
  for (final related in project.relatedChannelIds) {
    final channelId = _trimmedChannelId(related);
    if (channelId == null || !seen.add(channelId)) continue;
    channels.add((
      channelId: channelId,
      repositoryId: null,
      role: ProjectChannelRole.related,
    ));
  }
  for (final repository in project.repositories) {
    final channelId = _trimmedChannelId(repository.channelId);
    if (channelId == null || !seen.add(channelId)) continue;
    channels.add((
      channelId: channelId,
      repositoryId: repository.id,
      role: ProjectChannelRole.related,
    ));
  }
  return channels;
}
