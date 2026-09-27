import 'package:buzz/shared/projects/project_read_models.dart';
import 'package:buzz/shared/projects/project_sidebar_membership.dart';
import 'package:flutter_test/flutter_test.dart';

import 'project_fixtures.dart';

void main() {
  group('ProjectSidebarMembershipStore', () {
    test('round-trips the Desktop v1 shape', () {
      final store = const ProjectSidebarMembershipStore()
          .withSelection('30621:a:p', selected: true, updatedAt: 5)
          .withSelection('30621:a:q', selected: false, updatedAt: 6);
      final decoded = ProjectSidebarMembershipStore.decode(store.encode());
      expect(decoded.selectedAddresses, {'30621:a:p'});
      expect(decoded.projects['30621:a:q']?.updatedAt, 6);
    });

    test('accepts the legacy array form', () {
      final decoded = ProjectSidebarMembershipStore.decode('["30621:a:p",""]');
      expect(decoded.selectedAddresses, {'30621:a:p'});
    });

    test('rejects malformed payloads and entries', () {
      for (final raw in [
        null,
        '',
        '{',
        '{"version":2,"projects":{}}',
        '{"version":1,"projects":[]}',
      ]) {
        expect(ProjectSidebarMembershipStore.decode(raw).projects, isEmpty);
      }
      final partial = ProjectSidebarMembershipStore.decode(
        '{"version":1,"projects":{"ok":{"selected":true,"updatedAt":1},'
        '"bad":{"selected":"yes","updatedAt":1},'
        '"neg":{"selected":true,"updatedAt":-1}}}',
      );
      expect(partial.projects.keys, ['ok']);
    });
  });

  group('listSidebarProjects', () {
    final f = CommunityFixture();
    final projects = buildProjectReadModels(
      projectEvents: [
        ...f.projectEvents,
        projectEvent(
          owner: bob,
          dtag: 'alpha',
          name: 'alpha',
          createdAt: 1_700_000_050,
          repoAddresses: [],
        ),
      ],
      repositoryEvents: f.repositoryEvents,
      deletionEvents: f.deletionEvents,
      relayOrigin: relayOrigin,
    );
    final everything = {for (final p in projects) p.projectAddress};

    List<String> names(
      SidebarProjectsFilter filter,
      SidebarProjectsSort sort, {
      Set<String>? added,
      String? viewer = alice,
    }) => listSidebarProjects(
      projects: projects,
      addedProjectAddresses: added ?? everything,
      currentPubkey: viewer,
      filter: filter,
      sort: sort,
    ).map((p) => p.name).toList();

    test('added + name: explicit projects only, case-insensitive', () {
      expect(names(SidebarProjectsFilter.added, SidebarProjectsSort.name), [
        'alpha',
        'Docs',
        'Platform',
      ]);
    });

    test('added + created: newest first', () {
      expect(names(SidebarProjectsFilter.added, SidebarProjectsSort.created), [
        'Docs',
        'Platform',
        'alpha',
      ]);
    });

    test('added respects membership', () {
      expect(
        names(
          SidebarProjectsFilter.added,
          SidebarProjectsSort.name,
          added: {projectAddress(alice, 'docs')},
        ),
        ['Docs'],
      );
    });

    test('owned ignores membership and matches the viewer', () {
      expect(
        names(
          SidebarProjectsFilter.owned,
          SidebarProjectsSort.name,
          added: const {},
          viewer: alice.toUpperCase(),
        ),
        ['Docs', 'Platform'],
      );
      expect(
        names(
          SidebarProjectsFilter.owned,
          SidebarProjectsSort.name,
          viewer: null,
        ),
        isEmpty,
      );
    });
  });
}
