import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:hooks_riverpod/misc.dart';
import 'package:buzz/features/channels/channel.dart';
import 'package:buzz/features/channels/channel_typing_provider.dart';
import 'package:buzz/features/forum/forum_activity.dart';
import 'package:buzz/features/forum/forum_models.dart';
import 'package:buzz/features/forum/forum_post_card.dart';
import 'package:buzz/features/forum/forum_posts_view.dart';
import 'package:buzz/features/forum/forum_provider.dart';
import 'package:buzz/features/forum/forum_thread_page.dart';
import 'package:buzz/features/forum/forum_thread_history.dart';
import 'package:buzz/features/profile/profile_provider.dart';
import 'package:buzz/shared/mentions/agent_identity_provider.dart';
import 'package:buzz/shared/profile/user_cache_provider.dart';
import 'package:buzz/shared/profile/user_profile.dart';
import 'package:buzz/shared/read_state/read_state_format.dart';
import 'package:buzz/shared/read_state/read_state_provider.dart';
import 'package:buzz/shared/relay/relay.dart';
import 'package:buzz/shared/theme/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _channelId = 'forum-channel';
const _self = 'self';
const _agent = 'scout';
const _human = 'bob';

final _forumChannel = Channel(
  id: _channelId,
  name: 'design-forum',
  channelType: 'forum',
  visibility: 'open',
  description: '',
  createdBy: 'abc123',
  createdAt: DateTime(2025),
  memberCount: 5,
  isMember: true,
);

const _users = {
  _agent: UserProfile(pubkey: _agent, displayName: 'Scout'),
  _human: UserProfile(pubkey: _human, displayName: 'Bob'),
};

ForumPost _post({
  String eventId = 'post1',
  int createdAt = 1000,
  ForumThreadSummary? summary,
}) => ForumPost(
  eventId: eventId,
  pubkey: 'alice',
  content: 'Hello forum',
  kind: 45001,
  createdAt: createdAt,
  channelId: _channelId,
  tags: const [
    ['h', _channelId],
  ],
  threadSummary: summary,
);

ForumThreadSummary _summary({int replyCount = 2, int? lastReplyAt = 2000}) =>
    ForumThreadSummary(
      replyCount: replyCount,
      descendantCount: replyCount,
      lastReplyAt: lastReplyAt,
      participants: const [],
    );

ThreadReply _reply(String id, int createdAt, {String parent = 'post1'}) =>
    ThreadReply(
      eventId: id,
      pubkey: _human,
      content: 'reply $id',
      kind: 45003,
      createdAt: createdAt,
      channelId: _channelId,
      tags: const [],
      parentEventId: parent,
      rootEventId: 'post1',
      depth: 0,
    );

TypingEntry _typing(String pubkey, String? threadHeadId) => TypingEntry(
  pubkey: pubkey,
  threadHeadId: threadHeadId,
  expiresAtMs: DateTime.now().millisecondsSinceEpoch + 60000,
);

List<Override> _commonOverrides({
  required _RecordingReadStateNotifier readState,
  List<TypingEntry> typing = const [],
}) => [
  userCacheProvider.overrideWith(() => _FakeUserCacheNotifier(_users)),
  knownAgentPubkeysProvider.overrideWithValue(const {_agent}),
  channelBotPubkeysProvider(
    _channelId,
  ).overrideWith((ref) async => const <String>{}),
  profileProvider.overrideWith(() => _FakeProfileNotifier()),
  readStateProvider.overrideWith(() => readState),
  channelTypingProvider(
    _channelId,
  ).overrideWith(() => _FakeTypingNotifier(typing)),
  relayClientProvider.overrideWithValue(
    RelayClient(baseUrl: 'http://localhost:3000'),
  ),
];

/// Animations disabled so the working-row shimmer does not keep frames busy.
Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.light(),
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: true),
      child: child,
    ),
  ),
);

Widget _card({
  required ForumPost post,
  required _RecordingReadStateNotifier readState,
  int? channelReadSnapshot,
  List<TypingEntry> typing = const [],
}) => ProviderScope(
  overrides: _commonOverrides(readState: readState, typing: typing),
  child: _app(
    Scaffold(
      body: ForumPostCard(
        post: post,
        currentPubkey: _self,
        onTap: () {},
        channelReadSnapshot: channelReadSnapshot,
      ),
    ),
  ),
);

