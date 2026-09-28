import 'dart:async';
import 'dart:convert';

import 'package:buzz/features/activity/compose_drafts_provider.dart';
import 'package:buzz/features/channels/channel.dart';
import 'package:buzz/features/channels/channel_detail_page.dart';
import 'package:buzz/features/channels/compose_bar.dart';
import 'package:buzz/features/channels/channels_page.dart';
import 'package:buzz/features/channels/channels_provider.dart';
import 'package:buzz/features/forum/forum_models.dart';
import 'package:buzz/features/forum/forum_posts_view.dart';
import 'package:buzz/features/forum/forum_provider.dart';
import 'package:buzz/features/profile/profile_provider.dart';
import 'package:buzz/features/projects/project_apps/project_app_bridge.dart';
import 'package:buzz/features/projects/project_apps/project_app_host.dart';
import 'package:buzz/features/projects/project_page.dart';
import 'package:buzz/features/projects/project_tasks_view.dart';
import 'package:buzz/shared/community/community_icon_provider.dart';
import 'package:buzz/shared/profile/user_profile.dart';
import 'package:buzz/shared/projects/project_read_models.dart';
import 'package:buzz/shared/projects/project_task_store.dart';
import 'package:buzz/shared/projects/projects.dart';
import 'package:buzz/shared/community/community_membership_provider.dart';
import 'package:buzz/shared/relay/relay.dart';
import 'package:buzz/shared/theme/theme.dart';
import 'package:buzz/shared/widgets/app_list.dart';
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

