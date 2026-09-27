import 'dart:async';

import 'package:buzz/features/channels/channel.dart';
import 'package:buzz/features/channels/channels_page.dart';
import 'package:buzz/features/channels/channels_provider.dart';
import 'package:buzz/features/forum/forum_models.dart';
import 'package:buzz/features/forum/forum_posts_view.dart';
import 'package:buzz/features/forum/forum_provider.dart';
import 'package:buzz/features/profile/profile_provider.dart';
import 'package:buzz/features/projects/project_page.dart';
import 'package:buzz/features/projects/project_tasks_page.dart';
import 'package:buzz/shared/community/community_icon_provider.dart';
import 'package:buzz/shared/profile/user_profile.dart';
import 'package:buzz/shared/projects/project_read_models.dart';
import 'package:buzz/shared/projects/project_task_store.dart';
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

/// The projects state under test; tests change it to simulate reloads.
class _ProjectsState extends Notifier<AsyncValue<ProjectsSnapshot>> {
  _ProjectsState(this._initial);

  final AsyncValue<ProjectsSnapshot> _initial;

  @override
  AsyncValue<ProjectsSnapshot> build() => _initial;

  void set(AsyncValue<ProjectsSnapshot> value) => state = value;

  /// A failed reload that keeps the previous snapshot, as Riverpod reports
  /// it for a real provider.
  void fail() {
    const error = AsyncError<ProjectsSnapshot>('offline', StackTrace.empty);
    // ignore: invalid_use_of_internal_member
    state = error.copyWithPrevious(state);
  }
}

late NotifierProvider<_ProjectsState, AsyncValue<ProjectsSnapshot>>
_projectsState;

class _Refreshes extends ProjectsNotifier {
  _Refreshes() : super(_scope);

  int count = 0;

  @override
  Future<void> refresh() async => count++;
}

Future<SharedPreferences> _pumpChannels(
  WidgetTester tester, {
  ProjectsSnapshot? snapshot,
  AsyncValue<ProjectsSnapshot>? state,
  List<Channel>? channels,
  Map<String, Object> prefs = const {},
  _Refreshes? refreshes,
}) async {
  final initial = state ?? AsyncData(snapshot!);
  _projectsState = NotifierProvider(() => _ProjectsState(initial));
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
        activeProjectsProvider.overrideWith((ref) => ref.watch(_projectsState)),
        activeProjectsNotifierProvider.overrideWithValue(
          refreshes ?? _Refreshes(),
        ),
        projectTaskTransportProvider.overrideWithValue(
          ProjectTaskTransport(
            query: (_) async => const [],
            publish: (_) async {},
            sign: (_, _, _, _) => throw UnimplementedError(),
          ),
        ),
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

  group('load failures and Tasks', () {
    ProviderContainer containerOf(WidgetTester tester) =>
        ProviderScope.containerOf(
          tester.element(find.byType(ChannelsPage, skipOffstage: false)),
        );

    Future<void> openPlatformPage(WidgetTester tester) async {
      final store = const ProjectSidebarMembershipStore().withSelection(
        platform,
        selected: true,
        updatedAt: 1,
      );
      await tester.tap(_projectRow(platform));
      await tester.pumpAndSettle();
      expect(find.byType(ProjectPage), findsOneWidget);
      expect(store.selectedAddresses, {platform});
    }

    Map<String, Object> platformAdded() => {
      _membershipKey: const ProjectSidebarMembershipStore()
          .withSelection(platform, selected: true, updatedAt: 1)
          .encode(),
    };

    testWidgets('Browse survives the snapshot going away', (tester) async {
      await _pumpChannels(tester, snapshot: _snapshot(CommunityFixture()));
      await tester.tap(
        find.byKey(const ValueKey('channels-projects-browse-empty')),
      );
      await tester.pumpAndSettle();

      // An account or community change drops the snapshot.
      containerOf(
        tester,
      ).read(_projectsState.notifier).set(const AsyncLoading());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('a failed refresh keeps the project and offers Retry', (
      tester,
    ) async {
      final refreshes = _Refreshes();
      await _pumpChannels(
        tester,
        snapshot: _snapshot(CommunityFixture()),
        prefs: platformAdded(),
        refreshes: refreshes,
      );
      await openPlatformPage(tester);

      containerOf(tester).read(_projectsState.notifier).fail();
      await tester.pumpAndSettle();
      expect(
        find.text('Could not refresh. This may be out of date.'),
        findsOneWidget,
      );
      expect(find.text('Repositories'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('project-page-retry')));
      expect(refreshes.count, 1);
    });

    testWidgets('a cold-load failure shows Retry, not a deleted project', (
      tester,
    ) async {
      final refreshes = _Refreshes();
      await _pumpChannels(
        tester,
        state: AsyncError<ProjectsSnapshot>(
          StateError('offline'),
          StackTrace.empty,
        ),
        refreshes: refreshes,
      );
      expect(
        find.byKey(const ValueKey('channels-projects-section')),
        findsOneWidget,
      );
      expect(find.text('Projects could not be loaded.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('channels-projects-retry')));
      expect(refreshes.count, 1);

      unawaited(
        Navigator.of(tester.element(find.byType(ChannelsPage))).push(
          MaterialPageRoute<void>(
            builder: (_) => ProjectPage(projectAddress: platform),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Projects could not be loaded.'), findsOneWidget);
      expect(find.textContaining('not available'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('project-page-retry')));
      expect(refreshes.count, 2);
    });

    testWidgets('Tasks opens the project tasks with its repositories', (
      tester,
    ) async {
      await _pumpChannels(
        tester,
        snapshot: _snapshot(CommunityFixture()),
        prefs: platformAdded(),
      );
      await openPlatformPage(tester);

      await tester.tap(find.byKey(const ValueKey('project-tasks')));
      await tester.pumpAndSettle();
      final page = tester.widget<ProjectTasksPage>(
        find.byType(ProjectTasksPage),
      );
      expect(page.repositories, {
        repoAddress(bob, 'private-notes'): 'Private Notes',
        repoAddress(alice, 'buzz'): 'buzz',
        repoAddress(alice, 'buzz-infra'): 'buzz-infra',
      });
      expect(page.channelId, streamHomeChannel);
      expect(page.repositoryChannels, {
        repoAddress(alice, 'buzz'): streamHomeChannel,
        repoAddress(alice, 'buzz-infra'): streamHomeChannel,
      });
    });
  });
}
