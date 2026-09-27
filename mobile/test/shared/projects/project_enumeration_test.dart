import 'package:buzz/shared/projects/project_enumeration.dart';
import 'package:buzz/shared/projects/project_models.dart';
import 'package:buzz/shared/relay/relay.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_project_relay.dart';
import 'project_fixtures.dart';

Future<List<Project>> loadVia(FakeProjectRelaySession relay) async {
  final events = await fetchProjectEvents(
    (filter) => relay.queryRelay([filter]),
  );
  return events.buildProjects(relayOrigin: relayOrigin, viewerPubkey: alice);
}

/// A kind:5 deletion of a chat message (e-tagged), as mobile and desktop
/// publish when a user deletes their own message.
NostrEvent messageDeletion(String author, int createdAt) => NostrEvent(
  id: 'd$createdAt'.padRight(64, '0'),
  pubkey: author,
  createdAt: createdAt,
  kind: EventKind.deletion,
  content: '',
  sig: 'f' * 128,
  tags: [
    ['e', createdAt.toRadixString(16).padLeft(64, '0')],
    ['k', '9'],
  ],
);

void main() {
  group('enumerateProjectEvents', () {
    test('drains a page boundary that splits one second', () async {
      // The first page of three ends inside second 20, which also holds `d`:
      // advancing a bare `until` cursor to 19 would silently skip `d`.
      final events = [
        repoEvent(owner: alice, dtag: 'a', createdAt: 30),
        repoEvent(owner: alice, dtag: 'b', createdAt: 25),
        repoEvent(owner: alice, dtag: 'c', createdAt: 20),
        repoEvent(owner: alice, dtag: 'd', createdAt: 20),
        repoEvent(owner: alice, dtag: 'e', createdAt: 10),
      ];
      final filters = <NostrFilter>[];
      final result = await enumerateProjectEvents(
        (filter) async {
          filters.add(filter);
          return applyFilter(events, filter);
        },
        [EventKind.repoAnnouncement],
        pageSize: 3,
      );
      expect(result.map((e) => e.id).toSet(), events.map((e) => e.id).toSet());
      expect(filters[1].since, 20);
      expect(filters[1].until, 20);
      expect(filters[2].until, 19);
    });

    test('fails instead of truncating when one second overflows', () async {
      final events = [
        for (var i = 0; i < 3; i++)
          repoEvent(owner: alice, dtag: 'r$i', createdAt: 5),
      ];
      await expectLater(
        enumerateProjectEvents((filter) async => applyFilter(events, filter), [
          EventKind.repoAnnouncement,
        ], pageSize: 2),
        throwsA(isA<ProjectsLoadException>()),
      );
    });

    test('fails instead of scanning past the page budget', () async {
      final events = [
        for (var i = 0; i < 10; i++)
          repoEvent(owner: alice, dtag: 'r$i', createdAt: 100 - i),
      ];
      await expectLater(
        enumerateProjectEvents(
          (filter) async => applyFilter(events, filter),
          [EventKind.repoAnnouncement],
          pageSize: 2,
          maxPages: 3,
        ),
        throwsA(isA<ProjectsLoadException>()),
      );
    });

    test('stops when cancelled', () async {
      var calls = 0;
      await expectLater(
        enumerateProjectEvents(
          (filter) async {
            calls++;
            return const [];
          },
          [EventKind.repoAnnouncement],
          isCancelled: () => true,
        ),
        throwsA(isA<ProjectsCancelledException>()),
      );
      expect(calls, 0);
    });
  });

  group('fetchProjectEvents', () {
    test('queries explicit kinds with SQL-pushable filters only', () async {
      final relay = FakeProjectRelaySession(CommunityFixture().allEvents);
      final projects = await loadVia(relay);

      expect(relay.queries.every((q) => q.kinds.length == 1), isTrue);
      expect(relay.queries.map((q) => q.kinds.single).toSet(), {
        EventKind.projectAnnouncement,
        EventKind.repoAnnouncement,
        EventKind.deletion,
      });
      expect(relay.queries.every((q) => q.tags.isEmpty), isTrue);
      final tombstoneQuery = relay.queries.singleWhere(
        (q) => q.kinds.single == EventKind.deletion,
      );
      expect(tombstoneQuery.authors, unorderedEquals([alice, bob, carol]));
      expect(tombstoneQuery.since, 1_700_000_000);

      expect(
        projects.any(
          (p) => p.projectAddress == projectAddress(alice, 'retired'),
        ),
        isFalse,
      );
      expect(projects, hasLength(4));
    });

    test('the relay drops #a matches beyond its SQL limit', () {
      // Why tombstones are not scoped with `#a`: 600 newer message deletions
      // fill the limited page before the project tombstone is post-filtered.
      final events = [
        ...CommunityFixture().allEvents,
        for (var i = 0; i < 600; i++) messageDeletion(alice, 1_700_001_000 + i),
      ];
      final page = applyFilter(
        events,
        NostrFilter(
          kinds: const [EventKind.deletion],
          tags: {
            '#a': [projectAddress(alice, 'retired')],
          },
          limit: projectEnumerationPageSize,
        ),
      );
      expect(page, isEmpty);
    });

    test('finds a tombstone buried under newer unrelated deletions', () async {
      final relay = FakeProjectRelaySession([
        ...CommunityFixture().allEvents,
        for (var i = 0; i < 1200; i++)
          messageDeletion(alice, 1_700_001_000 + i),
      ]);
      final projects = await loadVia(relay);
      expect(
        projects.any(
          (p) => p.projectAddress == projectAddress(alice, 'retired'),
        ),
        isFalse,
      );
      expect(
        relay.queries.where((q) => q.kinds.single == EventKind.deletion).length,
        greaterThan(2),
      );
    });

    test('honors a tombstone from the NIP-OA owner of an agent repo', () async {
      const agent =
          'a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90';
      final agentRepo = repoEvent(
        owner: agent,
        dtag: 'agent-scratch',
        extraTags: [
          ['auth', carol, 'kind=30617', 'e' * 128],
        ],
      );
      final tombstone = deletionEvent(
        author: carol,
        coordinates: [repoAddress(agent, 'agent-scratch')],
        createdAt: 1_800_000_000,
      );
      expect(await loadVia(FakeProjectRelaySession([agentRepo])), hasLength(1));
      expect(
        await loadVia(FakeProjectRelaySession([agentRepo, tombstone])),
        isEmpty,
      );
    });

    test('chunks tombstone authors to at most 100 per query', () async {
      final relay = FakeProjectRelaySession([
        for (var i = 0; i < 150; i++)
          repoEvent(
            owner: (i + 1).toRadixString(16).padLeft(64, '0'),
            dtag: 'r$i',
          ),
      ]);
      await loadVia(relay);
      final chunks = relay.queries
          .where((q) => q.kinds.single == EventKind.deletion)
          .map((q) => q.authors!.length)
          .toList();
      expect(chunks..sort(), [50, 100]);
    });

    test('fails closed when tombstones cannot be fetched', () async {
      final relay = FakeProjectRelaySession(CommunityFixture().allEvents)
        ..failingKinds.add(EventKind.deletion);
      await expectLater(loadVia(relay), throwsA(isA<ProjectsLoadException>()));
    });

    test('propagates an announcement query failure', () async {
      final relay = FakeProjectRelaySession(CommunityFixture().allEvents)
        ..failingKinds.add(EventKind.repoAnnouncement);
      await expectLater(loadVia(relay), throwsA(isA<RelayException>()));
    });
  });
}