final _dot = find.byKey(const ValueKey('forum-post-new-replies-dot'));
final _cardWorking = find.byKey(const ValueKey('forum-post-working-post1'));

void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  group('forumPostHasNewReplies', () {
    // (summary, threadReadAt, channelReadSnapshot) -> expected
    final cases = <(String, ForumThreadSummary?, int?, int?, bool)>[
      ('no summary', null, 0, 0, false),
      ('no replies', _summary(replyCount: 0), 0, 0, false),
      ('no last reply time', _summary(lastReplyAt: null), 0, 0, false),
      ('both markers null', _summary(), null, null, false),
      ('thread marker older', _summary(), 1999, null, true),
      ('thread marker equal', _summary(), 2000, null, false),
      ('thread marker newer', _summary(), 2001, null, false),
      ('snapshot older, no thread marker', _summary(), null, 1999, true),
      ('snapshot equal, no thread marker', _summary(), null, 2000, false),
      ('thread marker wins over older snapshot', _summary(), 2000, 1, false),
      ('thread marker wins over newer snapshot', _summary(), 1, 3000, true),
    ];
    for (final (name, summary, threadReadAt, snapshot, expected) in cases) {
      test(name, () {
        expect(
          forumPostHasNewReplies(
            summary: summary,
            threadReadAt: threadReadAt,
            channelReadSnapshot: snapshot,
          ),
          expected,
        );
      });
    }
  });

  test('forumTypingPubkeys scopes by thread, drops self, sorts', () {
    final entries = [
      _typing('Zed', 'post1'),
      _typing('SELF', 'post1'),
      _typing('amy', 'post1'),
      _typing('bob', 'post2'),
      _typing('cat', null),
    ];
    expect(
      forumTypingPubkeys(entries, threadHeadId: 'post1', currentPubkey: _self),
      ['amy', 'zed'],
    );
    expect(
      forumTypingPubkeys(entries, threadHeadId: null, currentPubkey: _self),
      ['cat'],
    );
    expect(
      forumTypingPubkeys(entries, threadHeadId: 'post1', currentPubkey: null),
      ['amy', 'self', 'zed'],
    );
  });

  group('forumThreadReadAt', () {
    final post = _post();
    test('no replies reads at the post time', () {
      expect(forumThreadReadAt(post: post, replies: const []), 1000);
    });
    test('reads at the newest loaded reply', () {
      expect(
        forumThreadReadAt(
          post: post,
          replies: [_reply('a', 1500), _reply('b', 1200)],
        ),
        1500,
      );
    });
    test('adopts the relay last-reply time when every reply is loaded', () {
      expect(
        forumThreadReadAt(
          post: post,
          replies: [_reply('a', 1500), _reply('b', 1200)],
          listedSummary: _summary(replyCount: 2, lastReplyAt: 1501),
        ),
        1501,
      );
    });
    test('ignores a summary counting replies not loaded yet', () {
      expect(
        forumThreadReadAt(
          post: post,
          replies: [
            _reply('a', 1500),
            _reply('n', 1400, parent: 'a'),
          ],
          listedSummary: _summary(replyCount: 2, lastReplyAt: 1900),
        ),
        1500,
      );
    });
    test('adopts the fetched post summary when every reply is loaded', () {
      expect(
        forumThreadReadAt(
          post: _post(summary: _summary(replyCount: 1, lastReplyAt: 1501)),
          replies: [_reply('a', 1500)],
        ),
        1501,
      );
    });
    test('ignores a fetched post summary counting unloaded replies', () {
      expect(
        forumThreadReadAt(
          post: _post(summary: _summary(replyCount: 2, lastReplyAt: 1900)),
          replies: [_reply('a', 1500)],
        ),
        1500,
      );
    });
  });

  group('forumThreadProvider post summary', () {
    final root = _event('post1', EventKind.forumPost, 1000);
    final reply = _event(
      'a',
      EventKind.forumComment,
      1500,
      tags: const [
        ['h', _channelId],
        ['e', 'post1', '', 'reply'],
      ],
    );

    test('attaches the summary from the window anchored at the post', () async {
      final session = _FakeRelaySession(
        root: root,
        replies: [reply],
        window: [
          _event('newer-same-second', EventKind.forumPost, 1000),
          root,
          _summaryEvent('newer-same-second', lastReplyAt: 3000),
          _summaryEvent('post1', lastReplyAt: 1501),
        ],
      );

      final thread = await _readThread(session);

      expect(thread.post.threadSummary?.lastReplyAt, 1501);
      expect(thread.replies.single.eventId, 'a');
      final filter = session.queried.single.toJson();
      expect(filter['kinds'], [EventKind.forumPost]);
      expect(filter['#h'], [_channelId]);
      expect(filter['limit'], 10);
      expect(filter['until'], 1000);
      expect(filter['top_level'], isTrue);
      expect(filter['include_summaries'], isTrue);
      expect(filter['before_id'], '0' * 64);
    });

    test(
      'opens without a summary when the post is not in the window',
      () async {
        final session = _FakeRelaySession(
          root: root,
          window: [
            _event('other', EventKind.forumPost, 1000),
            _summaryEvent('other', lastReplyAt: 3000),
          ],
        );

        final thread = await _readThread(session);

        expect(thread.post.eventId, 'post1');
        expect(thread.post.threadSummary, isNull);
      },
    );

    test('opens without a summary when the query fails', () async {
      final session = _FakeRelaySession(
        root: root,
        replies: [reply],
        failQuery: true,
      );

      final thread = await _readThread(session);

      expect(thread.post.threadSummary, isNull);
      expect(thread.replies, hasLength(1));
    });

    test('skips the summary query for a non-forum root', () async {
      final session = _FakeRelaySession(
        root: _event('post1', EventKind.streamMessage, 1000),
      );

      final thread = await _readThread(session);

      expect(thread.post.threadSummary, isNull);
      expect(session.queried, isEmpty);
    });
  });

  group('ForumPostCard new replies', () {
    testWidgets('flags replies newer than the thread marker', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _card(
          post: _post(summary: _summary(lastReplyAt: 2000)),
          readState: _RecordingReadStateNotifier({
            threadContextKey('post1'): 1999,
          }),
        ),
      );
      await tester.pump();

      expect(_dot, findsOneWidget);
      expect(
        tester.widget<Text>(find.text('2 replies')).style?.fontWeight,
        FontWeight.w700,
      );
      expect(
        find.bySemanticsLabel(RegExp(r'^2 replies, last .*, new replies$')),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('thread marker at the last reply clears the flag even with '
        'an older channel snapshot', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _card(
          post: _post(summary: _summary(lastReplyAt: 2000)),
          readState: _RecordingReadStateNotifier({
            threadContextKey('post1'): 2000,
          }),
          channelReadSnapshot: 100,
        ),
      );
      await tester.pump();

      expect(_dot, findsNothing);
      expect(find.text('2 replies'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('new replies')), findsNothing);
      handle.dispose();
    });

    testWidgets('falls back to the channel snapshot without a thread marker', (
      tester,
    ) async {
      await tester.pumpWidget(
        _card(
          post: _post(summary: _summary(lastReplyAt: 2000)),
          readState: _RecordingReadStateNotifier({}),
          channelReadSnapshot: 1500,
        ),
      );
      await tester.pump();
      expect(_dot, findsOneWidget);
    });

    testWidgets('no marker without a thread marker or snapshot', (
      tester,
    ) async {
      await tester.pumpWidget(
        _card(
          post: _post(summary: _summary(lastReplyAt: 2000)),
          readState: _RecordingReadStateNotifier({}),
        ),
      );
      await tester.pump();
      expect(_dot, findsNothing);
    });

    testWidgets('clears when the thread marker advances', (tester) async {
      final readState = _RecordingReadStateNotifier({});
      await tester.pumpWidget(
        _card(
          post: _post(summary: _summary(lastReplyAt: 2000)),
          readState: readState,
          channelReadSnapshot: 1500,
        ),
      );
      await tester.pump();
      expect(_dot, findsOneWidget);

      readState.markContextRead(threadContextKey('post1'), 2000);
      await tester.pump();
      expect(_dot, findsNothing);
    });
  });

  group('ForumPostCard working row', () {
    testWidgets('shows an agent working on this post', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _card(
          post: _post(),
          readState: _RecordingReadStateNotifier({}),
          typing: [_typing(_agent, 'post1')],
        ),
      );
      await tester.pump();

      expect(_cardWorking, findsOneWidget);
      expect(find.text('Scout is working…'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Scout is working on a reply'),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('says typing for a person', (tester) async {
      await tester.pumpWidget(
        _card(
          post: _post(),
          readState: _RecordingReadStateNotifier({}),
          typing: [_typing(_human, 'post1')],
        ),
      );
      await tester.pump();
      expect(find.text('Bob is typing…'), findsOneWidget);
    });

    for (final (name, entry) in [
      ('another post', _typing(_agent, 'post2')),
      ('channel level', _typing(_agent, null)),
      ('self', _typing(_self, 'post1')),
    ]) {
      testWidgets('hidden for $name', (tester) async {
        await tester.pumpWidget(
          _card(
            post: _post(),
            readState: _RecordingReadStateNotifier({}),
            typing: [entry],
          ),
        );
        await tester.pump();
        expect(_cardWorking, findsNothing);
      });
    }
  });

  group('ForumPostsView', () {
    Widget view({
      required _RecordingReadStateNotifier readState,
      required List<ForumPost> posts,
      List<TypingEntry> typing = const [],
    }) => ProviderScope(
      overrides: [
        ..._commonOverrides(readState: readState, typing: typing),
        forumPostsProvider(_channelId).overrideWith(
          (ref) async => ForumPostsResponse(posts: posts, nextCursor: null),
        ),
      ],
      child: _app(
        Scaffold(
          body: ForumPostsView(channel: _forumChannel, currentPubkey: _self),
        ),
      ),
    );

    testWidgets('keeps the flag after the channel is marked read on open', (
      tester,
    ) async {
      final readState = _RecordingReadStateNotifier({_channelId: 1500});
      await tester.pumpWidget(
        view(
          readState: readState,
          posts: [_post(summary: _summary(lastReplyAt: 2000))],
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(_dot, findsOneWidget);

      // The channel page marks the forum read at its latest activity.
      readState.markContextRead(_channelId, 2500);
      await tester.pump();
      expect(_dot, findsOneWidget);
    });

    testWidgets('shows a channel-level working line for untagged entries', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        view(
          readState: _RecordingReadStateNotifier({}),
          posts: [_post()],
          typing: [_typing(_agent, null), _typing(_self, null)],
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        find.byKey(const ValueKey('forum-channel-working')),
        findsOneWidget,
      );
      expect(find.text('Scout is working…'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Scout is working in this forum'),
        findsOneWidget,
      );
      expect(_cardWorking, findsNothing);
      handle.dispose();
    });

    testWidgets('no channel-level line for post-scoped entries', (
      tester,
    ) async {
      await tester.pumpWidget(
        view(
          readState: _RecordingReadStateNotifier({}),
          posts: [_post()],
          typing: [_typing(_agent, 'post1')],
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const ValueKey('forum-channel-working')), findsNothing);
      expect(_cardWorking, findsOneWidget);
    });

    testWidgets('shows the channel-level line in an empty forum', (
      tester,
    ) async {
      await tester.pumpWidget(
        view(
          readState: _RecordingReadStateNotifier({}),
          posts: const [],
          typing: [_typing(_agent, null)],
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('No posts yet'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('forum-channel-working')),
        findsOneWidget,
      );
      expect(find.text('Scout is working…'), findsOneWidget);
    });
  });

  group('ForumThreadPage', () {
    Widget page({
      required _RecordingReadStateNotifier readState,
      required Future<ForumThreadResponse> Function() loadThread,
      List<TypingEntry> typing = const [],
    }) {
      final overrides = [
        ..._commonOverrides(readState: readState, typing: typing),
        savedPrefsProvider.overrideWithValue(prefs),
        forumThreadProvider((
          channelId: _channelId,
          eventId: 'post1',
        )).overrideWith((ref) => loadThread()),
      ];
      return ProviderScope(
        overrides: overrides,
        child: _app(
          const ForumThreadPage(
            channelId: _channelId,
            postEventId: 'post1',
            currentPubkey: _self,
            isMember: true,
            isArchived: false,
          ),
        ),
      );
    }

    ForumThreadResponse thread(List<ThreadReply> replies) =>
        ForumThreadResponse(
          post: _post(),
          replies: replies,
          totalReplies: replies.length,
        );

    testWidgets('reopening thread shows latest reply within one second', (
      tester,
    ) async {
      var replies = [_reply('old', 1500)];
      final container = ProviderContainer(
        overrides: [
          ..._commonOverrides(readState: _RecordingReadStateNotifier({})),
          savedPrefsProvider.overrideWithValue(prefs),
          forumThreadProvider((
            channelId: _channelId,
            eventId: 'post1',
          )).overrideWith((ref) async {
            ref.keepAlive();
            return thread(List.of(replies));
          }),
        ],
      );
      Widget mount(bool open) => UncontrolledProviderScope(
        container: container,
        child: _app(
          open
              ? const ForumThreadPage(
                  channelId: _channelId,
                  postEventId: 'post1',
                  currentPubkey: _self,
                  isMember: true,
                  isArchived: false,
                )
              : const SizedBox.shrink(),
        ),
      );
      await tester.pumpWidget(mount(true));
      await tester.pumpAndSettle();
      expect(find.text('reply old'), findsOneWidget);
      await tester.pumpWidget(mount(false));
      await tester.pumpAndSettle();
      replies = [...replies, _reply('latest', 1800)];
      await tester.pumpWidget(mount(true));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      final freshWithinOneSecond = find
          .text('reply latest')
          .evaluate()
          .isNotEmpty;
      await tester.pump(const Duration(seconds: 9));
      await tester.pumpAndSettle();
      final freshAtTenSeconds = find.text('reply latest').evaluate().isNotEmpty;
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      expect(freshAtTenSeconds, isTrue);
      expect(
        freshWithinOneSecond,
        isTrue,
        reason:
            'An immediately available new reply should appear promptly when reopening a cached thread',
      );
    });

    testWidgets('hides cached thread after a confirmed missing root', (
      tester,
    ) async {
      var unavailable = false;
      await tester.pumpWidget(
        page(
          readState: _RecordingReadStateNotifier({}),
          loadThread: () async {
            if (unavailable) throw ForumThreadUnavailable();
            return thread([_reply('old', 1500)]);
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('reply old'), findsOneWidget);
      unavailable = true;
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      expect(find.text('reply old'), findsNothing);
      expect(find.text('Failed to load thread'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });

    testWidgets('shows thread data before summary metadata arrives', (
      tester,
    ) async {
      final summary = Completer<List<NostrEvent>>();
      final session = _DelayedSummarySession(
        root: _event('post1', 45001, 1000, content: 'root'),
        summary: summary,
      );
      final container = ProviderContainer(
        overrides: [relaySessionProvider.overrideWith(() => session)],
      );
      addTearDown(container.dispose);
      final provider = forumThreadProvider((
        channelId: _channelId,
        eventId: 'post1',
      ));
      final summarySubscription = container.listen(
        forumThreadSummaryProvider((channelId: _channelId, eventId: 'post1')),
        (_, _) {},
      );
      addTearDown(summarySubscription.close);
      final subscription = container.listen(provider, (_, _) {});
      addTearDown(subscription.close);
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      final availableWhileSummaryPending = container.read(provider).hasValue;

      summary.complete([]);
      await tester.pump();
      await tester.pump();
      expect(container.read(provider).requireValue.replies, hasLength(1));
      expect(
        availableWhileSummaryPending,
        isTrue,
        reason:
            'Received replies should not wait behind ancillary summary metadata',
      );
    });

    testWidgets(
      'resume refreshes immediately while cached replies remain visible',
      (tester) async {
        var replies = [_reply('old', 1500)];
        Completer<ForumThreadResponse>? pending;
        await tester.pumpWidget(
          page(
            readState: _RecordingReadStateNotifier({}),
            loadThread: () => pending?.future ?? Future.value(thread(replies)),
          ),
        );
        await tester.pumpAndSettle();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        replies = [...replies, _reply('latest', 1800)];
        pending = Completer<ForumThreadResponse>();
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        await tester.pump();
        expect(find.text('reply old'), findsOneWidget);
        expect(find.text('reply latest'), findsNothing);
        pending.complete(thread(replies));
        await tester.pumpAndSettle();
        expect(find.text('reply latest'), findsOneWidget);
      },
    );

    testWidgets('marks the thread read at the post time without replies', (
      tester,
    ) async {
      final readState = _RecordingReadStateNotifier({});
      await tester.pumpWidget(
        page(readState: readState, loadThread: () async => thread(const [])),
      );
      await tester.pumpAndSettle();

      expect(readState.marked[threadContextKey('post1')], [1000]);
    });

    testWidgets('marks the newest reply, then newer replies as they load', (
      tester,
    ) async {
      final readState = _RecordingReadStateNotifier({});
      var replies = [_reply('a', 1500), _reply('b', 1200)];
      await tester.pumpWidget(
        page(readState: readState, loadThread: () async => thread(replies)),
      );
      await tester.pumpAndSettle();
      expect(readState.marked[threadContextKey('post1')], [1500]);

      replies = [...replies, _reply('c', 1800)];
      // The page's periodic refresh reloads the thread.
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      expect(readState.marked[threadContextKey('post1')], [1500, 1800]);
      expect(find.text('reply c'), findsOneWidget);
    });

    testWidgets('adopts the listed relay last-reply time when covered', (
      tester,
    ) async {
      final readState = _RecordingReadStateNotifier({});
      final container = ProviderContainer(
        overrides: [
          ..._commonOverrides(readState: readState),
          savedPrefsProvider.overrideWithValue(prefs),
          forumPostsProvider(_channelId).overrideWith(
            (ref) async => ForumPostsResponse(
              posts: [
                _post(summary: _summary(replyCount: 1, lastReplyAt: 1501)),
              ],
              nextCursor: null,
            ),
          ),
          forumThreadProvider((
            channelId: _channelId,
            eventId: 'post1',
          )).overrideWith((ref) async => thread([_reply('a', 1500)])),
        ],
      );
      // The post list underneath keeps the listing alive.
      final listing = container.listen(
        forumPostsProvider(_channelId),
        (_, _) {},
      );
      await container.read(forumPostsProvider(_channelId).future);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: _app(
            const ForumThreadPage(
              channelId: _channelId,
              postEventId: 'post1',
              currentPubkey: _self,
              isMember: true,
              isArchived: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(readState.marked[threadContextKey('post1')], [1501]);

      // The container outlives the tree; release its timers before teardown.
      await tester.pumpWidget(const SizedBox());
      listing.close();
      container.dispose();
      await tester.pump();
    });

    testWidgets('direct entry adopts the fetched summary so the card clears', (
      tester,
    ) async {
      // Opened from search: no post list, so no listed summary. The relay
      // stored the reply signed at 1500 at 1501.
      final readState = _RecordingReadStateNotifier({});
      final container = ProviderContainer(
        overrides: [
          ..._commonOverrides(readState: readState),
          savedPrefsProvider.overrideWithValue(prefs),
          forumThreadProvider((
            channelId: _channelId,
            eventId: 'post1',
          )).overrideWith(
            (ref) async => ForumThreadResponse(
              post: _post(summary: _summary(replyCount: 1, lastReplyAt: 1501)),
              replies: [_reply('a', 1500)],
              totalReplies: 1,
            ),
          ),
        ],
      );
      expect(container.exists(forumPostsProvider(_channelId)), isFalse);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: _app(
            const ForumThreadPage(
              channelId: _channelId,
              postEventId: 'post1',
              currentPubkey: _self,
              isMember: true,
              isArchived: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(readState.marked[threadContextKey('post1')], [1501]);

      // Later, the post list shows the same summary.
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: _app(
            Scaffold(
              body: ForumPostCard(
                post: _post(
                  summary: _summary(replyCount: 1, lastReplyAt: 1501),
                ),
                currentPubkey: _self,
                onTap: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final dots = _dot.evaluate().length;

      await tester.pumpWidget(const SizedBox());
      container.dispose();
      await tester.pump();
      expect(dots, 0);
    });

    testWidgets('direct entry does not adopt a summary with unloaded replies', (
      tester,
    ) async {
      final readState = _RecordingReadStateNotifier({});
      await tester.pumpWidget(
        page(
          readState: readState,
          loadThread: () async => ForumThreadResponse(
            post: _post(summary: _summary(replyCount: 2, lastReplyAt: 1900)),
            replies: [_reply('a', 1500)],
            totalReplies: 1,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(readState.marked[threadContextKey('post1')], [1500]);
    });

    testWidgets('shows who is working on this post only', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        page(
          readState: _RecordingReadStateNotifier({}),
          loadThread: () async => thread(const []),
          typing: [
            _typing(_agent, 'post1'),
            _typing(_human, 'post2'),
            _typing(_self, 'post1'),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('forum-thread-working')),
        findsOneWidget,
      );
      expect(find.text('Scout is working…'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Scout is working on a reply'),
        findsOneWidget,
      );
      handle.dispose();
    });
  });
}

class _FakeRelaySession extends RelaySessionNotifier {
  final NostrEvent root;
  final List<NostrEvent> replies;
  final List<NostrEvent> window;
  final bool failQuery;
  final queried = <NostrFilter>[];

  _FakeRelaySession({
    required this.root,
    this.replies = const [],
    this.window = const [],
    this.failQuery = false,
  });

  @override
  SessionState build() => const SessionState(status: SessionStatus.connected);

  @override
  Future<List<NostrEvent>> fetchHistory(
    NostrFilter filter, {
    Duration timeout = const Duration(seconds: 8),
  }) async => filter.ids != null ? [root] : replies;

  @override
  Future<List<NostrEvent>> queryRelay(
    List<NostrFilter> filters, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final filter = filters.single;
    if (filter.ids != null) return [root];
    if (filter.kinds.contains(EventKind.forumComment)) return replies;
    if (filter.kinds.contains(EventKind.deletion)) return [];
    queried.addAll(filters);
    if (failQuery) throw StateError('relay down');
    return window;
  }
}

NostrEvent _event(
  String id,
  int kind,
  int createdAt, {
  List<List<String>> tags = const [
    ['h', _channelId],
  ],
  String content = '',
}) => NostrEvent(
  id: id,
  pubkey: 'alice',
  createdAt: createdAt,
  kind: kind,
  tags: tags,
  content: content,
  sig: '',
);

NostrEvent _summaryEvent(String postId, {required int lastReplyAt}) => _event(
  'summary-$postId',
  EventKind.channelThreadSummary,
  lastReplyAt,
  tags: [
    ['e', postId],
  ],
  content: jsonEncode({
    'reply_count': 1,
    'descendant_count': 1,
    'last_reply_at': lastReplyAt,
    'participants': const <String>[],
  }),
);

Future<ForumThreadResponse> _readThread(_FakeRelaySession session) async {
  final container = ProviderContainer(
    overrides: [relaySessionProvider.overrideWith(() => session)],
  );
  addTearDown(container.dispose);
  const args = (channelId: _channelId, eventId: 'post1');
  await container.read(forumThreadProvider(args).future);
  final summary = await container.read(forumThreadSummaryProvider(args).future);
  return ForumThreadResponse.fromEvents(
    root: session.root,
    replies: session.replies,
    postSummary: summary,
  );
}

class _RecordingReadStateNotifier extends ReadStateNotifier {
  final Map<String, int> _initial;
  final Map<String, List<int>> marked = {};

  _RecordingReadStateNotifier(this._initial);

  @override
  ReadStateState build() => ReadStateState(
    isReady: true,
    pubkey: _self,
    contexts: Map.unmodifiable(_initial),
    version: 1,
  );

  @override
  void markContextRead(
    String contextId,
    int unixTimestamp, {
    bool clearForcedMessages = false,
  }) {
    marked.putIfAbsent(contextId, () => []).add(unixTimestamp);
    state = state.copyWithContext(contextId, unixTimestamp);
  }
}

class _FakeTypingNotifier extends ChannelTypingNotifier {
  final List<TypingEntry> _entries;
  _FakeTypingNotifier(this._entries) : super(_channelId);

  @override
  List<TypingEntry> build() => _entries;
}

class _FakeUserCacheNotifier extends UserCacheNotifier {
  final Map<String, UserProfile> _users;
  _FakeUserCacheNotifier(this._users);

  @override
  Map<String, UserProfile> build() => _users;

  @override
  UserProfile? get(String pubkey) => _users[pubkey.toLowerCase()];

  @override
  Future<bool> preload(List<String> pubkeys) async => true;
}

class _FakeProfileNotifier extends ProfileNotifier {
  @override
  Future<UserProfile?> build() async =>
      const UserProfile(pubkey: _self, displayName: 'Self');
}

class _DelayedSummarySession extends _FakeRelaySession {
  final Completer<List<NostrEvent>> summary;
  _DelayedSummarySession({required super.root, required this.summary})
    : super(replies: [_event('reply1', 45003, 1500)]);
  @override
  Future<List<NostrEvent>> queryRelay(
    List<NostrFilter> filters, {
    Duration timeout = const Duration(seconds: 8),
  }) {
    if (filters.single.extensions['include_summaries'] == true) {
      return summary.future;
    }
    return super.queryRelay(filters, timeout: timeout);
  }
}
