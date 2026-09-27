import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/relay/relay.dart';
import '../channels/channel_management_provider.dart';
import '../../shared/custom_emoji/custom_emoji.dart';
import '../../shared/custom_emoji/custom_emoji_provider.dart';
import 'forum_models.dart';
import 'forum_thread_history.dart';

/// Fetches forum posts (kind:45001) for a channel from the relay.
///
/// Posts are top-level events tagged `#h:<channelId>`. The relay's channel
/// window adds each post's reply count and last reply time. Invalidate to
/// refresh (e.g. after creating a new post).
final forumPostsProvider = FutureProvider.family<ForumPostsResponse, String>((
  ref,
  channelId,
) async {
  final session = ref.watch(relaySessionProvider.notifier);
  final events = await session.queryRelay([
    NostrFilters.forumPostsWindow(channelId, limit: 50),
  ]);
  return ForumPostsResponse.fromEvents(events);
});

/// Identifies a thread within the active community.
typedef ForumThreadKey = ({String channelId, String eventId});

// Keep cache lifetime aligned with the community and signing identity. A late
// response cannot populate a replacement community's history.
final _forumThreadHistoryProvider = Provider.autoDispose
    .family<ForumThreadHistory, ForumThreadKey>((ref, args) {
      ref.watch(relayConfigProvider);
      return ForumThreadHistory();
    });

/// Finite history uses the HTTP bridge so a reconnecting WebSocket cannot
/// strand thread loading. Refreshes merge only recent replies into cached data.
final forumThreadProvider = FutureProvider.autoDispose
    .family<ForumThreadResponse, ForumThreadKey>((ref, args) async {
      final retention = ref.keepAlive();
      Timer? expiry;
      ref.onCancel(() {
        expiry?.cancel();
        expiry = Timer(const Duration(minutes: 5), retention.close);
      });
      ref.onResume(() {
        expiry?.cancel();
      });
      ref.onDispose(() {
        expiry?.cancel();
      });
      final history = ref.watch(_forumThreadHistoryProvider(args));
      final session = ref.watch(relaySessionProvider.notifier);
      return history.load(
        session,
        channelId: args.channelId,
        eventId: args.eventId,
        isCurrent: () => ref.mounted,
      );
    });

/// Read markers use summary metadata when it arrives; messages never wait for it.
final forumThreadSummaryProvider = FutureProvider.autoDispose
    .family<ForumThreadSummary?, ForumThreadKey>((ref, args) async {
      final thread = await ref.watch(forumThreadProvider(args).future);
      if (!ref.mounted || thread.post.kind != EventKind.forumPost) return null;
      final session = ref.read(relaySessionProvider.notifier);
      return fetchForumPostSummary(
        session,
        channelId: args.channelId,
        postEventId: thread.post.eventId,
        postCreatedAt: thread.post.createdAt,
      );
    });

/// The relay's reply summary for one forum post, read from the channel window
/// anchored at the post, or `null` when the post has none or the query fails.
///
/// The summary's `last_reply_at` is the relay's store time, which can trail a
/// reply's signed `created_at`; the thread page needs it to mark the thread
/// read past that gap. Failure is not fatal to opening the thread — it only
/// leaves a post-list dot lit — and the thread's periodic refresh retries.
Future<ForumThreadSummary?> fetchForumPostSummary(
  RelaySessionNotifier session, {
  required String channelId,
  required String postEventId,
  required int postCreatedAt,
}) async {
  try {
    final events = await session.queryRelay([
      NostrFilters.forumPostSummaryWindow(
        channelId,
        postCreatedAt: postCreatedAt,
      ),
    ]);
    for (final listed in ForumPostsResponse.fromEvents(events).posts) {
      if (listed.eventId == postEventId) return listed.threadSummary;
    }
  } on Object catch (error) {
    debugPrint('[forum] post summary fetch failed for $postEventId: $error');
  }
  return null;
}

/// A forum event delivery bound to the community where composition began.
///
/// Attachment uploads can outlive their route. Capturing the relay identity,
/// signing key, and emoji palette prevents a queued draft from being delivered
/// to a different community after the user switches relays.
class ForumEventDelivery {
  final ProviderContainer _container;
  final String _relayUrl;
  final String? _nsec;
  final SignedEventRelay _relay;
  final List<CustomEmoji> _customEmoji;

