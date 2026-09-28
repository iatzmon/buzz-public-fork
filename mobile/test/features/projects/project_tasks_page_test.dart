import 'package:buzz/features/projects/project_activity.dart';
import 'package:buzz/features/projects/project_activity_section.dart';
import 'package:buzz/features/projects/project_tasks_page.dart';
import 'package:buzz/shared/profile/user_cache_provider.dart';
import 'package:buzz/shared/profile/user_profile.dart';
import 'package:buzz/shared/projects/project_task_store.dart';
import 'package:buzz/shared/community/community_membership_provider.dart';
import 'package:buzz/shared/relay/relay.dart';
import 'package:buzz/shared/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _owner = 'b' * 64;
final _viewer = 'a' * 64;
final _carol = 'c' * 64;
final _repo = '30617:$_owner:app';
final _secondRepo = '30617:$_owner:website';
NostrEvent _event(
  String id, {
  int kind = 1621,
  String? signer,
  List<List<String>>? tags,
  String content = 'Read the task details',
}) => NostrEvent(
  id: id.padLeft(64, '0'),
  pubkey: signer ?? _owner,
  createdAt: 10,
  kind: kind,
  tags:
      tags ??
      [
        ['a', _repo],
        ['subject', 'Mobile project task'],
      ],
  content: content,
  sig: '0' * 128,
);

class _Config extends RelayConfigNotifier {
  @override
  RelayConfig build() => const RelayConfig(baseUrl: 'https://tasks.example');
}

class _Profiles extends UserCacheNotifier {
  @override
  Map<String, UserProfile> build() => {
    _viewer: UserProfile(pubkey: _viewer, displayName: 'You'),
    _carol: UserProfile(pubkey: _carol, displayName: 'Carol'),
  };
  @override
  Future<bool> preload(List<String> pubkeys) async => true;
}

/// Community member list served to the screens; tests may replace it.
CommunityMembershipSnapshot communityOwnersSnapshot =
    const CommunityMembershipSnapshot(snapshotFound: false, members: []);

