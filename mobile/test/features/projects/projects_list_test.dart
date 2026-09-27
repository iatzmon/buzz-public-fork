import 'package:buzz/features/channels/channel.dart';
import 'package:buzz/features/channels/channels_page.dart';
import 'package:buzz/features/channels/channels_provider.dart';
import 'package:buzz/features/forum/forum_models.dart';
import 'package:buzz/features/forum/forum_posts_view.dart';
import 'package:buzz/features/forum/forum_provider.dart';
import 'package:buzz/features/profile/profile_provider.dart';
import 'package:buzz/features/projects/project_page.dart';
import 'package:buzz/shared/community/community_icon_provider.dart';
import 'package:buzz/shared/profile/user_profile.dart';
import 'package:buzz/shared/projects/project_read_models.dart';
import 'package:buzz/shared/projects/projects.dart';
import 'package:buzz/shared/relay/relay.dart';
import 'package:buzz/shared/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../shared/projects/project_fixtures.dart';

const _scope = (
  relayBaseUrl: relayOrigin,
  relayOrigin: relayOrigin,
  viewerPubkey: alice,
);

ProjectsSnapshot _snapshot(CommunityFixture fixture, {bool empty = false}) =>
    ProjectsSnapshot(
      scope: _scope,
      projects: empty
          ? const []
          : buildProjectReadModels(
              projectEvents: fixture.projectEvents,
              repositoryEvents: fixture.repositoryEvents,
              deletionEvents: fixture.deletionEvents,
              relayOrigin: relayOrigin,
              viewerPubkey: alice,
            ),
      fetchedAt: DateTime(2026, 9, 27),
    );

Channel _channel(String id, String name, String type) => Channel(
  id: id,
  name: name,
  channelType: type,
  visibility: 'open',
  description: '',
  createdBy: alice,
  createdAt: DateTime(2025),
  memberCount: 3,
  isMember: true,
);

final _general = _channel('general-id', 'general', 'stream');
final _docsForum = _channel(forumHomeChannel, 'docs-home', 'forum');

class _Channels extends ChannelsNotifier {
  _Channels(this._channels);

  final List<Channel> _channels;

  @override
  Future<List<Channel>> build() async => _channels;

  @override
  Future<void> ensureDirectoryLoaded() async {}
}

class _RelayConfig extends RelayConfigNotifier {
  @override
  RelayConfig build() => const RelayConfig(baseUrl: relayOrigin);
}

class _Profile extends ProfileNotifier {
  @override
  Future<UserProfile?> build() async =>
      const UserProfile(pubkey: alice, displayName: 'Alice');
}

class _Presence extends PresenceNotifier {
  @override
  Future<String> build() async => 'online';
}

