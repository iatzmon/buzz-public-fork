import 'package:buzz/shared/projects/project_event_parsing.dart';
import 'package:buzz/shared/projects/project_read_models.dart';
import 'package:buzz/shared/projects/projects.dart';
import 'package:buzz/shared/relay/nostr_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'project_fixtures.dart';

List<Project> build(CommunityFixture f, {String? viewer}) =>
    buildProjectReadModels(
      projectEvents: f.projectEvents,
      repositoryEvents: f.repositoryEvents,
      deletionEvents: f.deletionEvents,
      relayOrigin: relayOrigin,
      viewerPubkey: viewer,
    );

Project byAddress(List<Project> projects, String address) =>
    projects.singleWhere((project) => project.projectAddress == address);

void main() {
  group('repositoryFromEvent', () {
    test('parses a GitHub-backed repository', () {
      final repo = repositoryFromEvent(CommunityFixture().githubRepo, null)!;
      expect(repo.id, '$alice:buzz');
      expect(repo.repoAddress, repoAddress(alice, 'buzz'));
      expect(repo.name, 'buzz');
      expect(repo.description, 'Nostr-native team chat');
      expect(repo.cloneUrls, ['https://github.com/block/buzz.git']);
      expect(repo.webUrl, 'https://github.com/block/buzz');
      expect(repo.channelId, streamHomeChannel);
      expect(repo.defaultBranch, 'main');
      expect(repo.status, 'active');
    });

    test('derives the Buzz-hosted clone URL when no clone tag exists', () {
      final repo = repositoryFromEvent(
        CommunityFixture().buzzHostedRepo,
        relayOrigin,
      )!;
      expect(repo.cloneUrls, ['$relayOrigin/git/$alice/buzz-infra']);
      expect(repo.webUrl, isNull);
    });

    test('lowercases maintainers and drops malformed ones', () {
      final repo = repositoryFromEvent(
        repoEvent(
          owner: bob,
          dtag: 'r',
          maintainers: [alice.toUpperCase(), 'not-a-pubkey'],
        ),
        null,
      )!;
      expect(repo.maintainers, [alice]);
      expect(repo.authorizes(alice), isTrue);
      expect(repo.authorizes(carol), isFalse);
    });

    test('drops a buzz-channel that is not a channel UUID', () {
      final repo = repositoryFromEvent(
        repoEvent(owner: bob, dtag: 'r', channel: 'general'),
        null,
      )!;
      expect(repo.channelId, isNull);
    });

    test('rejects a repository without a d tag', () {
      final event = repoEvent(owner: bob, dtag: '');
      expect(repositoryFromEvent(event, null), isNull);
    });
  });

  group('projectEnvelopeViolation', () {
    final member = ['a', repoAddress(alice, 'buzz')];
    final cases = <String, (List<List<String>>, bool)>{
      'valid': (
        [
          ['d', 'p'],
          member,
        ],
        true,
      ),
      'missing d': ([member], false),
      'two d tags': (
        [
          ['d', 'p'],
          ['d', 'q'],
        ],
        false,
      ),
      'duplicate name': (
        [
          ['d', 'p'],
          ['name', 'a'],
          ['name', 'b'],
        ],
        false,
      ),
      'uppercase member owner': (
        [
          ['d', 'p'],
          ['a', repoAddress(alice.toUpperCase(), 'buzz')],
        ],
        false,
      ),
      'duplicate member': (
        [
          ['d', 'p'],
          member,
          member,
        ],
        false,
      ),
      'member arity 4': (
        [
          ['d', 'p'],
          [...member, 'wss://relay', 'extra'],
        ],
        false,
      ),
      'member of wrong kind': (
        [
          ['d', 'p'],
          ['a', '30621:$alice:buzz'],
        ],
        false,
      ),
      'name over 256 bytes': (
        [
          ['d', 'p'],
          ['name', 'x' * 257],
        ],
        false,
      ),
      'too many members': (
        [
          ['d', 'p'],
          for (var i = 0; i <= maxProjectMembers; i++)
            ['a', repoAddress(alice, 'r$i')],
        ],
        false,
      ),
    };
    for (final entry in cases.entries) {
      test(entry.key, () {
        final (tags, valid) = entry.value;
        expect(projectEnvelopeViolation(tags) == null, valid);
      });
    }
  });

  group('buildProjectReadModels', () {
    test('folds explicit, legacy, and deleted projects newest first', () {
      final projects = build(CommunityFixture());
      expect(projects.map((p) => p.projectAddress), [
        projectAddress(alice, 'docs'),
        projectAddress(alice, 'platform'),
        repoAddress(carol, 'sandbox'),
        repoAddress(bob, 'private-notes'),
      ]);
    });

    test('hides a project deleted by a kind:5 tombstone', () {
      final f = CommunityFixture();
      expect(
        build(
          f,
        ).any((p) => p.projectAddress == projectAddress(alice, 'retired')),
        isFalse,
      );
      final withoutTombstone = buildProjectReadModels(
        projectEvents: f.projectEvents,
        repositoryEvents: f.repositoryEvents,
        relayOrigin: relayOrigin,
      );
      expect(
        withoutTombstone.any(
          (p) => p.projectAddress == projectAddress(alice, 'retired'),
        ),
        isTrue,
      );
    });

    test('a head republished after its tombstone is visible again', () {
      final f = CommunityFixture();
      final republished = projectEvent(
        owner: alice,
        dtag: 'retired',
        name: 'Revived',
        createdAt: 1_700_000_500,
        repoAddresses: [],
      );
      final projects = buildProjectReadModels(
        projectEvents: [...f.projectEvents, republished],
        repositoryEvents: f.repositoryEvents,
        deletionEvents: f.deletionEvents,
        relayOrigin: relayOrigin,
      );
      expect(
        byAddress(projects, projectAddress(alice, 'retired')).name,
        'Revived',
      );
    });

    test('a tombstone hides a deleted repository and its legacy card', () {
      final f = CommunityFixture();
      final projects = buildProjectReadModels(
        projectEvents: f.projectEvents,
        repositoryEvents: f.repositoryEvents,
        deletionEvents: [
          deletionEvent(
            author: carol,
            coordinates: [repoAddress(carol, 'sandbox')],
            createdAt: 1_800_000_000,
          ),
        ],
        relayOrigin: relayOrigin,
      );
      expect(
        projects.any((p) => p.projectAddress == repoAddress(carol, 'sandbox')),
        isFalse,
      );
    });

    group('tombstone authorization', () {
      List<String> visible(
        List<NostrEvent> repositories,
        List<NostrEvent> deletions,
      ) => [
        for (final project in buildProjectReadModels(
          projectEvents: const [],
          repositoryEvents: repositories,
          deletionEvents: deletions,
          relayOrigin: relayOrigin,
        ))
          project.projectAddress,
      ];

      NostrEvent deletionOf(String author, String address) => deletionEvent(
        author: author,
        coordinates: [address],
        createdAt: 1_800_000_000,
      );

      test('ignores a tombstone signed by another author', () {
        final bobRepo = repoEvent(owner: bob, dtag: 'notes');
        final address = repoAddress(bob, 'notes');
        expect(visible([bobRepo], [deletionOf(alice, address)]), [address]);
        expect(visible([bobRepo], [deletionOf(bob, address)]), isEmpty);
      });

      test('honors the attested NIP-OA owner of the author', () {
        final agentRepo = repoEvent(
          owner: agent,
          dtag: 'scratch',
          extraTags: [oaAuthTag(carol, agent)],
        );
        final address = repoAddress(agent, 'scratch');
        expect(visible([agentRepo], [deletionOf(carol, address)]), isEmpty);
        expect(visible([agentRepo], [deletionOf(bob, address)]), [address]);
      });

      test('ignores an owner the auth tag does not validly attest', () {
        final address = repoAddress(agent, 'scratch');
        final tombstone = deletionOf(carol, address);
        // Signed by bob, naming carol as owner.
        final forged = oaAuthTag(bob, agent);
        forged[1] = carol;
        // Carol attests a different agent key.
        final otherAgent = oaAuthTag(carol, bob);
        // Carol attests the agent only for another kind.
        final wrongKind = oaAuthTag(carol, agent, conditions: 'kind=30621');
        for (final tag in [forged, otherAgent, wrongKind]) {
          final agentRepo = repoEvent(
            owner: agent,
            dtag: 'scratch',
            extraTags: [tag],
          );
          expect(visible([agentRepo], [tombstone]), [address]);
        }
      });
    });

    test('an unclaimed repository becomes a legacy project', () {
      final legacy = byAddress(
        build(CommunityFixture()),
        repoAddress(carol, 'sandbox'),
      );
      expect(legacy.legacy, isTrue);
      expect(legacy.isExplicit, isFalse);
      expect(legacy.name, 'Sandbox');
      expect(legacy.description, 'Scratch repository');
      expect(legacy.owner, carol);
      expect(legacy.projectChannelId, isNull);
      expect(legacy.repositories.single.repoAddress, legacy.projectAddress);
    });

    test('a listed repository the project owner cannot claim stays legacy', () {
      final projects = build(CommunityFixture());
      final platform = byAddress(projects, projectAddress(alice, 'platform'));
      expect(
        platform.repositoryAddresses,
        contains(repoAddress(bob, 'private-notes')),
      );
      expect(
        byAddress(projects, repoAddress(bob, 'private-notes')).legacy,
        isTrue,
      );
    });

    test('a repository claimed only through maintainers is not legacy', () {
      final projects = build(CommunityFixture());
      expect(
        projects.any(
          (p) => p.legacy && p.projectAddress == repoAddress(bob, 'forum-docs'),
        ),
        isFalse,
      );
      final docs = byAddress(projects, projectAddress(alice, 'docs'));
      expect(docs.repositories.single.owner, bob);
      expect(docs.projectChannelId, forumHomeChannel);
    });

    test('parses explicit project metadata and member resolution', () {
      final platform = byAddress(
        build(CommunityFixture()),
        projectAddress(alice, 'platform'),
      );
      expect(platform.name, 'Platform');
      expect(platform.description, 'Relay, desktop, and mobile');
      expect(platform.owner, alice);
      expect(platform.projectChannelId, streamHomeChannel);
      expect(platform.visibility, ProjectVisibility.listed);
      // Sorted by address, as Desktop does.
      expect(platform.repositoryAddresses, [
        repoAddress(bob, 'private-notes'),
        repoAddress(alice, 'buzz'),
        repoAddress(alice, 'buzz-infra'),
      ]);
      // No member shares the project's d-tag: the first visible one wins.
      expect(
        platform.primaryRepositoryAddress,
        repoAddress(bob, 'private-notes'),
      );
      expect(platform.unavailableRepositoryAddresses, isEmpty);
    });

    test('records members without an announcement as unavailable', () {
      final projects = buildProjectReadModels(
        projectEvents: [
          projectEvent(
            owner: alice,
            dtag: 'ghost',
            repoAddresses: [repoAddress(alice, 'missing')],
          ),
        ],
        repositoryEvents: const [],
      );
      expect(projects.single.unavailableRepositoryAddresses, [
        repoAddress(alice, 'missing'),
      ]);
      expect(projects.single.repositories, isEmpty);
    });

    test('keeps unlisted projects only for their owner', () {
      final unlisted = projectEvent(
        owner: alice,
        dtag: 'secret',
        visibility: 'unlisted',
        repoAddresses: [],
      );
      List<Project> visibleTo(String viewer) => buildProjectReadModels(
        projectEvents: [unlisted],
        repositoryEvents: const [],
        viewerPubkey: viewer,
      );
      expect(visibleTo(alice).single.visibility, ProjectVisibility.unlisted);
      expect(visibleTo(bob), isEmpty);
    });

    test('keeps only the newest head of a replaceable project', () {
      final older = projectEvent(
        owner: alice,
        dtag: 'p',
        name: 'Old',
        createdAt: 10,
        repoAddresses: [],
      );
      final newer = projectEvent(
        owner: alice,
        dtag: 'p',
        name: 'New',
        createdAt: 20,
        repoAddresses: [],
      );
      final projects = buildProjectReadModels(
        projectEvents: [newer, older],
        repositoryEvents: const [],
      );
      expect(projects.single.name, 'New');
    });

    test('drops projects that violate the NIP-MP envelope', () {
      final invalid = projectEvent(
        owner: alice,
        dtag: 'p',
        repoAddresses: [repoAddress(alice, 'a'), repoAddress(alice, 'a')],
      );
      expect(
        buildProjectReadModels(
          projectEvents: [invalid],
          repositoryEvents: const [],
        ),
        isEmpty,
      );
    });

    test('absorbs a channel-bound repository into the home project', () {
      // Agents announce repos with `--channel` but skip `projects add-repo`.
      final project = projectEvent(
        owner: alice,
        dtag: 'app',
        channel: streamHomeChannel,
        repoAddresses: [repoAddress(alice, 'buzz')],
      );
      final projects = buildProjectReadModels(
        projectEvents: [project],
        repositoryEvents: [
          CommunityFixture().githubRepo,
          CommunityFixture().buzzHostedRepo,
        ],
        relayOrigin: relayOrigin,
      );
      expect(projects.single.repositoryAddresses, [
        repoAddress(alice, 'buzz'),
        repoAddress(alice, 'buzz-infra'),
      ]);
    });
  });
}
