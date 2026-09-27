import 'dart:async';

import 'package:buzz/shared/projects/projects.dart';
import 'package:buzz/shared/relay/relay.dart';
import 'package:buzz/shared/theme/theme_provider.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_project_relay.dart';
import 'project_fixtures.dart';

class _RelayConfig extends RelayConfigNotifier {
  @override
  RelayConfig build() => const RelayConfig(baseUrl: relayOrigin);
}

class _Pubkey extends Notifier<String?> {
  @override
  String? build() => alice;

  void set(String? pubkey) => state = pubkey;
}

final _pubkeyProvider = NotifierProvider<_Pubkey, String?>(_Pubkey.new);

class _Lifecycle extends AppLifecycleNotifier {
  @override
  AppLifecycleState build() => AppLifecycleState.resumed;
}

const otherRelay = 'https://other.example.com';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeProjectRelaySession relay;
  late ProviderContainer container;

  Future<ProviderContainer> start(
    List<NostrEvent> events, {
    Set<int> failingKinds = const {},
    Map<String, Object> prefsValues = const {},
    Completer<void>? gate,
  }) async {
    SharedPreferences.setMockInitialValues(prefsValues);
    final prefs = await SharedPreferences.getInstance();
    relay = FakeProjectRelaySession(events)
      ..failingKinds.addAll(failingKinds)
      ..gate = gate;
    container = ProviderContainer(
      overrides: [
        savedPrefsProvider.overrideWithValue(prefs),
        relayConfigProvider.overrideWith(_RelayConfig.new),
        myPubkeyProvider.overrideWith((ref) => ref.watch(_pubkeyProvider)),
        relaySessionProvider.overrideWith(() => relay),
        appLifecycleProvider.overrideWith(_Lifecycle.new),
      ],
    );
    addTearDown(container.dispose);
    // Keep the collection alive like a mounted screen would.
    container.listen(activeProjectsProvider, (_, _) {});
    return container;
  }

  Future<ProjectsSnapshot> loaded() async {
    final scope = container.read(projectScopeProvider)!;
    return container.read(projectsProvider(scope).future);
  }

  test('loads the active community and resolves project homes', () async {
    await start(CommunityFixture().allEvents);
    final snapshot = await loaded();

    expect(snapshot.projects, hasLength(4));
    expect(snapshot.relayOrigin, relayOrigin);
    expect(
      container.read(projectHomeForChannelProvider(forumHomeChannel))?.dtag,
      'docs',
    );
    expect(
      container.read(isProjectHomeChannelProvider(streamHomeChannel)),
      isTrue,
    );
    expect(
      container
          .read(projectByAddressProvider(repoAddress(carol, 'sandbox')))
          ?.legacy,
      isTrue,
    );
  });

  test(
    'sidebar lists added explicit projects and persists per scope',
    () async {
      await start(CommunityFixture().allEvents);
      await loaded();
      expect(container.read(sidebarProjectsProvider), isEmpty);

      final membership = container.read(
        projectSidebarMembershipProvider.notifier,
      );
      expect(await membership.add(projectAddress(alice, 'platform')), isTrue);
      // Legacy projects never appear in the sidebar, even when added.
      await membership.add(repoAddress(carol, 'sandbox'));
      expect(container.read(sidebarProjectsProvider)!.map((p) => p.name), [
        'Platform',
      ]);

      final prefs = container.read(savedPrefsProvider);
      final stored = ProjectSidebarMembershipStore.decode(
        prefs.getString(
          'buzz.sidebar.projects.membership.v1:$relayOrigin:$alice',
        ),
      );
      expect(stored.selectedAddresses, {
        projectAddress(alice, 'platform'),
        repoAddress(carol, 'sandbox'),
      });

      await membership.remove(projectAddress(alice, 'platform'));
      expect(container.read(sidebarProjectsProvider), isEmpty);

      await container
          .read(projectSidebarViewProvider.notifier)
          .setFilter(SidebarProjectsFilter.owned);
      expect(container.read(sidebarProjectsProvider)!.map((p) => p.name), [
        'Docs',
        'Platform',
      ]);

      // Another identity on the same relay sees its own, empty membership.
      container.read(_pubkeyProvider.notifier).set(bob);
      expect(
        container.read(projectSidebarMembershipProvider).projects,
        isEmpty,
      );
      expect(
        container.read(projectSidebarViewProvider).filter,
        SidebarProjectsFilter.added,
      );
    },
  );

  test('a failed first load is an error, never an empty list', () async {
    await start(
      CommunityFixture().allEvents,
      failingKinds: {EventKind.projectAnnouncement},
    );
    await expectLater(loaded(), throwsA(isA<RelayException>()));

    final state = container.read(activeProjectsProvider);
    expect(state.hasError, isTrue);
    expect(state.hasValue, isFalse);
    expect(container.read(sidebarProjectsProvider), isNull);
  });

  test('a failed refresh keeps the previous snapshot visible', () async {
    await start(CommunityFixture().allEvents);
    await loaded();
    await container
        .read(projectSidebarMembershipProvider.notifier)
        .add(projectAddress(alice, 'platform'));

    relay.failingKinds.add(EventKind.deletion);
    await container.read(activeProjectsNotifierProvider)!.refresh();

    final state = container.read(activeProjectsProvider);
    expect(state.hasError, isTrue);
    expect(state.error, isA<ProjectsLoadException>());
    expect(state.value?.projects, hasLength(4));
    expect(container.read(sidebarProjectsProvider), hasLength(1));
  });

  test('refresh picks up a newly deleted project', () async {
    final f = CommunityFixture();
    await start(f.allEvents);
    await loaded();
    relay.events = [
      ...f.allEvents,
      deletionEvent(
        author: alice,
        coordinates: [projectAddress(alice, 'docs')],
        createdAt: 1_800_000_000,
      ),
    ];
    await container.read(activeProjectsNotifierProvider)!.refresh();
    final snapshot = container.read(activeProjectsProvider).value!;
    expect(snapshot.projectByAddress(projectAddress(alice, 'docs')), isNull);
    expect(
      container.read(isProjectHomeChannelProvider(forumHomeChannel)),
      isFalse,
    );
  });

  test('a relay reconnect retries a failed load', () async {
    await start(
      CommunityFixture().allEvents,
      failingKinds: {EventKind.projectAnnouncement},
    );
    await expectLater(loaded(), throwsA(isA<RelayException>()));

    relay.failingKinds.clear();
    relay.state = const SessionState(status: SessionStatus.reconnecting);
    relay.state = const SessionState(status: SessionStatus.connected);
    await pumpEventQueue();

    expect(
      container.read(activeProjectsProvider).value?.projects,
      hasLength(4),
    );
  });

  test('switching community never exposes the previous community', () async {
    await start(CommunityFixture().allEvents);
    await loaded();
    expect(container.read(sidebarProjectsProvider), isNotNull);

    relay.events = [
      repoEvent(owner: carol, dtag: 'elsewhere', clone: ['$otherRelay/x']),
    ];
    relay.gate = Completer<void>();
    container.read(relayConfigProvider.notifier).update(baseUrl: otherRelay);

    final switching = container.read(activeProjectsProvider);
    expect(switching.isLoading, isTrue);
    expect(switching.value, isNull);
    expect(
      container.read(isProjectHomeChannelProvider(streamHomeChannel)),
      isFalse,
    );
    expect(container.read(sidebarProjectsProvider), isNull);

    relay.gate!.complete();
    final snapshot = await loaded();
    expect(snapshot.scope.relayOrigin, otherRelay);
    expect(snapshot.projects.single.name, 'elsewhere');
  });

  group('offline-first snapshot cache', () {
    const aliceKey = 'buzz.projects.snapshot.v1:$relayOrigin:$alice';

    /// Loads once online and returns the persisted cache entry.
    Future<String> cachedEntry() async {
      await start(CommunityFixture().allEvents);
      await loaded();
      await pumpEventQueue();
      final raw = container.read(savedPrefsProvider).getString(aliceKey);
      expect(raw, isNotNull);
      container.dispose();
      return raw!;
    }

    test(
      'a cold start offline shows the cached snapshot and the error',
      () async {
        final raw = await cachedEntry();
        await start(
          const [],
          prefsValues: {aliceKey: raw},
          failingKinds: {
            EventKind.projectAnnouncement,
            EventKind.repoAnnouncement,
          },
        );
        await pumpEventQueue();

        final state = container.read(activeProjectsProvider);
        expect(state.hasError, isTrue);
        expect(state.error, isA<RelayException>());
        expect(state.value?.fromCache, isTrue);
        expect(state.value?.projects, hasLength(4));
        expect(
          container.read(isProjectHomeChannelProvider(forumHomeChannel)),
          isTrue,
        );
        // A deleted project stays deleted in the cached fold.
        expect(
          container.read(
            projectByAddressProvider(projectAddress(alice, 'retired')),
          ),
          isNull,
        );
      },
    );

    test('the cache paints first, then the relay result replaces it', () async {
      final raw = await cachedEntry();
      final gate = Completer<void>();
      await start(
        [
          ...CommunityFixture().allEvents,
          deletionEvent(
            author: alice,
            coordinates: [projectAddress(alice, 'docs')],
            createdAt: 1_800_000_000,
          ),
        ],
        prefsValues: {aliceKey: raw},
        gate: gate,
      );
      await pumpEventQueue();
      expect(container.read(activeProjectsProvider).value?.fromCache, isTrue);
      expect(
        container.read(isProjectHomeChannelProvider(forumHomeChannel)),
        isTrue,
      );

      gate.complete();
      await pumpEventQueue();
      final fresh = container.read(activeProjectsProvider).value!;
      expect(fresh.fromCache, isFalse);
      expect(fresh.projectByAddress(projectAddress(alice, 'docs')), isNull);
    });

    test(
      'switching account or community never shows another scope cache',
      () async {
        final raw = await cachedEntry();
        await start(
          CommunityFixture().allEvents,
          prefsValues: {aliceKey: raw},
          gate: Completer<void>(),
        );
        await pumpEventQueue();
        expect(container.read(activeProjectsProvider).value?.fromCache, isTrue);

        container.read(_pubkeyProvider.notifier).set(bob);
        await pumpEventQueue();
        expect(container.read(activeProjectsProvider).value, isNull);
        expect(container.read(sidebarProjectsProvider), isNull);

        container.read(_pubkeyProvider.notifier).set(alice);
        container
            .read(relayConfigProvider.notifier)
            .update(baseUrl: otherRelay);
        await pumpEventQueue();
        expect(container.read(activeProjectsProvider).value, isNull);
        expect(
          container.read(isProjectHomeChannelProvider(streamHomeChannel)),
          isFalse,
        );
      },
    );

    test('a corrupt cache entry is ignored', () async {
      await start(
        CommunityFixture().allEvents,
        prefsValues: {aliceKey: '{"version":1,"fetchedAt":"x"}'},
      );
      final snapshot = await loaded();
      expect(snapshot.fromCache, isFalse);
      expect(snapshot.projects, hasLength(4));
    });
  });
}