Future<SharedPreferences> _pumpChannels(
  WidgetTester tester, {
  required ProjectsSnapshot snapshot,
  List<Channel>? channels,
  Map<String, Object> prefs = const {},
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final saved = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        savedPrefsProvider.overrideWithValue(saved),
        relayConfigProvider.overrideWith(_RelayConfig.new),
        myPubkeyProvider.overrideWithValue(alice),
        profileProvider.overrideWith(_Profile.new),
        presenceProvider.overrideWith(_Presence.new),
        communityIconProvider.overrideWith((ref, relayUrl) async => null),
        activeProjectsProvider.overrideWithValue(AsyncData(snapshot)),
        channelsProvider.overrideWith(
          () => _Channels(channels ?? [_general, _docsForum]),
        ),
        forumPostsProvider(
          forumHomeChannel,
        ).overrideWith((ref) async => const ForumPostsResponse(posts: [])),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: ChannelsPage(
          settingsPageBuilder: (_) => const SizedBox(),
          onSettingsTransitionProgress: (_) {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return saved;
}

Finder _projectRow(String address) =>
    find.byKey(ValueKey('channels-project-$address'));

const _membershipKey =
    'buzz.sidebar.projects.membership.v1:$relayOrigin:$alice';

void main() {
  final platform = projectAddress(alice, 'platform');
  final docs = projectAddress(alice, 'docs');

  testWidgets('hides the Projects section when the community has none', (
    tester,
  ) async {
    await _pumpChannels(
      tester,
      snapshot: _snapshot(CommunityFixture(), empty: true),
    );

    expect(
      find.byKey(const ValueKey('channels-projects-section')),
      findsNothing,
    );
    expect(find.text('general'), findsOneWidget);
  });

  testWidgets('adds a project from Browse projects and keeps it', (
    tester,
  ) async {
    final prefs = await _pumpChannels(
      tester,
      snapshot: _snapshot(CommunityFixture()),
    );

    expect(
      find.byKey(const ValueKey('channels-projects-section')),
      findsOneWidget,
    );
    expect(_projectRow(platform), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('channels-projects-browse-empty')),
    );
    await tester.pumpAndSettle();

    // Explicit, undeleted projects only: no legacy Sandbox, no Retired.
    expect(find.byKey(ValueKey('browse-project-$platform')), findsOneWidget);
    expect(find.byKey(ValueKey('browse-project-$docs')), findsOneWidget);
    expect(find.text('Sandbox'), findsNothing);
    expect(find.text('Retired'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('browse-project-add-platform')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('browse-project-remove-platform')),
      findsOneWidget,
    );

    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    expect(_projectRow(platform), findsOneWidget);
    expect(_projectRow(docs), findsNothing);
    expect(
      ProjectSidebarMembershipStore.decode(
        prefs.getString(_membershipKey),
      ).selectedAddresses,
      {platform},
    );
  });

  testWidgets('Owned by me lists the viewer\'s projects without adding', (
    tester,
  ) async {
    await _pumpChannels(tester, snapshot: _snapshot(CommunityFixture()));

    await tester.tap(find.byKey(const ValueKey('sort-menu-Projects')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show: Owned by me'));
    await tester.pumpAndSettle();

    expect(_projectRow(platform), findsOneWidget);
    expect(_projectRow(docs), findsOneWidget);
  });

  testWidgets('long press removes a project from the list', (tester) async {
    final store = const ProjectSidebarMembershipStore().withSelection(
      platform,
      selected: true,
      updatedAt: 1,
    );
    final prefs = await _pumpChannels(
      tester,
      snapshot: _snapshot(CommunityFixture()),
      prefs: {_membershipKey: store.encode()},
    );
    expect(_projectRow(platform), findsOneWidget);

    await tester.longPress(_projectRow(platform));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from list'));
    await tester.pumpAndSettle();

    expect(_projectRow(platform), findsNothing);
    expect(
      ProjectSidebarMembershipStore.decode(
        prefs.getString(_membershipKey),
      ).selectedAddresses,
      isEmpty,
    );
  });

  testWidgets(
    'opens a forum home, and its project button shows the repositories',
    (tester) async {
      final store = const ProjectSidebarMembershipStore().withSelection(
        docs,
        selected: true,
        updatedAt: 1,
      );
      await _pumpChannels(
        tester,
        snapshot: _snapshot(CommunityFixture()),
        prefs: {_membershipKey: store.encode()},
      );

      await tester.tap(_projectRow(docs));
      await tester.pumpAndSettle();
      expect(find.byType(ForumPostsView), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('channel-project-details')));
      await tester.pumpAndSettle();

      expect(find.byType(ProjectPage), findsOneWidget);
      expect(find.text('Forum Docs'), findsOneWidget);
      expect(find.text('Project home · Forum'), findsOneWidget);
    },
  );

  testWidgets(
    'falls back to the project page when the home channel is not loaded',
    (tester) async {
      final store = const ProjectSidebarMembershipStore().withSelection(
        platform,
        selected: true,
        updatedAt: 1,
      );
      await _pumpChannels(
        tester,
        snapshot: _snapshot(CommunityFixture()),
        channels: [_general],
        prefs: {_membershipKey: store.encode()},
      );

      await tester.tap(_projectRow(platform));
      await tester.pumpAndSettle();

      expect(find.byType(ProjectPage), findsOneWidget);
      // The stream home is not visible to this viewer.
      expect(find.text('Unavailable channel'), findsOneWidget);
      final homeRow = tester.widget<ListTile>(
        find.byKey(const ValueKey('project-channel-$streamHomeChannel')),
      );
      expect(homeRow.enabled, isFalse);
      // GitHub repository: an "Open on GitHub" link.
      expect(
        find.byKey(const ValueKey('project-repository-open-buzz')),
        findsOneWidget,
      );
      expect(find.text('Open on GitHub'), findsOneWidget);
      // Buzz-hosted repositories: no external link. Bob's listed
      // repository resolves as a member repository (as on Desktop).
      expect(find.textContaining('Hosted in this community'), findsNWidgets(2));
      expect(find.text('Private Notes'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('project-repository-open-buzz-infra')),
        findsNothing,
      );
      expect(find.textContaining('not available.'), findsNothing);
    },
  );
}
