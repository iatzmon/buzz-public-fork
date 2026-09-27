import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:buzz/features/channels/channel.dart';
import 'package:buzz/features/channels/channel_management_provider.dart';
import 'package:buzz/features/forum/forum_models.dart';
import 'package:buzz/features/forum/forum_post_card.dart';
import 'package:buzz/features/forum/forum_posts_view.dart';
import 'package:buzz/features/forum/forum_provider.dart';
import 'package:buzz/features/forum/forum_thread_page.dart';
import 'package:buzz/features/profile/profile_provider.dart';
import 'package:buzz/shared/community/community_membership_provider.dart';
import 'package:buzz/shared/mentions/agent_identity_provider.dart';
import 'package:buzz/shared/profile/user_cache_provider.dart';
import 'package:buzz/shared/profile/user_profile.dart';
import 'package:buzz/shared/relay/relay.dart';
import 'package:buzz/shared/theme/theme.dart';
import 'package:buzz/shared/widgets/avatar_image.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/recording_signed_event_relay.dart';

const _channelId = 'forum-channel';

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

ForumPost _makePost({
  String eventId = 'post1',
  String pubkey = 'alice',
  String content = 'Hello forum',
  int createdAt = 1000,
  List<List<String>> tags = const [
    ['h', 'forum-channel'],
  ],
  ForumThreadSummary? threadSummary,
}) => ForumPost(
  eventId: eventId,
  pubkey: pubkey,
  content: content,
  kind: 45001,
  createdAt: createdAt,
  channelId: _channelId,
  tags: tags,
  threadSummary: threadSummary,
);

const _aliceProfile = UserProfile(pubkey: 'alice', displayName: 'Alice');

void _setSurfaceSize(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
}

Widget _buildPostCard({
  required ForumPost post,
  String? currentPubkey = 'self',
  Map<String, UserProfile> users = const {},
  VoidCallback? onTap,
  void Function(String eventId, {required bool asModerator})? onDelete,
  TextScaler textScaler = TextScaler.noScaling,
  Set<String> knownAgentPubkeys = const {},
  CommunityMemberRole? communityRole,
}) {
  return ProviderScope(
    overrides: [
      userCacheProvider.overrideWith(() => _FakeUserCacheNotifier(users)),
      knownAgentPubkeysProvider.overrideWithValue(knownAgentPubkeys),
      currentCommunityRoleProvider.overrideWithValue(AsyncData(communityRole)),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: textScaler),
          child: Scaffold(
            body: ForumPostCard(
              post: post,
              currentPubkey: currentPubkey,
              onTap: onTap ?? () {},
              onDelete: onDelete,
            ),
          ),
        ),
      ),
    ),
  );
}

Widget _buildPostsView({
  ForumPostsResponse? postsResponse,
  ForumPostsResponse Function()? loadPosts,
  Channel? channel,
  Map<String, UserProfile> users = const {},
  CommunityMemberRole? communityRole,
  RecordingSignedEventRelay? signedEventRelay,
  List<ChannelMember> channelMembers = const [],
}) {
  final ch = channel ?? _forumChannel;
  return ProviderScope(
    overrides: [
      channelMembersProvider(ch.id).overrideWith((ref) async => channelMembers),
      userCacheProvider.overrideWith(() => _FakeUserCacheNotifier(users)),
      profileProvider.overrideWith(() => _FakeProfileNotifier()),
      forumPostsProvider(
        ch.id,
      ).overrideWith((ref) async => loadPosts?.call() ?? postsResponse!),
      currentCommunityRoleProvider.overrideWithValue(AsyncData(communityRole)),
      if (signedEventRelay != null)
        channelActionsProvider.overrideWith(
          recordingChannelActions(signedEventRelay),
        ),
      relayClientProvider.overrideWithValue(
        RelayClient(baseUrl: 'http://localhost:3000'),
      ),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: ForumPostsView(channel: ch, currentPubkey: 'self'),
      ),
    ),
  );
}

/// Shared mock prefs for the compose bar's draft store. Initialized in
/// [main].
late SharedPreferences _testPrefs;