void main() {
  // Channel message reads fail while this is set.
  var failMessages = false;
  setUp(() => failMessages = false);

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    bool fail = false,
    required List<NostrEvent> published,
    Map<String, String>? repositories,
    bool accountSwitch = false,
    List<NostrEvent> history = const [],
    bool failTasks = false,
    String? viewer,
    Widget? home,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        savedPrefsProvider.overrideWithValue(prefs),
        communityMembershipProvider.overrideWith(
          (ref) async => communityOwnersSnapshot,
        ),
        relayConfigProvider.overrideWith(_Config.new),
        myPubkeyProvider.overrideWith(
          (ref) =>
              accountSwitch && ref.watch(relayConfigProvider).nsec == 'second'
              ? 'd' * 64
              : viewer ?? _viewer,
        ),
        userCacheProvider.overrideWith(_Profiles.new),
        projectTaskTransportProvider.overrideWithValue(
          ProjectTaskTransport(
            query: (filter) async {
              if (failTasks && !filter.tags.containsKey('#h')) {
                throw StateError('Offline');
              }
              if (filter.kinds.contains(1621)) {
                return [_event('1')];
              }
              // Channel reads match kinds, tags, and the relay's
              // `(until, before_id)` cursor, and return rows newest first,
              // then by id, like the relay.
              if (filter.tags['#h'] case final channels?) {
                if (failMessages) throw StateError('Offline');
                final ids = filter.tags['#e'];
                final beforeId = filter.extensions['before_id'] as String?;
                return ([
                      for (final e in history)
                        if (filter.kinds.contains(e.kind) &&
                            channels.contains(e.getTagValue('h')) &&
                            (ids == null ||
                                e.tags.any(
                                  (t) =>
                                      t.length > 1 &&
                                      t[0] == 'e' &&
                                      ids.contains(t[1]),
                                )) &&
                            (filter.until == null ||
                                e.createdAt < filter.until! ||
                                (e.createdAt == filter.until! &&
                                    (beforeId == null ||
                                        e.id.compareTo(beforeId) > 0))))
                          e,
                    ]..sort(
                      (a, b) => a.createdAt != b.createdAt
                          ? b.createdAt.compareTo(a.createdAt)
                          : a.id.compareTo(b.id),
                    ))
                    .take(filter.limit)
                    .toList();
              }
              return history;
            },
            publish: (e) async {
              published.add(e);
              if (fail) throw StateError('Offline');
            },
            sign: (kind, content, tags, time) => _event(
              '99',
              kind: kind,
              signer: _viewer,
              tags: tags,
              content: content,
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home:
              home ??
              ProjectTasksPage(
                repositories: repositories ?? {_repo: 'App'},
                channelId: 'channel',
              ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets(
    'opens actual task detail and self-assigns through signed operation',
    (tester) async {
      final published = <NostrEvent>[];
      await pump(tester, published: published);
      await tester.tap(find.text('Mobile project task'));
      await tester.pumpAndSettle();
      expect(find.text('Read the task details'), findsOneWidget);
      expect(find.text('Assign member'), findsNothing);
      await tester.tap(find.text('Assign to me'));
      await tester.pumpAndSettle();
      expect(published.single.kind, 1);
      expect(published.single.tags, contains(equals(['t', 'assignment'])));
      expect(published.single.tags, contains(equals(['p', _viewer])));
      expect(find.text('You'), findsNWidgets(2));
      expect(find.byTooltip('Unassign You'), findsOneWidget);
    },
  );
  testWidgets(
    'failed create keeps draft and exposes retry after navigating away',
    (tester) async {
      final published = <NostrEvent>[];
      await pump(tester, published: published, fail: true);
      await tester.tap(find.byTooltip('Create task'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Title'),
        'Save my task',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Description'),
        'Keep this body',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Create task'));
      await tester.pumpAndSettle();
      expect(find.text('Retry send'), findsOneWidget);
      expect(find.text('Save my task'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('1 change is waiting to send.'), findsOneWidget);
      await tester.tap(find.byTooltip('Create task'));
      await tester.pumpAndSettle();
      expect(find.text('Save my task'), findsOneWidget);
      expect(find.text('Keep this body'), findsOneWidget);
    },
  );
  testWidgets('a multi-repository project lists each task once, labelled', (
    tester,
  ) async {
    await pump(
      tester,
      published: [],
      repositories: {_repo: 'App', _secondRepo: 'Website'},
    );
    // The relay returns the App task to both repository scans; only the App
    // list keeps it.
    expect(find.text('Mobile project task'), findsOneWidget);
    expect(find.textContaining('App ·'), findsOneWidget);
    expect(find.textContaining('Website'), findsNothing);
  });
  for (final compose in [false, true]) {
    testWidgets(
      'same-community account switch hides ${compose ? 'compose' : 'detail'} actions',
      (tester) async {
        final published = <NostrEvent>[];
        final container = await pump(
          tester,
          published: published,
          accountSwitch: true,
        );
        await tester.tap(
          compose
              ? find.byTooltip('Create task')
              : find.text('Mobile project task'),
        );
        await tester.pumpAndSettle();
        if (compose) {
          await tester.enterText(
            find.widgetWithText(TextField, 'Title'),
            'Private draft',
          );
          await tester.pumpAndSettle();
        }
        container
            .read(relayConfigProvider.notifier)
            .update(baseUrl: 'https://tasks.example', nsec: 'second');
        await tester.pumpAndSettle();
        expect(
          find.text('Community or account changed. Reopen Tasks to continue.'),
          findsOneWidget,
        );
        expect(find.text('Assign to me'), findsNothing);
        expect(find.widgetWithText(FilledButton, 'Create task'), findsNothing);
        expect(find.text('Private draft'), findsNothing);
        expect(published, isEmpty);
      },
    );
  }
  testWidgets('malformed signed assignment cannot crash task detail', (
    tester,
  ) async {
    await pump(
      tester,
      published: [],
      history: [
        _event(
          '2',
          kind: 1,
          tags: [
            ['e', _event('1').id],
            ['a', _repo],
            ['p', 'x'],
            ['t', 'assignment'],
          ],
        ),
      ],
    );
    await tester.tap(find.text('Mobile project task'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Unassigned'), findsOneWidget);
  });
  testWidgets('community switch hides an open task and its action controls', (
    tester,
  ) async {
    final container = await pump(tester, published: []);
    await tester.tap(find.text('Mobile project task'));
    await tester.pumpAndSettle();
    container
        .read(relayConfigProvider.notifier)
        .update(baseUrl: 'https://other.example');
    await tester.pumpAndSettle();
    expect(find.text('Mobile project task'), findsNothing);
    expect(find.text('Assign to me'), findsNothing);
    expect(
      find.text('Community or account changed. Reopen Tasks to continue.'),
      findsOneWidget,
    );
  });
  testWidgets('status filters split open and finished tasks', (tester) async {
    await pump(
      tester,
      published: [],
      history: [
        _event(
          '3',
          kind: 1631,
          tags: [
            ['e', _event('1').id, '', 'root'],
            ['a', _repo],
          ],
        ),
      ],
    );
    expect(find.text('Mobile project task'), findsNothing);
    expect(find.text('No open tasks.'), findsOneWidget);
    await tester.tap(find.text('Finished (1)'));
    await tester.pumpAndSettle();
    expect(find.text('Mobile project task'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
    await tester.tap(find.text('Assigned to me (0)'));
    await tester.pumpAndSettle();
    expect(find.text('No tasks assigned to you.'), findsOneWidget);
  });
  testWidgets('the owner assigns a channel member from the member sheet', (
    tester,
  ) async {
    final published = <NostrEvent>[];
    await pump(
      tester,
      published: published,
      viewer: _owner,
      history: [
        _event(
          '4',
          kind: 39002,
          tags: [
            ['d', 'channel'],
            ['p', _carol],
          ],
        ),
      ],
    );
    await tester.tap(find.text('Mobile project task'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Assign a member'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Carol'));
    await tester.pumpAndSettle();
    expect(published.single.kind, 1);
    expect(published.single.tags, contains(equals(['p', _carol])));
    expect(published.single.tags, contains(equals(['t', 'assignment'])));
  });
  testWidgets('activity hides assignment changes the task state ignores', (
    tester,
  ) async {
    List<List<String>> assign(String who) => [
      ['e', _event('1').id, '', 'root'],
      ['a', _repo],
      ['p', who],
      ['t', 'assignment'],
    ];
    await pump(
      tester,
      published: [],
      history: [
        // A member who is not the author or owner cannot assign Carol.
        _event('5', kind: 1, signer: 'd' * 64, tags: assign(_carol)),
        // The repository owner can.
        _event('6', kind: 1, tags: assign(_viewer)),
      ],
    );
    await tester.tap(find.text('Mobile project task'));
    await tester.pumpAndSettle();
    expect(find.textContaining('assigned Carol'), findsNothing);
    expect(find.textContaining('assigned You'), findsOneWidget);
  });
  for (final variant in ['uppercase E', 'stale prior']) {
    testWidgets('activity hides a self-assignment with $variant', (
      tester,
    ) async {
      await pump(
        tester,
        published: [],
        history: [
          _event(
            '7',
            kind: 1,
            signer: _carol,
            tags: [
              [
                variant == 'uppercase E' ? 'E' : 'e',
                _event('1').id,
                '',
                'root',
              ],
              ['a', _repo],
              ['p', _carol],
              ['t', 'assignment'],
              if (variant == 'stale prior') ['prior', 'f' * 64],
            ],
          ),
        ],
      );
      await tester.tap(find.text('Mobile project task'));
      await tester.pumpAndSettle();
      expect(find.text('Unassigned'), findsOneWidget);
      expect(find.textContaining('assigned themselves'), findsNothing);
    });
  }
  testWidgets('screen readers can open a task and use its actions', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pump(tester, published: []);
    final row = tester.getSemantics(find.byKey(ValueKey(_event('1').id)));
    expect(row.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    await tester.tap(find.text('Mobile project task'));
    await tester.pumpAndSettle();
    final assign = tester.getSemantics(
      find.byKey(const ValueKey('project-task-assign-me')),
    );
    expect(assign.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    semantics.dispose();
  });
  testWidgets('the member sheet cannot assign after a community switch', (
    tester,
  ) async {
    final published = <NostrEvent>[];
    final container = await pump(
      tester,
      published: published,
      viewer: _owner,
      history: [
        _event(
          '4',
          kind: 39002,
          tags: [
            ['d', 'channel'],
            ['p', _carol],
          ],
        ),
      ],
    );
    await tester.tap(find.text('Mobile project task'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Assign a member'));
    await tester.pumpAndSettle();
    container
        .read(relayConfigProvider.notifier)
        .update(baseUrl: 'https://other.example');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Carol'));
    await tester.pumpAndSettle();
    expect(published, isEmpty);
  });
  testWidgets('the repository sheet cannot open a composer after a switch', (
    tester,
  ) async {
    final container = await pump(
      tester,
      published: [],
      repositories: {_repo: 'App', _secondRepo: 'Website'},
    );
    await tester.tap(find.byTooltip('Create task'));
    await tester.pumpAndSettle();
    container
        .read(relayConfigProvider.notifier)
        .update(baseUrl: 'https://other.example');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Website'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Title'), findsNothing);
  });
  group('community owners', () {
    final communityOwner = 'e' * 64;
    setUp(() {
      communityOwnersSnapshot = CommunityMembershipSnapshot(
        snapshotFound: true,
        members: [
          CommunityMember(
            pubkey: communityOwner,
            role: CommunityMemberRole.owner,
          ),
          CommunityMember(pubkey: _carol, role: CommunityMemberRole.admin),
        ],
      );
    });
    tearDown(() {
      communityOwnersSnapshot = const CommunityMembershipSnapshot(
        snapshotFound: false,
        members: [],
      );
    });

    testWidgets('a community owner assigns a member on any task', (
      tester,
    ) async {
      final published = <NostrEvent>[];
      await pump(
        tester,
        published: published,
        viewer: communityOwner,
        history: [
          _event(
            '4',
            kind: 39002,
            tags: [
              ['d', 'channel'],
              ['p', _carol],
            ],
          ),
        ],
      );
      await tester.tap(find.text('Mobile project task'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Assign a member'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Carol'));
      await tester.pumpAndSettle();
      expect(published.single.pubkey, _viewer);
      expect(published.single.tags, contains(equals(['p', _carol])));
    });

    testWidgets('assignments by a community owner count; by an admin, not', (
      tester,
    ) async {
      List<List<String>> assign(String who) => [
        ['e', _event('1').id, '', 'root'],
        ['a', _repo],
        ['p', who],
        ['t', 'assignment'],
      ];
      await pump(
        tester,
        published: [],
        history: [
          _event('8', kind: 1, signer: communityOwner, tags: assign(_viewer)),
          _event('9', kind: 1, signer: _carol, tags: assign('f' * 64)),
        ],
      );
      await tester.tap(find.text('Mobile project task'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(ValueKey('project-task-assignee-$_viewer')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('project-task-assignee-${'f' * 64}')),
        findsNothing,
      );
    });
  });

  testWidgets('a member who is not a community owner cannot assign others', (
    tester,
  ) async {
    await pump(tester, published: [], viewer: 'e' * 64);
    await tester.tap(find.text('Mobile project task'));
    await tester.pumpAndSettle();
    expect(find.text('Assign a member'), findsNothing);
    expect(find.text('Assign to me'), findsOneWidget);
  });

  testWidgets('Activity lists task changes and channel messages', (
    tester,
  ) async {
    final opened = <String>[];
    final message = _event(
      'a1',
      kind: 9,
      signer: _carol,
      tags: [
        ['h', 'channel'],
      ],
      content: 'Shipping the build today',
    );
    final removed = _event(
      'a2',
      kind: 9,
      signer: _carol,
      tags: [
        ['h', 'channel'],
      ],
      content: 'This was deleted',
    );
    await pump(
      tester,
      published: [],
      history: [
        message,
        removed,
        // A member cannot assign someone else: the feed must not show it.
        _event(
          'a4',
          kind: 1,
          signer: _carol,
          tags: [
            ['e', _event('1').id, '', 'root'],
            ['a', _repo],
            ['p', 'f' * 64],
            ['t', 'assignment'],
          ],
        ),
        _event(
          'a3',
          kind: 5,
          signer: _carol,
          tags: [
            ['h', 'channel'],
            ['e', removed.id],
          ],
        ),
      ],
      home: Scaffold(
        body: ListView(
          children: [
            ProjectActivitySection(
              repositories: {_repo: 'App'},
              channelNames: const {'channel': 'general'},
              onOpenChannel: opened.add,
            ),
          ],
        ),
      ),
    );
    expect(find.textContaining('created a task'), findsOneWidget);
    expect(find.text('Mobile project task'), findsOneWidget);
    expect(find.textContaining('in #general'), findsOneWidget);
    expect(find.text('Shipping the build today'), findsOneWidget);
    expect(find.text('This was deleted'), findsNothing);
    expect(find.textContaining('assigned'), findsNothing);
    await tester.tap(find.text('Shipping the build today'));
    await tester.pumpAndSettle();
    expect(opened, ['channel']);
  });

  testWidgets('Load more shows older channel messages', (tester) async {
    final messages = [
      for (var i = 0; i < projectActivityPageSize + 5; i++)
        NostrEvent(
          id: 'm$i'.padLeft(64, '0'),
          pubkey: _carol,
          createdAt: 1000 + i,
          kind: 9,
          tags: const [
            ['h', 'channel'],
          ],
          content: 'Message $i',
          sig: '0' * 128,
        ),
    ];
    await pump(
      tester,
      published: [],
      history: messages,
      home: Scaffold(
        body: ListView(
          children: [
            ProjectActivitySection(
              repositories: {_repo: 'App'},
              channelNames: const {'channel': 'general'},
              onOpenChannel: (_) {},
            ),
          ],
        ),
      ),
    );
    expect(find.text('Message 0', skipOffstage: false), findsNothing);
    final more = find.byKey(const ValueKey('project-activity-more'));
    await tester.ensureVisible(more);
    await tester.pumpAndSettle();
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(find.text('Message 0', skipOffstage: false), findsOneWidget);
    // The oldest item is the task, created before every message.
    expect(
      find.textContaining('created a task', skipOffstage: false),
      findsOneWidget,
    );
  });

  NostrEvent message(int i) => NostrEvent(
    id: 'm$i'.padLeft(64, '0'),
    pubkey: _carol,
    createdAt: 1000 + i,
    kind: 9,
    tags: const [
      ['h', 'channel'],
    ],
    content: 'Message $i',
    sig: '0' * 128,
  );

  Widget activity() => Scaffold(
    body: ListView(
      children: [
        ProjectActivitySection(
          repositories: {_repo: 'App'},
          channelNames: const {'channel': 'general'},
          onOpenChannel: (_) {},
        ),
      ],
    ),
  );

  testWidgets('deleted newest messages do not hide older messages', (
    tester,
  ) async {
    final messages = [
      for (var i = 0; i < projectActivityPageSize + 5; i++) message(i),
    ];
    await pump(
      tester,
      published: [],
      history: [
        ...messages,
        // Every message on the first page is deleted.
        for (final m in messages.skip(5))
          NostrEvent(
            id: 'd${m.id.substring(1)}',
            pubkey: _carol,
            createdAt: m.createdAt + 100,
            kind: 5,
            tags: [
              ['h', 'channel'],
              ['e', m.id],
            ],
            content: '',
            sig: '0' * 128,
          ),
      ],
      home: activity(),
    );
    expect(find.textContaining('Message ', skipOffstage: false), findsNothing);
    expect(find.text('No activity yet.'), findsNothing);
    final more = find.byKey(const ValueKey('project-activity-more'));
    await tester.ensureVisible(more);
    await tester.pumpAndSettle();
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(find.text('Message 0', skipOffstage: false), findsOneWidget);
    expect(find.text('Message 4', skipOffstage: false), findsOneWidget);
    expect(find.text('Message 5', skipOffstage: false), findsNothing);
  });

  testWidgets('Load more reaches messages that share one second', (
    tester,
  ) async {
    await pump(
      tester,
      published: [],
      history: [
        for (var i = 0; i <= projectActivityPageSize; i++)
          NostrEvent(
            id: 'm$i'.padLeft(64, '0'),
            pubkey: _carol,
            createdAt: 1000,
            kind: 9,
            tags: const [
              ['h', 'channel'],
            ],
            content: 'Tied $i',
            sig: '0' * 128,
          ),
      ],
      home: activity(),
    );
    final last = 'Tied $projectActivityPageSize';
    expect(find.text(last, skipOffstage: false), findsNothing);
    final more = find.byKey(const ValueKey('project-activity-more'));
    await tester.ensureVisible(more);
    await tester.pumpAndSettle();
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(find.text(last, skipOffstage: false), findsOneWidget);
    expect(find.text('Tied 0', skipOffstage: false), findsOneWidget);
  });

  testWidgets('a failed refresh keeps messages and shows Retry', (
    tester,
  ) async {
    final history = [message(1)];
    await pump(tester, published: [], history: history, home: activity());
    expect(find.text('Message 1'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
    history.clear();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ProjectActivitySection)),
    );
    failMessages = true;
    container.invalidate(projectMessagePageProvider);
    await tester.pumpAndSettle();
    expect(find.text('Message 1'), findsOneWidget);
    expect(find.text('Channel messages could not be loaded.'), findsOneWidget);
    failMessages = false;
    history.add(message(2));
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Message 2'), findsOneWidget);
    expect(find.text('Channel messages could not be loaded.'), findsNothing);
  });

  testWidgets('a failed task load shows an error and Retry', (tester) async {
    await pump(tester, published: [], failTasks: true, home: activity());
    expect(find.text('No activity yet.'), findsNothing);
    expect(find.text('Some task changes could not be loaded.'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });
}
