import 'package:buzz/shared/projects/projects.dart';
import 'package:flutter_test/flutter_test.dart';

ProjectRepository _repo(String dtag, String? channelId) => ProjectRepository(
  id: 'owner:$dtag',
  dtag: dtag,
  name: dtag,
  description: '',
  cloneUrls: const [],
  webUrl: null,
  owner: 'owner',
  contributors: const [],
  createdAt: 1,
  status: 'active',
  defaultBranch: 'main',
  repoAddress: '30617:owner:$dtag',
  maintainers: const [],
  channelId: channelId,
);

Project _project({
  String? home,
  List<String> related = const [],
  List<ProjectRepository> repositories = const [],
}) => Project(
  id: '30621:owner:p',
  dtag: 'p',
  name: 'P',
  description: '',
  owner: 'owner',
  createdAt: 1,
  projectChannelId: home,
  relatedChannelIds: related,
  status: 'active',
  projectAddress: '30621:owner:p',
  primaryRepositoryAddress: null,
  repositoryAddresses: [for (final r in repositories) r.repoAddress],
  repositoryRelayHints: const {},
  repositories: repositories,
  unavailableRepositoryAddresses: const [],
  visibility: ProjectVisibility.listed,
  legacy: false,
);

void main() {
  test('lists home, then related, then repository channels once each', () {
    final channels = listProjectBoundChannels(
      _project(
        home: ' home ',
        related: ['related', 'home', ' '],
        repositories: [
          _repo('a', 'home'),
          _repo('b', 'repo-b'),
          _repo('c', 'related'),
          _repo('d', null),
        ],
      ),
    );

    expect(
      [for (final c in channels) (c.channelId, c.role, c.repositoryId)],
      [
        ('home', ProjectChannelRole.home, null),
        ('related', ProjectChannelRole.related, null),
        ('repo-b', ProjectChannelRole.related, 'owner:b'),
      ],
    );
  });

  test('a project without a home lists only related channels', () {
    final channels = listProjectBoundChannels(
      _project(repositories: [_repo('a', 'repo-a')]),
    );
    expect(channels.single.role, ProjectChannelRole.related);
    expect(channels.single.channelId, 'repo-a');
  });
}
