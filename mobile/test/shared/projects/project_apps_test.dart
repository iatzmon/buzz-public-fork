import 'package:characters/characters.dart';
import 'package:buzz/shared/projects/project_event_parsing.dart';
import 'package:buzz/shared/projects/projects.dart';
import 'package:flutter_test/flutter_test.dart';

import 'project_fixtures.dart';

List<List<String>> _appTags(List<List<String>> apps) => [
  ['d', 'side-hustles'],
  for (final app in apps) ['buzz-app', ...app],
];

void main() {
  group('projectAppsFromTags', () {
    test('reads https apps in tag order with their labels', () {
      final apps = projectAppsFromTags(
        _appTags([
          ['https://side-hustles.acs.example.com/', 'Side Hustles'],
          ['https://tools.example.com:8443/board?view=all', 'Board'],
        ]),
      );

      expect([for (final app in apps) app.label], ['Side Hustles', 'Board']);
      expect(apps[0].origin, 'https://side-hustles.acs.example.com');
      expect(apps[0].host, 'side-hustles.acs.example.com');
      expect(apps[1].origin, 'https://tools.example.com:8443');
      expect(apps[1].url, 'https://tools.example.com:8443/board?view=all');
    });

    test('falls back to the host when the label is missing or blank', () {
      final apps = projectAppsFromTags(
        _appTags([
          ['https://a.example.com/'],
          ['https://b.example.com/', '   '],
        ]),
      );

      expect(
        [for (final app in apps) app.label],
        ['a.example.com', 'b.example.com'],
      );
    });

    test('accepts only https URLs with a host and no user info', () {
      final apps = projectAppsFromTags(
        _appTags([
          ['http://plain.example.com/', 'HTTP'],
          ['javascript:alert(1)', 'Script'],
          ['data:text/html,<p>hi</p>', 'Data'],
          ['buzz://channel/abc', 'Buzz'],
          ['https://user:pass@secret.example.com/', 'Credentials'],
          ['https:///no-host', 'No host'],
          ['//relative.example.com/', 'Relative'],
          ['', 'Empty'],
          ['https://ok.example.com/', 'OK'],
        ]),
      );

      expect([for (final app in apps) app.label], ['OK']);
    });

    test('rejects overlong URLs and ignores tags without a URL', () {
      final long = 'https://long.example.com/${'a' * maxProjectAppUrlLength}';
      final apps = projectAppsFromTags([
        ['buzz-app'],
        ['buzz-app', long, 'Long'],
        ['buzz-application', 'https://other.example.com/', 'Other tag'],
        ['buzz-app', 'https://ok.example.com/', 'OK'],
      ]);

      expect([for (final app in apps) app.label], ['OK']);
    });

    test('keeps the first tag for a repeated URL', () {
      final apps = projectAppsFromTags(
        _appTags([
          ['https://same.example.com/', 'First'],
          ['https://same.example.com/', 'Second'],
        ]),
      );

      expect([for (final app in apps) app.label], ['First']);
    });

    test('reads at most $maxProjectApps apps', () {
      final apps = projectAppsFromTags(
        _appTags([
          for (var i = 0; i < maxProjectApps + 5; i++)
            ['https://app$i.example.com/', 'App $i'],
        ]),
      );

      expect(apps, hasLength(maxProjectApps));
      expect(apps.last.label, 'App ${maxProjectApps - 1}');
    });

    test('shortens long labels', () {
      final apps = projectAppsFromTags(
        _appTags([
          ['https://a.example.com/', 'x' * (maxProjectAppLabelLength + 10)],
        ]),
      );

      expect(apps.single.label.characters, hasLength(maxProjectAppLabelLength));
      expect(apps.single.label, endsWith('…'));
    });
  });

  group('project read model', () {
    test('an announced project carries its apps', () {
      final event = projectEvent(
        owner: alice,
        dtag: 'side-hustles',
        repoAddresses: const [],
        channel: forumHomeChannel,
        extraTags: [
          ['buzz-app', 'https://side-hustles.acs.example.com/', 'Candidates'],
          ['buzz-app', 'http://insecure.example.com/', 'Insecure'],
        ],
      );

      final project = explicitProjectFromEvent(event, const {}, const {})!;

      expect(project.apps, hasLength(1));
      expect(project.apps.single.label, 'Candidates');
      expect(project.withAbsorbedRepository(_repository()).apps, project.apps);
    });

    test('a project without app tags has no apps', () {
      final event = projectEvent(
        owner: alice,
        dtag: 'plain',
        repoAddresses: const [],
      );

      expect(
        explicitProjectFromEvent(event, const {}, const {})!.apps,
        isEmpty,
      );
    });

    test('legacy projects have no apps', () {
      expect(legacyProjectFromRepository(_repository()).apps, isEmpty);
    });
  });
}

ProjectRepository _repository() => repositoryFromEvent(
  repoEvent(owner: alice, dtag: 'buzz', name: 'buzz'),
  relayOrigin,
)!;
