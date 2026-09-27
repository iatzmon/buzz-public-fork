part of 'channel_detail_page_test.dart';

class _NotificationPending extends PendingDeepLinkNotifier {
  @override
  Future<DeepLinkCommunityPreparation> prepareCommunity(
    BuzzDeepLink link,
  ) async => DeepLinkCommunityPreparation.ready;
}

class _NotificationSession extends _TrackingRelaySession {
  final List<NostrEvent> events;
  final filters = <NostrFilter>[];
  _NotificationSession(this.events);

  @override
  Future<List<NostrEvent>> fetchHistory(
    NostrFilter filter, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    filters.add(filter);
    return events
        .where((event) => filter.ids?.contains(event.id) == true)
        .toList();
  }
}

void registerNotificationNavigationCases() {
  for (final cold in [false, true]) {
    for (final nested in [false, true]) {
      testWidgets('notification ${cold ? "cold" : "warm"} opens '
          '${nested ? "nested" : "direct"} reply without thread payload', (
        tester,
      ) async {
        PendingDeepLinkNotifier.debugUriStreamOverride = const Stream.empty();
        addTearDown(() {
          pendingPushNotificationLink.value = null;
          PendingDeepLinkNotifier.debugUriStreamOverride = null;
        });
        final root = _textMsg(
          id: 'root',
          pubkey: 'alice',
          content: 'Outer root',
          createdAt: 1000,
        );
        final parent = _textMsg(
          id: 'parent',
          pubkey: 'alice',
          content: 'Nested head',
          createdAt: 1100,
          extraTags: const [
            ['e', 'root', '', 'reply'],
          ],
        );
        final target = _textMsg(
          id: 'target',
          pubkey: 'alice',
          content: 'Notified reply',
          createdAt: 1200,
          extraTags: [
            ['e', 'root', '', 'root'],
            ['e', nested ? 'parent' : 'root', '', 'reply'],
          ],
        );
        const link = MessageDeepLink(
          communityId: 'community',
          channelId: _channelId,
          messageId: 'target',
        );
        pendingPushNotificationLink.value = cold ? link : null;
        final session = _NotificationSession([root, parent, target]);
        await tester.pumpWidget(
          _buildTestable(
            messages: cold ? [root, parent] : [root, parent, target],
            relaySessionNotifier: session,
            threadReplies: {
              'root': [parent, target],
            },
            home: ProviderScope(
              overrides: [
                pendingDeepLinkProvider.overrideWith(_NotificationPending.new),
              ],
              child: const AdaptiveWorkspace(
                child: DeepLinkDispatcher(child: Scaffold(body: Text('Home'))),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (!cold) {
          pendingPushNotificationLink.value = link;
          await tester.pumpAndSettle();
        }
        expect(tester.takeException(), isNull);
        final page = tester.widget<ThreadDetailPage>(
          find.byType(ThreadDetailPage),
        );
        expect(page.threadHead.id, nested ? 'parent' : 'root');
        expect(page.initialMessageId, 'target');
        final targetRow = find.byKey(const ValueKey('thread-message-target'));
        expect(targetRow.hitTestable(), findsOneWidget);
        if (cold) {
          expect(
            session.filters.any(
              (filter) =>
                  filter.ids?.contains('target') == true &&
                  filter.tags['#h']?.contains(_channelId) == true,
            ),
            isTrue,
          );
        }
        // Back returns to the workspace, rather than a leftover channel route.
        final context = tester.element(find.byType(ThreadDetailPage));
        Navigator.of(context).pop();
        await tester.pumpAndSettle();
        expect(find.text('Home'), findsOneWidget);
        expect(pendingPushNotificationLink.value, isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }

  testWidgets('notification resolves a forum reply to its post and message', (
    tester,
  ) async {
    final channel = Channel(
      id: _channelId,
      name: 'forum',
      channelType: 'forum',
      visibility: 'open',
      description: '',
      createdBy: 'alice',
      createdAt: DateTime(2025),
      memberCount: 2,
      isMember: true,
    );
    final root = NostrEvent(
      id: 'post',
      pubkey: 'alice',
      createdAt: 1000,
      kind: 45001,
      tags: const [
        ['h', _channelId],
      ],
      content: 'Forum post',
      sig: '',
    );
    final reply = NostrEvent(
      id: 'reply',
      pubkey: 'alice',
      createdAt: 1100,
      kind: 45003,
      tags: const [
        ['h', _channelId],
        ['e', 'post', '', 'reply'],
      ],
      content: 'Notified forum reply',
      sig: '',
    );
    final session = _NotificationSession([reply]);
    await tester.pumpWidget(
      _buildTestable(
        messages: const [],
        channel: channel,
        relaySessionNotifier: session,
        home: ProviderScope(
          overrides: [
            forumThreadProvider((
              channelId: _channelId,
              eventId: 'post',
            )).overrideWith(
              (ref) async =>
                  ForumThreadResponse.fromEvents(root: root, replies: [reply]),
            ),
          ],
          child: NotificationDestination(
            channel: channel,
            link: const MessageDeepLink(
              communityId: 'community',
              channelId: _channelId,
              messageId: 'reply',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final page = tester.widget<ForumThreadPage>(find.byType(ForumThreadPage));
    expect(page.postEventId, 'post');
    expect(page.initialMessageId, 'reply');
    expect(
      find.byKey(const ValueKey('forum-message-reply')).hitTestable(),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'unavailable notification reports failure and Retry resolves it',
    (tester) async {
      final events = <NostrEvent>[];
      final session = _NotificationSession(events);
      await tester.pumpWidget(
        _buildTestable(
          messages: const [],
          relaySessionNotifier: session,
          disableRetries: true,
          home: NotificationDestination(
            channel: _testChannel,
            link: const MessageDeepLink(
              communityId: 'community',
              channelId: _channelId,
              messageId: 'target',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Could not load this message. It may be unavailable.'),
        findsOneWidget,
      );
      events.add(
        _textMsg(
          id: 'target',
          pubkey: 'alice',
          content: 'Available now',
          createdAt: 1200,
        ),
      );
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.byType(ThreadDetailPage), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