  ForumEventDelivery._({
    required ProviderContainer container,
    required String relayUrl,
    required String? nsec,
    required SignedEventRelay relay,
    required List<CustomEmoji> customEmoji,
  }) : _container = container,
       _relayUrl = relayUrl,
       _nsec = nsec,
       _relay = relay,
       _customEmoji = customEmoji;

  /// Captures the active community dependencies for a future delivery.
  factory ForumEventDelivery.capture(ProviderContainer container) {
    final config = container.read(relayConfigProvider);
    return ForumEventDelivery._(
      container: container,
      relayUrl: config.baseUrl,
      nsec: config.nsec,
      relay: SignedEventRelay(
        session: container.read(relaySessionProvider.notifier),
        nsec: config.nsec,
      ),
      customEmoji: List<CustomEmoji>.unmodifiable(
        container.read(customEmojiListProvider),
      ),
    );
  }

  /// Creates a new forum post (kind:45001).
  Future<void> createPost({
    required String channelId,
    required String content,
    List<String> mentionPubkeys = const [],
    List<List<String>> mediaTags = const [],
  }) async {
    await _submit(
      kind: EventKind.forumPost,
      channelId: channelId,
      content: content,
      mentionPubkeys: mentionPubkeys,
      mediaTags: mediaTags,
    );
    _container.invalidate(forumPostsProvider(channelId));
  }

  /// Creates a reply to a forum post (kind:45003).
  Future<void> createReply({
    required String channelId,
    required String parentEventId,
    required String content,
    List<String> mentionPubkeys = const [],
    List<List<String>> mediaTags = const [],
  }) async {
    await _submit(
      kind: EventKind.forumComment,
      channelId: channelId,
      parentEventId: parentEventId,
      content: content,
      mentionPubkeys: mentionPubkeys,
      mediaTags: mediaTags,
    );
    _container.invalidate(forumPostsProvider(channelId));
    _container.invalidate(
      forumThreadProvider((channelId: channelId, eventId: parentEventId)),
    );
  }

  Future<void> _submit({
    required int kind,
    required String channelId,
    required String content,
    String? parentEventId,
    required List<String> mentionPubkeys,
    required List<List<String>> mediaTags,
  }) async {
    final currentConfig = _container.read(relayConfigProvider);
    if (currentConfig.baseUrl != _relayUrl || currentConfig.nsec != _nsec) {
      throw StateError(
        'Forum delivery cancelled because the active community changed',
      );
    }

    final selfPubkey = _relay.pubkey?.toLowerCase();
    final seen = <String>{?selfPubkey};
    final normalizedMentions = [
      for (final pk in mentionPubkeys)
        if (seen.add(pk.toLowerCase())) pk,
    ];

    await _relay.submit(
      kind: kind,
      content: content,
      tags: [
        ['h', channelId],
        if (parentEventId != null) ['e', parentEventId, '', 'reply'],
        for (final pk in normalizedMentions) ['p', pk],
        ...mediaTags,
        ...buildCustomEmojiTags(content, _customEmoji),
      ],
    );
  }
}

/// Whether the active user may delete other members' posts and replies in the
/// forum [channelId]: a community owner/admin or an owner/admin of the forum.
final canModerateForumProvider = Provider.autoDispose.family<bool, String>(
  (ref, channelId) => ref.watch(canModerateChannelMessagesProvider(channelId)),
);

/// Deletes a forum post or reply and invalidates relevant caches.
///
/// [asModerator] selects the NIP-29 kind:9005 moderator delete used when a
/// community owner/admin removes someone else's post or reply; authors keep
/// the NIP-09 kind:5 path.
Future<void> deleteForumEvent(
  WidgetRef ref, {
  required String channelId,
  required String eventId,
  String? rootEventId,
  bool asModerator = false,
}) async {
  final actions = ref.read(channelActionsProvider);
  await actions.deleteMessage(
    channelId: channelId,
    eventId: eventId,
    asModerator: asModerator,
  );
  ref.invalidate(forumPostsProvider(channelId));
  if (rootEventId != null) {
    ref.invalidate(
      forumThreadProvider((channelId: channelId, eventId: rootEventId)),
    );
  }
}
