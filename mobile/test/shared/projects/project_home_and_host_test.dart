import 'package:buzz/shared/projects/project_clone_url.dart';
import 'package:buzz/shared/projects/project_read_models.dart';
import 'package:buzz/shared/projects/projects.dart';
import 'package:flutter_test/flutter_test.dart';

import 'project_fixtures.dart';

void main() {
  late List<Project> projects;

  setUp(() {
    final f = CommunityFixture();
    projects = buildProjectReadModels(
      projectEvents: f.projectEvents,
      repositoryEvents: f.repositoryEvents,
      deletionEvents: f.deletionEvents,
      relayOrigin: relayOrigin,
    );
  });

  group('project home lookup', () {
    test('resolves a stream home channel', () {
      final home = findProjectHomeByChannelId(streamHomeChannel, projects);
      expect(home?.projectAddress, projectAddress(alice, 'platform'));
      expect(isProjectHomeChannel(streamHomeChannel, projects), isTrue);
    });

    test('resolves a forum home channel claimed through maintainers', () {
      final home = findProjectHomeByChannelId(forumHomeChannel, projects);
      expect(home?.projectAddress, projectAddress(alice, 'docs'));
      expect(isProjectHomeChannel(forumHomeChannel, projects), isTrue);
    });

    test('an unrelated or missing channel is not a home', () {
      const other = '11111111-1111-4111-8111-111111111111';
      expect(findProjectHomeByChannelId(other, projects), isNull);
      expect(isProjectHomeChannel(other, projects), isFalse);
      expect(findProjectHomeByChannelId(null, projects), isNull);
      expect(isProjectHomeChannel('', projects), isFalse);
    });

    test('a binding no member repository confirms is not authoritative', () {
      // Bob claims Alice's home channel, but none of his members bind to it.
      final squatter = buildProjectReadModels(
        projectEvents: [
          projectEvent(
            owner: bob,
            dtag: 'squat',
            channel: streamHomeChannel,
            repoAddresses: [repoAddress(alice, 'buzz')],
          ),
        ],
        repositoryEvents: [CommunityFixture().githubRepo],
      );
      final project = squatter.firstWhere((p) => !p.legacy);
      expect(hasAuthoritativeHomeBinding(project), isFalse);
      expect(findProjectHomeByChannelId(streamHomeChannel, squatter), isNull);
    });

    test('prefers the oldest listed home over an older unlisted one', () {
      final f = CommunityFixture();
      Project home(String visibility, int createdAt, String dtag) =>
          buildProjectReadModels(
            projectEvents: [
              projectEvent(
                owner: alice,
                dtag: dtag,
                visibility: visibility,
                channel: streamHomeChannel,
                createdAt: createdAt,
                repoAddresses: [repoAddress(alice, 'buzz')],
              ),
            ],
            repositoryEvents: [f.githubRepo],
            viewerPubkey: alice,
          ).firstWhere((p) => !p.legacy);
      final candidates = [
        home('unlisted', 1, 'hidden'),
        home('listed', 3, 'newer'),
        home('listed', 2, 'older'),
      ];
      expect(
        findProjectHomeByChannelId(streamHomeChannel, candidates)?.dtag,
        'older',
      );
      expect(
        findProjectHomeByChannelId(streamHomeChannel, [candidates.first])?.dtag,
        'hidden',
      );
    });
  });

  group('repository host classification', () {
    final buzzPath = '$relayOrigin/git/$alice/buzz';
    final cases = <String, (String?, String?, ProjectRepoHost)>{
      'buzz-hosted': (buzzPath, relayOrigin, const BuzzRepoHost()),
      'buzz-hosted trailing slash': (
        '$buzzPath/',
        '$relayOrigin/',
        const BuzzRepoHost(),
      ),
      'github': (
        'https://github.com/block/buzz.git',
        relayOrigin,
        const ExternalRepoHost('github.com'),
      ),
      'same origin, non-git path': (
        '$relayOrigin/other/$alice/buzz',
        relayOrigin,
        const ExternalRepoHost('buzz.example.com'),
      ),
      'git path on another relay': (
        'https://other.example.com/git/$alice/buzz',
        relayOrigin,
        const ExternalRepoHost('other.example.com'),
      ),
      'same host, other port': (
        'https://buzz.example.com:8443/git/$alice/buzz',
        relayOrigin,
        const ExternalRepoHost('buzz.example.com:8443'),
      ),
      'scp-style url': (
        'git@github.com:block/buzz.git',
        relayOrigin,
        const UnresolvedRepoHost(),
      ),
      'no clone url': (null, relayOrigin, const UnresolvedRepoHost()),
      'no relay origin': (buzzPath, null, const UnresolvedRepoHost()),
    };
    for (final entry in cases.entries) {
      test(entry.key, () {
        final (clone, relay, expected) = entry.value;
        expect(classifyRepoHost(clone, relay), expected);
      });
    }

    test('presentation offers the web link only for external repos', () {
      final platform = projects.firstWhere(
        (p) => p.projectAddress == projectAddress(alice, 'platform'),
      );
      final github = platform.repositories.firstWhere((r) => r.dtag == 'buzz');
      final hosted = platform.repositories.firstWhere(
        (r) => r.dtag == 'buzz-infra',
      );

      final githubView = projectRepoPresentation(github, relayOrigin);
      expect(githubView.host, const ExternalRepoHost('github.com'));
      expect(githubView.externalUrl, 'https://github.com/block/buzz');

      final hostedView = projectRepoPresentation(hosted, relayOrigin);
      expect(hostedView.host, const BuzzRepoHost());
      expect(hostedView.externalUrl, isNull);
    });

    test('presentation rejects a non-http web link', () {
      final repo = buildProjectReadModels(
        projectEvents: const [],
        repositoryEvents: [
          repoEvent(
            owner: carol,
            dtag: 'x',
            clone: ['https://github.com/carol/x'],
            web: 'javascript:alert(1)',
          ),
        ],
      ).single.repositories.single;
      expect(projectRepoPresentation(repo, relayOrigin).externalUrl, isNull);
    });

    test('display path', () {
      final platform = projects.firstWhere(
        (p) => p.projectAddress == projectAddress(alice, 'platform'),
      );
      final github = platform.repositories.firstWhere((r) => r.dtag == 'buzz');
      final hosted = platform.repositories.firstWhere(
        (r) => r.dtag == 'buzz-infra',
      );
      expect(
        repositoryDisplayPath(github, relayOrigin),
        'github.com/block/buzz',
      );
      expect(
        repositoryDisplayPath(hosted, relayOrigin, ownerLabel: 'alice'),
        'alice/buzz-infra',
      );
      expect(
        repositoryDisplayPath(hosted, relayOrigin),
        '${alice.substring(0, 8)}…/buzz-infra',
      );
    });

    test('relay origin from a base url', () {
      expect(
        relayOriginFromBaseUrl('https://buzz.example.com/'),
        'https://buzz.example.com',
      );
      expect(
        relayOriginFromBaseUrl('wss://buzz.example.com'),
        'https://buzz.example.com',
      );
      expect(
        relayOriginFromBaseUrl('http://localhost:3000'),
        'http://localhost:3000',
      );
      expect(relayOriginFromBaseUrl('not a url'), isNull);
    });
  });
}