Widget _buildThreadPage({
  required ForumThreadResponse threadResponse,
  Future<ForumThreadResponse> Function()? loadThread,
  String postEventId = 'post1',
  String? currentPubkey = 'self',
  bool isMember = true,
  bool isArchived = false,
  Map<String, UserProfile> users = const {},
  Set<String> knownAgentPubkeys = const {},
  Set<String> channelBotPubkeys = const {},
  TextScaler textScaler = TextScaler.noScaling,
  CommunityMemberRole? communityRole,
  RecordingSignedEventRelay? signedEventRelay,
}) {
  return ProviderScope(
    // Failed loads stay failed until the user retries.
    retry: (_, _) => null,
    overrides: [
      currentCommunityRoleProvider.overrideWithValue(AsyncData(communityRole)),
      if (signedEventRelay != null)
        channelActionsProvider.overrideWith(
          recordingChannelActions(signedEventRelay),
        ),
      userCacheProvider.overrideWith(() => _FakeUserCacheNotifier(users)),
      knownAgentPubkeysProvider.overrideWithValue(knownAgentPubkeys),
      channelBotPubkeysProvider(
        _channelId,
      ).overrideWith((ref) async => channelBotPubkeys),
      profileProvider.overrideWith(() => _FakeProfileNotifier()),
      forumThreadProvider((
        channelId: _channelId,
        eventId: postEventId,
      )).overrideWith((ref) => loadThread?.call() ?? threadResponse),
      savedPrefsProvider.overrideWithValue(_testPrefs),
      relayClientProvider.overrideWithValue(
        RelayClient(baseUrl: 'http://localhost:3000'),
      ),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: textScaler),
          child: ForumThreadPage(
            channelId: _channelId,
            postEventId: postEventId,
            currentPubkey: currentPubkey,
            isMember: isMember,
            isArchived: isArchived,
          ),
        ),
      ),
    ),
  );
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _testPrefs = await SharedPreferences.getInstance();
  });

  test('cancels a captured forum delivery after the community changes', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(relayConfigProvider.notifier)
        .update(baseUrl: 'https://first.example');
    final delivery = ForumEventDelivery.capture(container);

    container
        .read(relayConfigProvider.notifier)
        .update(baseUrl: 'https://second.example');

    expect(
      delivery.createPost(channelId: _channelId, content: 'Queued post'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('active community changed'),
        ),
      ),
    );
  });

  group('ForumPostCard', () {
    testWidgets('renders author name and content', (tester) async {
      await tester.pumpWidget(
        _buildPostCard(
          post: _makePost(),
          users: const {'alice': _aliceProfile},
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Alice'), findsOneWidget);
      expect(find.text('Hello forum'), findsOneWidget);
    });

    testWidgets('shows compact npub when no profile', (tester) async {
      await tester.pumpWidget(
        _buildPostCard(
          post: _makePost(
            pubkey:
                'abcdef0000000000000000000000000000000000000000000000000000000000',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('npub140x\u2026etzk'), findsOneWidget);
    });

    testWidgets('uses directory classification for uncached author avatar', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildPostCard(
          post: _makePost(pubkey: 'directory-agent'),
          knownAgentPubkeys: const {'directory-agent'},
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester.widget<AvatarImage>(find.byType(AvatarImage)).isAgent,
        isTrue,
      );
    });

    testWidgets('keeps human author avatar circular', (tester) async {
      await tester.pumpWidget(
        _buildPostCard(
          post: _makePost(),
          users: const {'alice': _aliceProfile},
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester.widget<AvatarImage>(find.byType(AvatarImage)).isAgent,
        isFalse,
      );
    });

    testWidgets(
      'constrains an older timestamp at large accessible text sizes',
      (tester) async {
        _setSurfaceSize(tester, const Size(240, 600));
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        await tester.pumpWidget(
          _buildPostCard(
            post: _makePost(
              createdAt:
                  DateTime.utc(2025, 12, 31, 12).millisecondsSinceEpoch ~/ 1000,
            ),
            users: const {
              'alice': UserProfile(
                pubkey: 'alice',
                displayName: 'A very long display name',
              ),
            },
            textScaler: const TextScaler.linear(2),
          ),
        );
        await tester.pumpAndSettle();

        final timestamp = tester.widget<Text>(find.text('12/31/2025'));
        expect(timestamp.maxLines, 1);
        expect(timestamp.overflow, TextOverflow.ellipsis);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('gives the author unused timestamp width', (tester) async {
      _setSurfaceSize(tester, const Size(320, 600));
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final createdAt = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 120;
      const displayName = 'A moderately long forum author name';

      await tester.pumpWidget(
        _buildPostCard(
          post: _makePost(createdAt: createdAt),
          users: const {
            'alice': UserProfile(pubkey: 'alice', displayName: displayName),
          },
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.getSize(find.text(displayName)).width, greaterThan(150));
      expect(find.text('2m ago'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('truncates long content', (tester) async {
      final longContent = 'A' * 300;
      await tester.pumpWidget(
        _buildPostCard(post: _makePost(content: longContent)),
      );
      await tester.pumpAndSettle();

      // Should show 200 chars + "..."
      expect(find.textContaining('${'A' * 200}...'), findsOneWidget);
    });

    testWidgets('shows reply count with correct pluralization', (tester) async {
      await tester.pumpWidget(
        _buildPostCard(
          post: _makePost(
            threadSummary: const ForumThreadSummary(
              replyCount: 1,
              descendantCount: 1,
              participants: [],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('1 reply'), findsOneWidget);

      await tester.pumpWidget(
        _buildPostCard(
          post: _makePost(
            threadSummary: const ForumThreadSummary(
              replyCount: 5,
              descendantCount: 5,
              participants: [],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('5 replies'), findsOneWidget);
    });

    testWidgets('hides thread summary when reply count is 0', (tester) async {
      await tester.pumpWidget(
        _buildPostCard(
          post: _makePost(
            threadSummary: const ForumThreadSummary(
              replyCount: 0,
              descendantCount: 0,
              participants: [],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('0 replies'), findsNothing);
    });

    testWidgets('calls onTap when tapped', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        _buildPostCard(post: _makePost(), onTap: () => tapped = true),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(ForumPostCard));
      expect(tapped, isTrue);
    });

    testWidgets('keeps media previews non-interactive in the post list', (
      tester,
    ) async {
      var tapped = false;
      const imageUrl = 'https://example.com/media/card.png';

      await tester.pumpWidget(
        _buildPostCard(
          post: _makePost(
            content: '![image]($imageUrl)',
            tags: const [
              ['h', _channelId],
              [
                'imeta',
                'url https://example.com/media/card.png',
                'm image/png',
              ],
            ],
          ),
          onTap: () => tapped = true,
        ),
      );
      await tester.pumpAndSettle();

      final preview = find.byKey(
        const ValueKey(
          'message-media-image-preview:https://example.com/media/card.png',
        ),
      );

      await tester.tapAt(tester.getCenter(preview));
      await tester.pumpAndSettle();

      expect(tapped, isTrue);
      expect(
        find.byKey(const ValueKey('message-media-image-viewer')),
        findsNothing,
      );
    });

    testWidgets('long press opens action sheet with Copy text', (tester) async {
      await tester.pumpWidget(_buildPostCard(post: _makePost()));
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(ForumPostCard));
      await tester.pumpAndSettle();

      expect(find.text('Copy text'), findsOneWidget);
    });

    testWidgets('long press shows Delete only for own posts', (tester) async {
      // Own post — Delete should appear.
      await tester.pumpWidget(
        _buildPostCard(
          post: _makePost(pubkey: 'self'),
          currentPubkey: 'self',
          onDelete: (_, {required asModerator}) {},
        ),
      );
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(ForumPostCard));
      await tester.pumpAndSettle();
      expect(find.text('Delete post'), findsOneWidget);

      // Dismiss sheet.
      await tester.tapAt(Offset.zero);
      await tester.pumpAndSettle();

      // Other's post — Delete should NOT appear.
      await tester.pumpWidget(
        _buildPostCard(
          post: _makePost(pubkey: 'other'),
          currentPubkey: 'self',
          onDelete: (_, {required asModerator}) {},
        ),
      );
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(ForumPostCard));
      await tester.pumpAndSettle();
      expect(find.text('Delete post'), findsNothing);
    });

    testWidgets('delete confirmation dialog triggers onDelete', (tester) async {
      String? deletedId;
      bool? deletedAsModerator;
      await tester.pumpWidget(
        _buildPostCard(
          post: _makePost(pubkey: 'self', eventId: 'evt-to-delete'),
          currentPubkey: 'self',
          // An admin deleting their own post keeps the author path.
          communityRole: CommunityMemberRole.admin,
          onDelete: (id, {required asModerator}) {
            deletedId = id;
            deletedAsModerator = asModerator;
          },
        ),
      );
      await tester.pumpAndSettle();

      // Long press → action sheet.
      await tester.longPress(find.byType(ForumPostCard));
      await tester.pumpAndSettle();

      // Tap Delete post.
      await tester.tap(find.text('Delete post'));
      await tester.pumpAndSettle();

      // Confirmation dialog appears.
      expect(find.text('This cannot be undone.'), findsOneWidget);

      // Tap Delete button.
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(deletedId, 'evt-to-delete');
      expect(deletedAsModerator, isFalse);
    });

    testWidgets('community admin sees Delete post on another member\'s post', (
      tester,
    ) async {
      String? deletedId;
      bool? deletedAsModerator;
      await tester.pumpWidget(
        _buildPostCard(
          post: _makePost(pubkey: 'alice', eventId: 'alice-post'),
          currentPubkey: 'self',
          communityRole: CommunityMemberRole.admin,
          onDelete: (id, {required asModerator}) {
            deletedId = id;
            deletedAsModerator = asModerator;
          },
        ),
      );
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(ForumPostCard));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete post'));
      await tester.pumpAndSettle();
      expect(find.text('This cannot be undone.'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(deletedId, 'alice-post');
      expect(deletedAsModerator, isTrue);
    });

    for (final role in [CommunityMemberRole.member, null]) {
      testWidgets('$role does not see Delete post on another member\'s post', (
        tester,
      ) async {
        await tester.pumpWidget(
          _buildPostCard(
            post: _makePost(pubkey: 'alice'),
            currentPubkey: 'self',
            communityRole: role,
            onDelete: (_, {required asModerator}) {},
          ),
        );
        await tester.pumpAndSettle();

        await tester.longPress(find.byType(ForumPostCard));
        await tester.pumpAndSettle();
        expect(find.text('Copy text'), findsOneWidget);
        expect(find.text('Delete post'), findsNothing);
      });
    }
  });

  group('ForumPostsView', () {
    testWidgets('shows empty state for members', (tester) async {
      await tester.pumpWidget(
        _buildPostsView(postsResponse: const ForumPostsResponse(posts: [])),
      );
      await tester.pumpAndSettle();

      expect(find.text('No posts yet'), findsOneWidget);
      expect(
        find.text('Start a discussion by creating the first post.'),
        findsOneWidget,
      );
    });

    testWidgets('shows empty state for non-members', (tester) async {
      await tester.pumpWidget(
        _buildPostsView(
          postsResponse: const ForumPostsResponse(posts: []),
          channel: Channel(
            id: _channelId,
            name: 'design-forum',
            channelType: 'forum',
            visibility: 'open',
            description: '',
            createdBy: 'abc123',
            createdAt: DateTime(2025),
            memberCount: 5,
            isMember: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Join this forum to create posts.'), findsOneWidget);
    });

    testWidgets('shows FAB for members', (tester) async {
      await tester.pumpWidget(
        _buildPostsView(postsResponse: const ForumPostsResponse(posts: [])),
      );
      await tester.pumpAndSettle();

      expect(find.byType(FloatingActionButton), findsOneWidget);
      expect(find.byTooltip('New post'), findsOneWidget);
    });

    testWidgets('hides FAB for non-members', (tester) async {
      await tester.pumpWidget(
        _buildPostsView(
          postsResponse: const ForumPostsResponse(posts: []),
          channel: Channel(
            id: _channelId,
            name: 'design-forum',
            channelType: 'forum',
            visibility: 'open',
            description: '',
            createdBy: 'abc123',
            createdAt: DateTime(2025),
            memberCount: 5,
            isMember: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(FloatingActionButton), findsNothing);
    });

    testWidgets('renders post list', (tester) async {
      await tester.pumpWidget(
        _buildPostsView(
          postsResponse: ForumPostsResponse(
            posts: [
              _makePost(content: 'First post'),
              _makePost(eventId: 'post2', content: 'Second post'),
            ],
          ),
          users: const {'alice': _aliceProfile},
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('First post'), findsOneWidget);
      expect(find.text('Second post'), findsOneWidget);
    });

    Future<void> deleteFirstPost(WidgetTester tester) async {
      await tester.longPress(
        find.ancestor(
          of: find.text('Alice post'),
          matching: find.byType(ForumPostCard),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete post'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
    }

    testWidgets('community admin deletes another member\'s post with kind '
        '9005 and the refetched list drops it', (tester) async {
      var posts = [
        _makePost(eventId: 'alice-post', content: 'Alice post'),
        _makePost(eventId: 'other-post', content: 'Other post'),
      ];
      final relay = RecordingSignedEventRelay(
        // The relay soft-deletes the target, so the next fetch omits it.
        onSubmit: (submission) {
          final target = submission.tags.firstWhere((t) => t[0] == 'e')[1];
          posts = [
            for (final post in posts)
              if (post.eventId != target) post,
          ];
        },
      );
      await tester.pumpWidget(
        _buildPostsView(
          loadPosts: () => ForumPostsResponse(posts: posts),
          communityRole: CommunityMemberRole.admin,
          signedEventRelay: relay,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Alice post'), findsOneWidget);

      await deleteFirstPost(tester);

      expect(relay.submissions, hasLength(1));
      expect(relay.submissions.single.kind, EventKind.nip29DeleteEvent);
      expect(relay.submissions.single.tags, [
        ['h', _channelId],
        ['e', 'alice-post'],
      ]);
      expect(find.text('Alice post'), findsNothing);
      expect(find.text('Other post'), findsOneWidget);
    });

    testWidgets('forum admin deletes another member\'s post with kind 9005', (
      tester,
    ) async {
      final relay = RecordingSignedEventRelay();
      await tester.pumpWidget(
        _buildPostsView(
          postsResponse: ForumPostsResponse(
            posts: [_makePost(eventId: 'alice-post', content: 'Alice post')],
          ),
          communityRole: CommunityMemberRole.member,
          channelMembers: [
            ChannelMember(
              pubkey: 'self',
              role: 'owner',
              joinedAt: DateTime(2025),
            ),
          ],
          signedEventRelay: relay,
        ),
      );
      await tester.pumpAndSettle();

      await deleteFirstPost(tester);

      expect(relay.submissions.single.kind, EventKind.nip29DeleteEvent);
    });

    testWidgets('plain forum member cannot delete another member\'s post', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildPostsView(
          postsResponse: ForumPostsResponse(
            posts: [_makePost(eventId: 'alice-post', content: 'Alice post')],
          ),
          communityRole: CommunityMemberRole.member,
          channelMembers: [
            ChannelMember(
              pubkey: 'self',
              role: 'member',
              joinedAt: DateTime(2025),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.longPress(
        find.ancestor(
          of: find.text('Alice post'),
          matching: find.byType(ForumPostCard),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Copy text'), findsOneWidget);
      expect(find.text('Delete post'), findsNothing);
    });

    // The relay refuses moderator deletes in an archived forum.
    testWidgets('community admin sees no Delete post on another member\'s '
        'post in an archived forum', (tester) async {
      await tester.pumpWidget(
        _buildPostsView(
          channel: _forumChannel.copyWith(archivedAt: DateTime(2026)),
          postsResponse: ForumPostsResponse(
            posts: [
              _makePost(eventId: 'alice-post', content: 'Alice post'),
              _makePost(
                eventId: 'own-post',
                pubkey: 'self',
                content: 'Own post',
              ),
            ],
          ),
          communityRole: CommunityMemberRole.owner,
        ),
      );
      await tester.pumpAndSettle();

      Future<void> openCard(String content) async {
        await tester.longPress(
          find.ancestor(
            of: find.text(content),
            matching: find.byType(ForumPostCard),
          ),
        );
        await tester.pumpAndSettle();
      }

      await openCard('Alice post');
      expect(find.text('Copy text'), findsOneWidget);
      expect(find.text('Delete post'), findsNothing);
      Navigator.of(tester.element(find.text('Copy text'))).pop();
      await tester.pumpAndSettle();

      // The author's own Delete stays.
      await openCard('Own post');
      expect(find.text('Delete post'), findsOneWidget);
    });

    testWidgets('own post delete keeps the kind 5 author path', (tester) async {
      final relay = RecordingSignedEventRelay();
      await tester.pumpWidget(
        _buildPostsView(
          postsResponse: ForumPostsResponse(
            posts: [
              _makePost(
                eventId: 'own-post',
                pubkey: 'self',
                content: 'Alice post',
              ),
            ],
          ),
          communityRole: CommunityMemberRole.owner,
          signedEventRelay: relay,
        ),
      );
      await tester.pumpAndSettle();

      await deleteFirstPost(tester);

      expect(relay.submissions.single.kind, EventKind.deletion);
      expect(relay.submissions.single.tags, [
        ['h', _channelId],
        ['e', 'own-post'],
      ]);
    });

    testWidgets('surfaces a failed moderator delete in a SnackBar', (
      tester,
    ) async {
      final relay = RecordingSignedEventRelay(error: Exception('rejected'));
      await tester.pumpWidget(
        _buildPostsView(
          postsResponse: ForumPostsResponse(
            posts: [_makePost(eventId: 'alice-post', content: 'Alice post')],
          ),
          communityRole: CommunityMemberRole.admin,
          signedEventRelay: relay,
        ),
      );
      await tester.pumpAndSettle();

      await deleteFirstPost(tester);

      expect(relay.submissions.single.kind, EventKind.nip29DeleteEvent);
      expect(
        find.text('Failed to delete post: Exception: rejected'),
        findsOneWidget,
      );
    });
  });

  group('ForumThreadPage', () {
    ThreadReply reply(String eventId, String content) => ThreadReply(
      eventId: eventId,
      pubkey: 'bob',
      content: content,
      kind: 45003,
      createdAt: 2000,
      channelId: _channelId,
      tags: const [
        ['h', _channelId],
      ],
      depth: 1,
    );

    testWidgets('pull down shows a reply published after opening', (
      tester,
    ) async {
      var loads = 0;
      await tester.pumpWidget(
        _buildThreadPage(
          threadResponse: ForumThreadResponse(
            post: _makePost(),
            replies: const [],
            totalReplies: 0,
          ),
          loadThread: () async {
            loads++;
            final replies = loads == 1
                ? const <ThreadReply>[]
                : [reply('r1', 'Late reply')];
            return ForumThreadResponse(
              post: _makePost(),
              replies: replies,
              totalReplies: replies.length,
            );
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('0 replies'), findsOneWidget);

      await tester.timedDrag(
        find.byType(ListView),
        const Offset(0, 320),
        const Duration(milliseconds: 500),
      );
      await tester.pumpAndSettle();

      expect(loads, 2);
      expect(find.text('1 reply'), findsOneWidget);
      expect(find.text('Late reply'), findsOneWidget);
    });

    testWidgets('Retry reloads a thread that failed to load', (tester) async {
      var loads = 0;
      await tester.pumpWidget(
        _buildThreadPage(
          threadResponse: ForumThreadResponse(
            post: _makePost(),
            replies: const [],
            totalReplies: 0,
          ),
          loadThread: () async {
            loads++;
            if (loads == 1) throw Exception('relay timeout');
            return ForumThreadResponse(
              post: _makePost(),
              replies: [reply('r1', 'Reply after retry')],
              totalReplies: 1,
            );
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Failed to load thread'), findsOneWidget);

      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(loads, 2);
      expect(find.text('Failed to load thread'), findsNothing);
      expect(find.text('Reply after retry'), findsOneWidget);
    });

    AvatarImage avatarIn(WidgetTester tester, Key key) =>
        tester.widget<AvatarImage>(
          find.descendant(
            of: find.byKey(key),
            matching: find.byType(AvatarImage),
          ),
        );

    testWidgets(
      'uses directory classification for an uncached original author',
      (tester) async {
        await tester.pumpWidget(
          _buildThreadPage(
            threadResponse: ForumThreadResponse(
              post: _makePost(pubkey: 'directory-agent'),
              replies: const [],
              totalReplies: 0,
            ),
            knownAgentPubkeys: const {'directory-agent'},
          ),
        );
        await tester.pumpAndSettle();

        expect(
          avatarIn(
            tester,
            const ValueKey('forum-original-avatar-post1'),
          ).isAgent,
          isTrue,
        );
      },
    );

    testWidgets('uses bot-role classification for an uncached reply author', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildThreadPage(
          threadResponse: ForumThreadResponse(
            post: _makePost(),
            replies: const [
              ThreadReply(
                eventId: 'bot-reply',
                pubkey: 'channel-bot',
                content: 'Automated reply',
                kind: 45003,
                createdAt: 2000,
                channelId: _channelId,
                tags: [
                  ['h', _channelId],
                ],
                depth: 1,
              ),
            ],
            totalReplies: 1,
          ),
          users: const {'alice': _aliceProfile},
          channelBotPubkeys: const {'channel-bot'},
        ),
      );
      await tester.pumpAndSettle();

      expect(
        avatarIn(
          tester,
          const ValueKey('forum-reply-avatar-bot-reply'),
        ).isAgent,
        isTrue,
      );
      expect(
        avatarIn(tester, const ValueKey('forum-original-avatar-post1')).isAgent,
        isFalse,
      );
    });

    testWidgets('shows original post and replies header', (tester) async {
      await tester.pumpWidget(
        _buildThreadPage(
          threadResponse: ForumThreadResponse(
            post: _makePost(content: 'Thread root'),
            replies: const [],
            totalReplies: 0,
          ),
          users: const {'alice': _aliceProfile},
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Thread'), findsOneWidget); // App bar title
      expect(find.text('0 replies'), findsOneWidget);
      expect(
        find.text('No replies yet. Be the first to respond.'),
        findsOneWidget,
      );
    });

    testWidgets('shows reply count with replies', (tester) async {
      await tester.pumpWidget(
        _buildThreadPage(
          threadResponse: ForumThreadResponse(
            post: _makePost(),
            replies: [
              const ThreadReply(
                eventId: 'r1',
                pubkey: 'bob',
                content: 'Great post!',
                kind: 45003,
                createdAt: 2000,
                channelId: _channelId,
                tags: [
                  ['h', _channelId],
                ],
                depth: 1,
              ),
            ],
            totalReplies: 1,
          ),
          users: const {
            'alice': _aliceProfile,
            'bob': UserProfile(pubkey: 'bob', displayName: 'Bob'),
          },
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('1 reply'), findsOneWidget);
      expect(find.text('Bob'), findsOneWidget);
    });

    testWidgets('constrains post and reply timestamps at large text sizes', (
      tester,
    ) async {
      final oldTimestamp =
          DateTime.utc(2025, 12, 31, 12).millisecondsSinceEpoch ~/ 1000;

      await tester.pumpWidget(
        _buildThreadPage(
          threadResponse: ForumThreadResponse(
            post: _makePost(createdAt: oldTimestamp),
            replies: [
              ThreadReply(
                eventId: 'old-reply',
                pubkey: 'bob',
                content: 'An older reply',
                kind: 45003,
                createdAt: oldTimestamp,
                channelId: _channelId,
                tags: const [
                  ['h', _channelId],
                ],
                depth: 1,
              ),
            ],
            totalReplies: 1,
          ),
          users: const {
            'alice': _aliceProfile,
            'bob': UserProfile(
              pubkey: 'bob',
              displayName: 'A very long reply author name',
            ),
          },
          textScaler: const TextScaler.linear(2),
        ),
      );
      await tester.pumpAndSettle();

      final timestamps = tester.widgetList<Text>(find.text('12/31/2025'));
      expect(timestamps, hasLength(2));
      for (final timestamp in timestamps) {
        expect(timestamp.maxLines, 1);
        expect(timestamp.overflow, TextOverflow.ellipsis);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('gives thread authors unused timestamp width', (tester) async {
      _setSurfaceSize(tester, const Size(320, 800));
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final createdAt = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 120;
      const postAuthor = 'A moderately long original author';
      const replyAuthor = 'A moderately long reply author';

      await tester.pumpWidget(
        _buildThreadPage(
          threadResponse: ForumThreadResponse(
            post: _makePost(createdAt: createdAt),
            replies: [
              ThreadReply(
                eventId: 'reply',
                pubkey: 'bob',
                content: 'A reply',
                kind: 45003,
                createdAt: createdAt,
                channelId: _channelId,
                tags: const [
                  ['h', _channelId],
                ],
                depth: 1,
              ),
            ],
            totalReplies: 1,
          ),
          users: const {
            'alice': UserProfile(pubkey: 'alice', displayName: postAuthor),
            'bob': UserProfile(pubkey: 'bob', displayName: replyAuthor),
          },
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.getSize(find.text(postAuthor)).width, greaterThan(150));
      expect(tester.getSize(find.text(replyAuthor)).width, greaterThan(140));
      expect(find.text('2m ago'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('shows compose bar for members', (tester) async {
      await tester.pumpWidget(
        _buildThreadPage(
          threadResponse: ForumThreadResponse(
            post: _makePost(),
            replies: const [],
            totalReplies: 0,
          ),
          isMember: true,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Reply to this post\u2026'), findsOneWidget);
    });

    testWidgets('renders media previews for forum posts', (tester) async {
      const imageUrl = 'https://example.com/media/forum.png';

      await tester.pumpWidget(
        _buildThreadPage(
          threadResponse: ForumThreadResponse(
            post: _makePost(
              content: '![image]($imageUrl)',
              tags: const [
                ['h', _channelId],
                [
                  'imeta',
                  'url https://example.com/media/forum.png',
                  'm image/png',
                ],
              ],
            ),
            replies: const [],
            totalReplies: 0,
          ),
          users: const {'alice': _aliceProfile},
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(
          const ValueKey(
            'message-media-image-preview:https://example.com/media/forum.png',
          ),
        ),
        findsOneWidget,
      );
    });

    testWidgets('keeps tall forum image previews bounded inline', (
      tester,
    ) async {
      _setSurfaceSize(tester, const Size(400, 800));
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      const imageUrl = 'https://example.com/media/forum-tall.png';

      await tester.pumpWidget(
        _buildThreadPage(
          threadResponse: ForumThreadResponse(
            post: _makePost(
              content: '![image]($imageUrl)',
              tags: const [
                ['h', _channelId],
                [
                  'imeta',
                  'url https://example.com/media/forum-tall.png',
                  'm image/png',
                  'dim 1200x2400',
                ],
              ],
            ),
            replies: const [],
            totalReplies: 0,
          ),
          users: const {'alice': _aliceProfile},
        ),
      );
      await tester.pumpAndSettle();

      final preview = find.byKey(
        const ValueKey(
          'message-media-image-preview:https://example.com/media/forum-tall.png',
        ),
      );
      final size = tester.getSize(preview);

      expect(size.height, closeTo(240, 0.1));
      expect(size.width, closeTo(120, 0.1));
    });

    testWidgets('hides compose bar for non-members', (tester) async {
      await tester.pumpWidget(
        _buildThreadPage(
          threadResponse: ForumThreadResponse(
            post: _makePost(),
            replies: const [],
            totalReplies: 0,
          ),
          isMember: false,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Reply to this post\u2026'), findsNothing);
    });

    testWidgets('shows 3-dot in app bar for own post', (tester) async {
      await tester.pumpWidget(
        _buildThreadPage(
          threadResponse: ForumThreadResponse(
            post: _makePost(pubkey: 'self'),
            replies: const [],
            totalReplies: 0,
          ),
          currentPubkey: 'self',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip('Post actions'), findsOneWidget);
    });

    testWidgets('hides 3-dot in app bar for others post', (tester) async {
      await tester.pumpWidget(
        _buildThreadPage(
          threadResponse: ForumThreadResponse(
            post: _makePost(pubkey: 'alice'),
            replies: const [],
            totalReplies: 0,
          ),
          currentPubkey: 'self',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip('Post actions'), findsNothing);
    });

    testWidgets('community admin deletes another member\'s post from the '
        'thread with kind 9005', (tester) async {
      final relay = RecordingSignedEventRelay();
      await tester.pumpWidget(
        _buildThreadPage(
          threadResponse: ForumThreadResponse(
            post: _makePost(pubkey: 'alice'),
            replies: const [],
            totalReplies: 0,
          ),
          currentPubkey: 'self',
          communityRole: CommunityMemberRole.owner,
          signedEventRelay: relay,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Post actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete post'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(relay.submissions.single.kind, EventKind.nip29DeleteEvent);
      expect(relay.submissions.single.tags, [
        ['h', _channelId],
        ['e', 'post1'],
      ]);
    });

    Future<void> openReplyActions(WidgetTester tester) async {
      await tester.tap(
        find.descendant(
          of: find.byWidgetPredicate(
            (widget) => widget.runtimeType.toString() == '_ReplyRow',
          ),
          matching: find.byType(IconButton),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('community admin gets no post or reply Delete on other '
        'members\' content in an archived forum', (tester) async {
      await tester.pumpWidget(
        _buildThreadPage(
          threadResponse: ForumThreadResponse(
            post: _makePost(pubkey: 'alice'),
            replies: [reply('bob-reply', 'Bob reply')],
            totalReplies: 1,
          ),
          currentPubkey: 'self',
          isArchived: true,
          communityRole: CommunityMemberRole.owner,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip('Post actions'), findsNothing);
      await openReplyActions(tester);
      expect(find.text('Copy text'), findsOneWidget);
      expect(find.text('Delete reply'), findsNothing);
    });

    testWidgets('author keeps post Delete in an archived forum', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildThreadPage(
          threadResponse: ForumThreadResponse(
            post: _makePost(pubkey: 'self'),
            replies: const [],
            totalReplies: 0,
          ),
          currentPubkey: 'self',
          isArchived: true,
          communityRole: CommunityMemberRole.owner,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip('Post actions'), findsOneWidget);
    });

    testWidgets('community admin deletes another member\'s reply with kind '
        '9005 and the refetched thread drops it', (tester) async {
      var replies = [reply('bob-reply', 'Bob reply')];
      final relay = RecordingSignedEventRelay(
        onSubmit: (submission) {
          final target = submission.tags.firstWhere((t) => t[0] == 'e')[1];
          replies = [
            for (final r in replies)
              if (r.eventId != target) r,
          ];
        },
      );
      await tester.pumpWidget(
        _buildThreadPage(
          threadResponse: ForumThreadResponse(
            post: _makePost(pubkey: 'alice'),
            replies: replies,
            totalReplies: replies.length,
          ),
          loadThread: () async => ForumThreadResponse(
            post: _makePost(pubkey: 'alice'),
            replies: replies,
            totalReplies: replies.length,
          ),
          currentPubkey: 'self',
          communityRole: CommunityMemberRole.admin,
          signedEventRelay: relay,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Bob reply'), findsOneWidget);

      await openReplyActions(tester);
      await tester.tap(find.text('Delete reply'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(relay.submissions.single.kind, EventKind.nip29DeleteEvent);
      expect(relay.submissions.single.tags, [
        ['h', _channelId],
        ['e', 'bob-reply'],
      ]);
      expect(find.text('Bob reply'), findsNothing);
    });

    testWidgets('plain member does not see Delete reply on others\' replies', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildThreadPage(
          threadResponse: ForumThreadResponse(
            post: _makePost(pubkey: 'alice'),
            replies: [reply('bob-reply', 'Bob reply')],
            totalReplies: 1,
          ),
          currentPubkey: 'self',
          communityRole: CommunityMemberRole.member,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip('Post actions'), findsNothing);
      await openReplyActions(tester);
      expect(find.text('Copy text'), findsOneWidget);
      expect(find.text('Delete reply'), findsNothing);
    });

    testWidgets('own reply delete keeps the kind 5 author path', (
      tester,
    ) async {
      final relay = RecordingSignedEventRelay();
      final ownReply = ThreadReply(
        eventId: 'own-reply',
        pubkey: 'self',
        content: 'Bob reply',
        kind: 45003,
        createdAt: 2000,
        channelId: _channelId,
        tags: const [
          ['h', _channelId],
        ],
        depth: 1,
      );
      await tester.pumpWidget(
        _buildThreadPage(
          threadResponse: ForumThreadResponse(
            post: _makePost(pubkey: 'alice'),
            replies: [ownReply],
            totalReplies: 1,
          ),
          currentPubkey: 'self',
          communityRole: CommunityMemberRole.admin,
          signedEventRelay: relay,
        ),
      );
      await tester.pumpAndSettle();

      await openReplyActions(tester);
      await tester.tap(find.text('Delete reply'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(relay.submissions.single.kind, EventKind.deletion);
    });
  });
}

class _FakeUserCacheNotifier extends UserCacheNotifier {
  final Map<String, UserProfile> _users;
  _FakeUserCacheNotifier(this._users);

  @override
  Map<String, UserProfile> build() => _users;

  @override
  UserProfile? get(String pubkey) => _users[pubkey.toLowerCase()];
}

class _FakeProfileNotifier extends ProfileNotifier {
  @override
  Future<UserProfile?> build() async =>
      const UserProfile(pubkey: 'self', displayName: 'Self');
}
