import 'dart:async';

import 'package:buzz/shared/community/community_membership_provider.dart';
import 'package:buzz/shared/projects/project_task.dart';
import 'package:buzz/shared/projects/project_task_store.dart';
import 'package:buzz/shared/relay/relay.dart';
import 'package:buzz/shared/theme/theme_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:hooks_riverpod/legacy.dart';
import 'package:nostr/nostr.dart' as nostr;
import 'package:shared_preferences/shared_preferences.dart';

final author = 'a' * 64;
final owner = 'b' * 64;
final member = 'c' * 64;
final stranger = 'd' * 64;
final repo = '30617:$owner:app';

NostrEvent event(
  String id, {
  int kind = 1,
  String? signer,
  int time = 1,
  List<List<String>> tags = const [],
  String content = '',
}) => NostrEvent(
  id: id.padLeft(64, '0'),
  pubkey: signer ?? author,
  createdAt: time,
  kind: kind,
  tags: tags,
  content: content,
  sig: '0' * 128,
);
NostrEvent root() => event(
  '1',
  kind: 1621,
  tags: [
    ['a', repo],
    ['subject', 'Ship mobile'],
    ['p', member],
  ],
  content: 'The task body',
);
NostrEvent operation(
  String id,
  String signer,
  String target, {
  bool assign = true,
  int time = 1,
  String? prior,
}) => event(
  id,
  signer: signer,
  time: time,
  tags: [
    ['e', root().id, '', 'root'],
    ['a', repo],
    ['p', target],
    ['t', assign ? 'assignment' : 'unassignment'],
    if (prior != null) ['prior', prior],
  ],
);

class Config extends RelayConfigNotifier {
  @override
  RelayConfig build() => const RelayConfig(baseUrl: 'https://tasks.example');
}

class QuerySession extends RelaySessionNotifier {
  List<NostrEvent> events = [];
  @override
  SessionState build() => const SessionState(status: SessionStatus.connected);
  @override
  Future<List<NostrEvent>> queryRelay(
    List<NostrFilter> filters, {
    Duration timeout = const Duration(seconds: 8),
  }) async => events;
}