ProjectsSnapshot _snapshot(
  CommunityFixture fixture, {
  bool empty = false,
  List<NostrEvent> extraProjects = const [],
}) => ProjectsSnapshot(
  scope: _scope,
  projects: empty
      ? const []
      : buildProjectReadModels(
          projectEvents: [...fixture.projectEvents, ...extraProjects],
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
  Future<List<NostrEvent>> Function(NostrFilter filter)? query,
}) async {
  final initial = state ?? AsyncData(snapshot!);
  _projectsState = NotifierProvider(() => _ProjectsState(initial));
  SharedPreferences.setMockInitialValues(prefs);
  final saved = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        savedPrefsProvider.overrideWithValue(saved),
        communityMembershipProvider.overrideWith(
          (ref) async => communityOwnersSnapshot,
        ),
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
            scan: query ?? (_) async => const [],
            verify: (events) async => events,
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

/// Community member list served to the screens; tests may replace it.
CommunityMembershipSnapshot communityOwnersSnapshot =
    const CommunityMembershipSnapshot(snapshotFound: false, members: []);

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
    'a project opens on Tasks, and its Channels tab opens the forum home',
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
      // The project page opens on Tasks, not on the home channel.
      expect(find.byType(ForumPostsView), findsNothing);
      expect(find.byType(ProjectPage), findsOneWidget);
      expect(find.byType(ProjectTasksSection), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('project-tab-repositories')));
      await tester.pumpAndSettle();
      expect(find.text('Forum Docs'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('project-tab-channels')));
      await tester.pumpAndSettle();
      expect(find.byType(ProjectTasksSection), findsNothing);
      expect(find.text('Project home · Forum'), findsOneWidget);
      await tester.tap(find.text('docs-home'));
      await tester.pumpAndSettle();
      expect(find.byType(ForumPostsView), findsOneWidget);

      // The home channel's project button opens the project page again.
      await tester.tap(find.byKey(const ValueKey('channel-project-details')));
      await tester.pumpAndSettle();
      expect(find.byType(ProjectTasksSection), findsOneWidget);
    },
  );

  testWidgets('pull to refresh reloads the Activity channel messages', (
    tester,
  ) async {
    var text = 'Original message';
    var reads = 0;
    final store = const ProjectSidebarMembershipStore().withSelection(
      platform,
      selected: true,
      updatedAt: 1,
    );
    await _pumpChannels(
      tester,
      snapshot: _snapshot(CommunityFixture()),
      channels: [_channel(streamHomeChannel, 'home', 'stream')],
      prefs: {_membershipKey: store.encode()},
      query: (filter) async {
        if (!filter.kinds.contains(EventKind.streamMessage)) return const [];
        reads++;
        return [
          NostrEvent(
            id: '$reads'.padLeft(64, 'a'),
            pubkey: alice,
            createdAt: 100 + reads,
            kind: EventKind.streamMessage,
            tags: const [
              ['h', streamHomeChannel],
            ],
            content: text,
            sig: '0' * 128,
          ),
        ];
      },
    );
    await tester.tap(_projectRow(platform));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('project-tab-activity')));
    await tester.pumpAndSettle();
    expect(find.text('Original message'), findsOneWidget);
    expect(reads, 1);

    text = 'New message';
    final indicator = tester.widget<RefreshIndicator>(
      find.descendant(
        of: find.byType(ProjectPage),
        matching: find.byType(RefreshIndicator),
      ),
    );
    await indicator.onRefresh();
    await tester.pumpAndSettle();
    expect(reads, 2);
    expect(find.text('New message'), findsOneWidget);
  });

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
      // The header is one line until tapped.
      expect(find.text('Relay, desktop, and mobile'), findsNothing);
      expect(
        find.textContaining('Relay, desktop, and mobile ·'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('project-summary')));
      await tester.pumpAndSettle();
      expect(find.text('Relay, desktop, and mobile'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('project-tab-channels')));
      await tester.pumpAndSettle();
      // The stream home is not visible to this viewer.
      expect(find.text('Unavailable channel'), findsOneWidget);
      final homeRow = tester.widget<AppListRowRaw>(
        find.descendant(
          of: find.byKey(const ValueKey('project-channel-$streamHomeChannel')),
          matching: find.byType(AppListRowRaw),
        ),
      );
      expect(homeRow.onTap, isNull);

      await tester.tap(find.byKey(const ValueKey('project-tab-repositories')));
      await tester.pumpAndSettle();
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
      expect(find.text('Repos'), findsOneWidget);

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

    testWidgets('the project page shows Tasks for its repositories', (
      tester,
    ) async {
      await _pumpChannels(
        tester,
        snapshot: _snapshot(CommunityFixture()),
        prefs: platformAdded(),
      );
      await openPlatformPage(tester);

      final page = tester.widget<ProjectTasksSection>(
        find.byKey(const ValueKey('project-tasks')),
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
  group('Apps tab', () {
    final sideHustles = projectAddress(alice, 'side-hustles');
    final appsProject = projectEvent(
      owner: alice,
      dtag: 'side-hustles',
      name: 'Side Hustles',
      channel: forumHomeChannel,
      createdAt: 1_700_000_500,
      repoAddresses: const [],
      extraTags: [
        ['buzz-app', 'https://side-hustles.acs.example.com/', 'Candidates'],
        ['buzz-app', 'https://board.example.com/view'],
        ['buzz-app', 'http://insecure.example.com/', 'Insecure'],
      ],
    );
    Map<String, Object> added(String address) => {
      _membershipKey: const ProjectSidebarMembershipStore()
          .withSelection(address, selected: true, updatedAt: 1)
          .encode(),
    };

    Future<void> openApps(WidgetTester tester, String address) async {
      await tester.tap(_projectRow(address));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('project-tab-apps')));
      await tester.pumpAndSettle();
    }

    testWidgets('lists the project apps with label and host', (tester) async {
      await _pumpChannels(
        tester,
        snapshot: _snapshot(CommunityFixture(), extraProjects: [appsProject]),
        prefs: added(sideHustles),
      );
      await openApps(tester, sideHustles);

      expect(find.text('Apps'), findsOneWidget);
      expect(find.byKey(const ValueKey('project-app-0')), findsOneWidget);
      expect(find.text('Candidates'), findsOneWidget);
      expect(find.text('side-hustles.acs.example.com'), findsOneWidget);
      // No label: the host is the label.
      expect(find.text('board.example.com'), findsNWidgets(2));
      // Only https apps are listed.
      expect(find.byKey(const ValueKey('project-app-2')), findsNothing);
      expect(find.text('Insecure'), findsNothing);
      expect(find.byKey(const ValueKey('project-apps-empty')), findsNothing);
    });

    testWidgets('explains how to add an app when there are none', (
      tester,
    ) async {
      await _pumpChannels(
        tester,
        snapshot: _snapshot(CommunityFixture()),
        prefs: added(platform),
      );
      await openApps(tester, platform);

      expect(find.byKey(const ValueKey('project-apps-empty')), findsOneWidget);
      expect(find.text('This project has no apps.'), findsOneWidget);
      expect(find.textContaining('--add-app'), findsOneWidget);
    });

    BuzzProjectAppHost hostFor(WidgetTester tester, String address) {
      final element = tester.element(find.byType(ProjectPage));
      final ref = element as WidgetRef;
      return BuzzProjectAppHost(
        context: element,
        ref: ref,
        project: ref.read(projectByAddressProvider(address))!,
      );
    }

    List<ComposeDraft> drafts(WidgetTester tester) => ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
      listen: false,
    ).read(composeDraftsProvider);

    testWidgets(
      'ui/message opens the forum home new-post composer with the draft',
      (tester) async {
        await _pumpChannels(
          tester,
          snapshot: _snapshot(CommunityFixture(), extraProjects: [appsProject]),
          prefs: {
            ...added(sideHustles),
            // An unsent draft the user already had stays first.
            'compose_drafts_v1:$relayOrigin:$alice': jsonEncode([
              ComposeDraft(
                key: forumHomeChannel,
                channelId: forumHomeChannel,
                threadHeadId: null,
                text: 'Earlier note',
                updatedAt: 1,
              ).toJson(),
            ]),
          },
        );
        await openApps(tester, sideHustles);

        await hostFor(
          tester,
          sideHustles,
        ).draftMessage('@Claude Forge dig deeper on Etsy printables');
        await tester.pumpAndSettle();

        const expected =
            'Earlier note\n\n@Claude Forge dig deeper on Etsy printables';
        expect(drafts(tester).single.key, forumHomeChannel);
        expect(drafts(tester).single.text, expected);
        // Forum home: the new-post composer is open with the draft, unsent.
        expect(find.byType(ForumPostsView), findsOneWidget);
        expect(find.byType(ComposeBar), findsOneWidget);
        // The collapsed composer previews the draft on one line.
        expect(
          find.descendant(
            of: find.byType(ComposeBar),
            matching: find.text(
              'Earlier note @Claude Forge dig deeper on Etsy printables',
            ),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('ui/message is refused without a readable home channel', (
      tester,
    ) async {
      final noHome = projectEvent(
        owner: alice,
        dtag: 'no-home',
        name: 'No Home',
        createdAt: 1_700_000_600,
        repoAddresses: const [],
      );
      await _pumpChannels(
        tester,
        snapshot: _snapshot(
          CommunityFixture(),
          extraProjects: [appsProject, noHome],
        ),
        channels: [_general],
        prefs: added(sideHustles),
      );
      await tester.tap(_projectRow(sideHustles));
      await tester.pumpAndSettle();

      await expectLater(
        hostFor(tester, sideHustles).draftMessage('hi'),
        throwsA(
          isA<ProjectAppHostException>().having(
            (e) => e.message,
            'message',
            'The project home channel is not available to you.',
          ),
        ),
      );
      await expectLater(
        hostFor(tester, projectAddress(alice, 'no-home')).draftMessage('hi'),
        throwsA(isA<ProjectAppHostException>()),
      );
      expect(drafts(tester), isEmpty);
      expect(find.byType(ForumPostsView), findsNothing);
    });

    testWidgets(
      'ui/message is refused when the viewer cannot post in the home forum',
      (tester) async {
        // Open and readable, but the viewer is not a member: the forum shows
        // no composer, so a saved draft could never be sent.
        await _pumpChannels(
          tester,
          snapshot: _snapshot(CommunityFixture(), extraProjects: [appsProject]),
          channels: [_general, _docsForum.copyWith(isMember: false)],
          prefs: added(sideHustles),
        );
        await openApps(tester, sideHustles);

        final host = hostFor(tester, sideHustles);
        final app = host.project.apps.first;
        final reply = await handleProjectAppMessage(
          app: app,
          projectApps: host.project.apps,
          origin: app.origin,
          fromAppFrame: true,
          data: {
            'jsonrpc': '2.0',
            'id': 7,
            'method': 'ui/message',
            'params': {
              'role': 'user',
              'content': {'type': 'text', 'text': 'hi'},
            },
          },
          host: host,
        );
        await tester.pumpAndSettle();

        expect(reply, {
          'jsonrpc': '2.0',
          'id': 7,
          'error': {
            'code': ProjectAppRpcError.denied,
            'message': 'Join the project home channel to post there.',
          },
        });
        expect(drafts(tester), isEmpty);
        expect(find.byType(ChannelDetailPage), findsNothing);
        expect(find.byType(ForumPostsView), findsNothing);
      },
    );
  });
}