String testNsec(String digit) => nostr.Nip19.encode(
  prefix: nostr.Nip19Prefix.nsec,
  data: digit.padLeft(64, '0'),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'event verification accepts valid signatures and rejects altered content',
    () async {
      final signed = nostr.Event.from(
        kind: 1621,
        content: 'Authentic',
        tags: [
          ['a', repo],
        ],
        secretKey: '1'.padLeft(64, '0'),
        createdAt: 100,
      ).toMap();
      for (final verify in [
        verifyProjectTaskEvents,
        verifyProjectTaskEventsInSlices,
      ]) {
        final events = await verify([NostrEvent.fromJson(signed)]);
        expect(events.single.content, 'Authentic');
        await expectLater(
          verify([
            NostrEvent.fromJson(signed),
            NostrEvent.fromJson({...signed, 'content': 'Altered'}),
          ]),
          throwsA(isA<Exception>()),
        );
      }
    },
  );
  test(
    'production transport verifies relay events before returning them',
    () async {
      final c = ProviderContainer(
        overrides: [
          relayConfigProvider.overrideWith(Config.new),
          relaySessionProvider.overrideWith(QuerySession.new),
        ],
      );
      addTearDown(c.dispose);
      final session = c.read(relaySessionProvider.notifier) as QuerySession;
      final signed = nostr.Event.from(
        kind: 1621,
        content: 'Authentic',
        tags: [
          ['a', repo],
        ],
        secretKey: '1'.padLeft(64, '0'),
        createdAt: 100,
      ).toMap();
      final transport = c.read(projectTaskTransportProvider);
      session.events = [
        NostrEvent.fromJson({...signed, 'content': 'Forged'}),
      ];
      await expectLater(
        transport.query(const NostrFilter(kinds: [1621])),
        throwsA(isA<Exception>()),
      );
      final scanned = await transport.scan(const NostrFilter(kinds: [1621]));
      await expectLater(transport.verify(scanned), throwsA(isA<Exception>()));
      session.events = [NostrEvent.fromJson(signed)];
      expect(
        (await transport.query(
          const NostrFilter(kinds: [1621]),
        )).single.content,
        'Authentic',
      );
      session.events = [
        NostrEvent.fromJson({...signed, 'content': 'Replaced after cache'}),
      ];
      expect(
        (await transport.query(
          const NostrFilter(kinds: [1621]),
        )).single.content,
        'Authentic',
      );
    },
  );
  test('malformed assignee tags are ignored even from the task author', () {
    for (final key in ['x', '', 'z' * 64, 'a' * 63]) {
      expect(
        ProjectTask.fromEvents(root(), [operation('2', author, key)]).assignees,
        isEmpty,
      );
    }
  });
  test(
    'uppercase references are not assignment or status operations; status ties preserve relay order',
    () {
      final upper = event(
        '2',
        kind: 1631,
        tags: [
          ['E', root().id],
        ],
      );
      final assignment = event(
        '3',
        tags: [
          ['E', root().id],
          ['t', 'assignment'],
          ['p', member],
        ],
      );
      expect(
        ProjectTask.fromEvents(root(), [upper, assignment]).assignees,
        isEmpty,
      );
      expect(ProjectTask.fromEvents(root(), [upper]).status, 'Backlog');
      expect(
        ProjectTask.fromEvents(root(), [
          event(
            '2',
            kind: 1631,
            tags: [
              ['e', root().id],
            ],
          ),
          event(
            '3',
            kind: 1632,
            tags: [
              ['e', root().id],
            ],
          ),
        ]).status,
        'Done',
      );
    },
  );
  test(
    'repository discovery reaches older tasks behind other repositories',
    () async {
      var calls = 0;
      final checked = <String>[];
      final roots = await loadProjectTaskRoots(
        repo,
        (filter) async {
          expect(filter.tags, isEmpty);
          calls++;
          if (calls == 1) {
            return [
              for (var i = 0; i < 500; i++)
                event(
                  '$i',
                  kind: 1621,
                  time: 1000 - i,
                  tags: [
                    ['a', '30617:$owner:unrelated'],
                  ],
                ),
            ];
          }
          return [root()];
        },
        verify: (events) async {
          checked.addAll(events.map((e) => e.id));
          return events;
        },
      );
      expect(calls, 2);
      expect(roots.single.id, root().id);
      // Other repositories' tasks are never checked: in the browser each
      // signature check blocks the page for about 60 ms.
      expect(checked, [root().id]);
    },
  );
  test('discovery keeps only tasks that verify as this repository', () async {
    final other = event(
      '1',
      kind: 1621,
      tags: [
        ['a', '30617:$owner:unrelated'],
      ],
    );
    final roots = await loadProjectTaskRoots(
      repo,
      (filter) async => [root()],
      // A verifier that returns the event it checked earlier under this id.
      verify: (events) async => [other],
    );
    expect(roots, isEmpty);
  });
  test(
    'recipients and unauthorized assignment/status events do not confer authority',
    () {
      final task = ProjectTask.fromEvents(root(), [
        operation('2', stranger, member),
        event(
          '3',
          kind: 1631,
          signer: stranger,
          tags: [
            ['e', root().id],
          ],
        ),
      ]);
      expect(task.assignees, isEmpty);
      expect(task.status, 'Backlog');
      expect(task.canManage(author), isTrue);
      expect(task.canManage(owner), isTrue);
      expect(task.canManage(stranger), isFalse);
    },
  );
  test('owner removal defeats future-dated uncaused self assignment', () {
    final task = ProjectTask.fromEvents(root(), [
      operation('2', member, member, time: 999999),
      operation('3', owner, member, assign: false, time: 2),
    ]);
    expect(task.assignees, isEmpty);
    expect(task.assignmentHeads[member], '3'.padLeft(64, '0'));
  });
  test('a community owner is an authority for assignments and status', () {
    final boss = 'e' * 64;
    final assign = operation('7', boss, member, time: 2);
    final done = event(
      '8',
      kind: 1631,
      signer: boss,
      time: 3,
      tags: [
        ['e', root().id, '', 'root'],
      ],
    );
    final withOwner = ProjectTask.fromEvents(
      root(),
      [assign, done],
      communityOwners: {boss},
    );
    expect(withOwner.assignees, {member});
    expect(withOwner.status, 'Done');
    expect(withOwner.canManage(boss), isTrue);
    expect(
      projectTaskAssignmentTags(
        task: withOwner,
        signer: boss,
        assignee: stranger,
        assign: true,
      ),
      contains(equals(['p', stranger])),
    );
    final without = ProjectTask.fromEvents(root(), [assign, done]);
    expect(without.assignees, isEmpty);
    expect(without.status, isNot('Done'));
    expect(without.canManage(boss), isFalse);
  });
  test('community owners are empty until the member list loads', () async {
    final pending = Completer<CommunityMembershipSnapshot>();
    final c = ProviderContainer(
      overrides: [
        communityMembershipProvider.overrideWith((ref) => pending.future),
      ],
    );
    addTearDown(c.dispose);
    final sub = c.listen(projectTaskCommunityOwnersProvider, (_, _) {});
    addTearDown(sub.close);
    expect(c.read(projectTaskCommunityOwnersProvider), isEmpty);
    pending.complete(
      CommunityMembershipSnapshot(
        snapshotFound: true,
        members: [
          CommunityMember(pubkey: 'E' * 64, role: CommunityMemberRole.owner),
          CommunityMember(pubkey: member, role: CommunityMemberRole.admin),
        ],
      ),
    );
    await pending.future;
    await Future<void>.delayed(Duration.zero);
    expect(c.read(projectTaskCommunityOwnersProvider), {'e' * 64});
  });
  test('a reloading member list does not keep the old owners', () async {
    final first = CommunityMembershipSnapshot(
      snapshotFound: true,
      members: [
        CommunityMember(pubkey: 'e' * 64, role: CommunityMemberRole.owner),
      ],
    );
    final second = Completer<CommunityMembershipSnapshot>();
    final community = StateProvider<int>((ref) => 0);
    final c = ProviderContainer(
      overrides: [
        communityMembershipProvider.overrideWith(
          (ref) =>
              ref.watch(community) == 0 ? Future.value(first) : second.future,
        ),
      ],
    );
    addTearDown(c.dispose);
    final sub = c.listen(projectTaskCommunityOwnersProvider, (_, _) {});
    addTearDown(sub.close);
    await Future<void>.delayed(Duration.zero);
    expect(c.read(projectTaskCommunityOwnersProvider), {'e' * 64});
    // A community switch reloads the list; the old owners must not apply.
    c.read(community.notifier).state = 1;
    await Future<void>.delayed(Duration.zero);
    expect(c.read(projectTaskCommunityOwnersProvider), isEmpty);
  });
  test('applied assignment ids list only operations the state used', () {
    final removal = operation('3', owner, member, assign: false, time: 2);
    final valid = operation('4', member, member, time: 3, prior: removal.id);
    final stale = operation(
      '5',
      member,
      member,
      assign: false,
      time: 4,
      prior: removal.id,
    );
    final foreign = operation('6', stranger, member, time: 5);
    final task = ProjectTask.fromEvents(root(), [
      stale,
      valid,
      removal,
      foreign,
    ]);
    expect(task.appliedAssignmentIds, {removal.id, valid.id});
  });
  test('self service must reference the current authority head', () {
    final removal = operation('3', owner, member, assign: false, time: 2);
    final valid = operation('4', member, member, time: 3, prior: removal.id);
    final stale = operation(
      '5',
      member,
      member,
      assign: false,
      time: 4,
      prior: removal.id,
    );
    final task = ProjectTask.fromEvents(root(), [stale, valid, removal]);
    expect(task.assignees, {member});
    expect(task.assignmentHeads[member], valid.id);
    expect(
      projectTaskAssignmentTags(
        task: task,
        signer: member,
        assignee: member,
        assign: false,
      ),
      contains(equals(['prior', valid.id])),
    );
  });
  test(
    'unrelated roots, conflicting labels, and malformed priors are ignored',
    () {
      final task = ProjectTask.fromEvents(root(), [
        event(
          '2',
          tags: [
            ['e', 'wrong'],
            ['t', 'assignment'],
            ['p', member],
          ],
        ),
        event(
          '3',
          tags: [
            ['e', root().id],
            ['t', 'assignment'],
            ['t', 'unassignment'],
            ['p', member],
          ],
        ),
        operation('4', member, member, prior: 'bad'),
      ]);
      expect(task.assignees, isEmpty);
    },
  );
  test('status lifecycle reads author/owner decisions', () {
    expect(
      ProjectTask.fromEvents(root(), [
        event(
          '2',
          kind: 1631,
          signer: owner,
          tags: [
            ['e', root().id],
          ],
        ),
      ]).status,
      'Done',
    );
    expect(
      ProjectTask.fromEvents(root(), [
        event(
          '2',
          kind: 1632,
          tags: [
            ['e', root().id],
          ],
        ),
      ]).status,
      'Closed',
    );
  });
  test('status notes join comments in Activity from any signer', () {
    final target = [
      ['e', root().id, '', 'root'],
    ];
    final task = ProjectTask.fromEvents(root(), [
      event('2', kind: 1111, time: 2, tags: target, content: 'A comment'),
      event(
        '3',
        kind: 1630,
        signer: owner,
        time: 3,
        tags: target,
        content: 'Next: open the PR',
      ),
      event('4', kind: 1631, signer: owner, time: 4, tags: target),
      event(
        '5',
        kind: 1632,
        signer: stranger,
        time: 1,
        tags: target,
        content: 'Untrusted note',
      ),
      event(
        '6',
        kind: 1631,
        signer: owner,
        time: 5,
        tags: [
          ['e', 'f' * 64],
        ],
        content: 'Another task',
      ),
    ]);
    expect(task.statusNotes.map((e) => e.content), [
      'Untrusted note',
      'Next: open the PR',
    ]);
    expect(task.activity.map((e) => e.content), [
      'Untrusted note',
      'A comment',
      'Next: open the PR',
    ]);
    expect(task.comments.map((e) => e.content), ['A comment']);
    expect(task.status, 'Done');
  });
  test(
    'write guard refuses assignment of others and emits real operation tags',
    () {
      final task = ProjectTask.fromEvents(root(), []);
      expect(
        () => projectTaskAssignmentTags(
          task: task,
          signer: stranger,
          assignee: member,
          assign: true,
        ),
        throwsArgumentError,
      );
      final tags = projectTaskAssignmentTags(
        task: task,
        signer: author,
        assignee: member,
        assign: true,
      );
      expect(tags, contains(equals(['t', 'assignment'])));
      expect(tags, contains(equals(['p', member])));
      expect(
        projectTaskTags(repoAddress: repo, title: ' Task '),
        contains(equals(['subject', 'Task'])),
      );
      expect(
        () => projectTaskTags(repoAddress: repo, title: ' '),
        throwsArgumentError,
      );
    },
  );
  test(
    'history pages include old assignment operations beyond newest comments',
    () async {
      var calls = 0;
      final old = operation('900', owner, member, time: 1);
      final result = await loadProjectTaskHistory([root().id], (filter) async {
        calls++;
        expect(filter.tags.keys, ['#e']);
        if (calls == 1) {
          return [for (var i = 0; i < 500; i++) event('$i', time: 1000 - i)];
        }
        expect(filter.until, 501);
        return [old];
      });
      expect(calls, 2);
      expect(result, contains(old));
    },
  );
  test(
    'saturated same-second history fails explicitly rather than losing assignees',
    () async {
      await expectLater(
        loadProjectTaskHistory(
          [root().id],
          (filter) async => [
            for (var i = 0; i < filter.limit; i++) event('$i'),
          ],
        ),
        throwsStateError,
      );
    },
  );

  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });
  ProviderContainer container(ProjectTaskTransport transport) =>
      ProviderContainer(
        overrides: [
          savedPrefsProvider.overrideWithValue(prefs),
          relayConfigProvider.overrideWith(Config.new),
          myPubkeyProvider.overrideWithValue(author),
          projectTaskTransportProvider.overrideWithValue(transport),
        ],
      );
  ProjectTaskTransport transport({
    Future<List<NostrEvent>> Function(NostrFilter)? query,
    Future<void> Function(NostrEvent)? publish,
  }) => ProjectTaskTransport(
    scan: query ?? (_) async => [],
    verify: (events) async => events,
    publish: publish ?? (_) async {},
    sign: (kind, content, tags, time) =>
        event('99', kind: kind, content: content, tags: tags, time: time),
  );
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 5));

  test(
    'same-community accounts have separate durable drafts and outboxes',
    () async {
      final c = ProviderContainer(
        overrides: [
          savedPrefsProvider.overrideWithValue(prefs),
          relayConfigProvider.overrideWith(Config.new),
          projectTaskTransportProvider.overrideWithValue(
            transport(
              publish: (_) async {
                throw StateError('offline');
              },
            ),
          ),
        ],
      );
      addTearDown(c.dispose);
      final config = c.read(relayConfigProvider.notifier);
      config.update(baseUrl: 'https://tasks.example', nsec: testNsec('1'));
      final firstKey = c.read(myPubkeyProvider);
      var store = c.read(projectTaskStoreProvider(repo).notifier);
      await settle();
      await store.saveDraft('Account one draft', 'Private');
      await expectLater(store.createTask(), throwsStateError);
      final pendingId = c
          .read(projectTaskStoreProvider(repo))
          .pending
          .single
          .id;
      config.update(baseUrl: 'https://tasks.example', nsec: testNsec('2'));
      expect(c.read(myPubkeyProvider), isNot(firstKey));
      expect(c.read(projectTaskStoreProvider(repo)).title, isEmpty);
      expect(c.read(projectTaskStoreProvider(repo)).pending, isEmpty);
      store = c.read(projectTaskStoreProvider(repo).notifier);
      await settle();
      await store.saveDraft('Account two draft', 'Other');
      config.update(baseUrl: 'https://tasks.example', nsec: testNsec('1'));
      expect(c.read(projectTaskStoreProvider(repo)).title, 'Account one draft');
      expect(
        c.read(projectTaskStoreProvider(repo)).pending.single.id,
        pendingId,
      );
    },
  );
  test('unreadable saved outbox is preserved and blocks publication', () async {
    final key = 'project-tasks-v1:https://tasks.example:$author:$repo';
    await prefs.setString(key, '{broken pending data');
    var published = false;
    final c = container(
      transport(
        publish: (_) async {
          published = true;
        },
      ),
    );
    addTearDown(c.dispose);
    final store = c.read(projectTaskStoreProvider(repo).notifier);
    await settle();
    await store.saveDraft('New draft', '');
    await expectLater(store.createTask(), throwsStateError);
    expect(published, isFalse);
    expect(prefs.getString(key), '{broken pending data');
    expect(c.read(projectTaskStoreProvider(repo)).error, contains('preserved'));
  });
  test(
    'failed create survives restart, retry publishes identical ID and clears draft only after ACK',
    () async {
      final published = <NostrEvent>[];
      final first = container(
        transport(
          publish: (e) async {
            published.add(e);
            throw StateError('offline');
          },
        ),
      );
      final store = first.read(projectTaskStoreProvider(repo).notifier);
      await settle();
      await store.saveDraft('Saved title', 'Saved body');
      await expectLater(
        store.createTask(channelId: 'channel'),
        throwsStateError,
      );
      expect(
        first.read(projectTaskStoreProvider(repo)).hasPendingCreate,
        isTrue,
      );
      expect(first.read(projectTaskStoreProvider(repo)).title, 'Saved title');
      first.dispose();
      final second = container(
        transport(
          publish: (e) async {
            published.add(e);
          },
        ),
      );
      addTearDown(second.dispose);
      final resumed = second.read(projectTaskStoreProvider(repo).notifier);
      await settle();
      expect(second.read(projectTaskStoreProvider(repo)).body, 'Saved body');
      await resumed.retryPending();
      expect(published.map((e) => e.id).toSet(), hasLength(1));
      expect(published.last.tags, contains(equals(['h', 'channel'])));
      expect(second.read(projectTaskStoreProvider(repo)).pending, isEmpty);
      expect(second.read(projectTaskStoreProvider(repo)).title, isEmpty);
      expect(
        second.read(projectTaskStoreProvider(repo)).tasks.single.title,
        'Saved title',
      );
    },
  );
  test(
    'cached tasks stay readable when refresh fails; drafts stay community-scoped',
    () async {
      var fail = false;
      final c = container(
        transport(
          query: (filter) async {
            if (fail) throw StateError('offline');
            return filter.kinds.contains(1621) ? [root()] : [];
          },
        ),
      );
      addTearDown(c.dispose);
      final store = c.read(projectTaskStoreProvider(repo).notifier);
      await settle();
      await store.saveDraft('Private draft', 'Private body');
      fail = true;
      await store.refresh();
      expect(
        c.read(projectTaskStoreProvider(repo)).tasks.single.title,
        'Ship mobile',
      );
      expect(c.read(projectTaskStoreProvider(repo)).error, contains('offline'));
      c
          .read(relayConfigProvider.notifier)
          .update(baseUrl: 'https://other.example');
      expect(c.read(projectTaskStoreProvider(repo)).title, isEmpty);
      expect(c.read(projectTaskStoreProvider(repo)).tasks, isEmpty);
    },
  );
  test(
    'late history cannot erase a confirmed local task or populate another community',
    () async {
      final waiting = Completer<List<NostrEvent>>();
      final c = container(transport(query: (_) => waiting.future));
      addTearDown(c.dispose);
      final store = c.read(projectTaskStoreProvider(repo).notifier);
      await settle();
      await store.saveDraft('New task', '');
      await store.createTask();
      waiting.complete([]);
      await settle();
      expect(
        c.read(projectTaskStoreProvider(repo)).tasks.single.title,
        'New task',
      );
    },
  );
}
