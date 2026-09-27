import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../../shared/mentions/agent_identity_provider.dart';
import '../../shared/read_state/deferred_read_state_update.dart';
import '../../shared/read_state/read_state_format.dart';
import '../../shared/read_state/read_state_provider.dart';
import '../../shared/theme/theme.dart';
import '../../shared/widgets/avatar_image.dart';
import '../../shared/widgets/bee_refresh_indicator.dart';
import '../../shared/widgets/buzz_loading_indicator.dart';
import '../../shared/widgets/frosted_app_bar.dart';
import '../../shared/widgets/frosted_scaffold.dart';
import '../../shared/widgets/modal_presentation.dart';
import '../channels/channel_typing_provider.dart';
import '../channels/compose_bar.dart';
import '../../shared/widgets/jump_to_latest_button.dart';
import '../../shared/widgets/jump_to_latest_switcher.dart';
import '../channels/message_content.dart';
import '../../shared/profile/user_cache_provider.dart';
import '../../shared/utils/string_utils.dart';
import '../../shared/profile/user_profile.dart';
import '../profile/user_profile_sheet.dart';
import 'forum_activity.dart';
import 'forum_models.dart';
import 'forum_provider.dart';
import 'forum_working_indicator.dart';

/// Full-screen page showing a forum post and its replies.
class ForumThreadPage extends HookConsumerWidget {
  final String channelId;
  final String postEventId;
  final String? currentPubkey;
  final bool isMember;
  final bool isArchived;
  final String? initialMessageId;
  final ThreadReply? initialReply;

  const ForumThreadPage({
    super.key,
    required this.channelId,
    required this.postEventId,
    required this.currentPubkey,
    required this.isMember,
    required this.isArchived,
    this.initialMessageId,
    this.initialReply,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final threadAsync = ref.watch(
      forumThreadProvider((channelId: channelId, eventId: postEventId)),
    );
    // Replies deleted from this page. Kept for the page's lifetime, because a
    // failed reload replaces the thread content and would forget them.
    final deletedReplyIds = useState<Set<String>>(const {});

    // Manual refresh for pull-down and the error state's Retry button.
    Future<void> refresh() async {
      final next = ref.refresh(
        forumThreadProvider((
          channelId: channelId,
          eventId: postEventId,
        )).future,
      );
      try {
        await next;
      } on Object {
        // The page's error state shows the failure.
      }
    }

    // Periodic refresh (every 10s, matching desktop).
    useEffect(() {
      final timer = Stream.periodic(const Duration(seconds: 10)).listen((_) {
        ref.invalidate(
          forumThreadProvider((channelId: channelId, eventId: postEventId)),
        );
      });
      return timer.cancel;
    }, [channelId, postEventId]);

    final isOwnPost =
        threadAsync
            .whenData(
              (t) =>
                  currentPubkey != null &&
                  t.post.pubkey.toLowerCase() == currentPubkey!.toLowerCase(),
            )
            .value ??
        false;
    // Community and forum owners/admins may delete other members' posts,
    // except in an archived forum, where the relay refuses moderator deletes.
    final canModerate =
        !isArchived && ref.watch(canModerateForumProvider(channelId));
    final canDeletePost = threadAsync.hasValue && (isOwnPost || canModerate);

    return FrostedScaffold(
      appBar: FrostedAppBar(
        title: const Text('Thread'),
        actions: [
          if (canDeletePost)
            IconButton(
              onPressed: () => _showPostActions(
                context,
                ref,
                threadAsync.value!,
                asModerator: !isOwnPost,
              ),
              tooltip: 'Post actions',
              icon: const Icon(LucideIcons.ellipsis),
            ),
        ],
      ),
      body: threadAsync.when(
        loading: () => Padding(
          padding: EdgeInsets.only(top: frostedAppBarHeight(context)),
          child: const Center(
            child: BuzzLoadingIndicator(
              size: 44,
              semanticLabel: 'Loading thread',
            ),
          ),
        ),
        error: (e, _) => Padding(
          padding: EdgeInsets.only(top: frostedAppBarHeight(context)),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Failed to load thread',
                  style: context.textTheme.bodyMedium?.copyWith(
                    color: context.colors.error,
                  ),
                ),
                TextButton(onPressed: refresh, child: const Text('Retry')),
              ],
            ),
          ),
        ),
        data: (thread) => _ThreadContent(
          thread: thread,
          channelId: channelId,
          currentPubkey: currentPubkey,
          isMember: isMember,
          isArchived: isArchived,
          initialMessageId: initialMessageId,
          initialReply: initialReply,
          deletedReplyIds: deletedReplyIds.value,
          onReplyDeleted: (eventId) =>
              deletedReplyIds.value = {...deletedReplyIds.value, eventId},
          onRefresh: refresh,
        ),
      ),
    );
  }

  void _showPostActions(
    BuildContext context,
    WidgetRef ref,
    ForumThreadResponse thread, {
    required bool asModerator,
  }) {
    showBuzzModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: IconTheme.merge(
          data: const IconThemeData(size: 22),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              Grid.gutter,
              0,
              Grid.gutter,
              Grid.xs,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(LucideIcons.copy),
                  title: const Text('Copy text'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    Clipboard.setData(ClipboardData(text: thread.post.content));
                  },
                ),
                ListTile(
                  leading: Icon(
                    LucideIcons.trash2,
                    color: sheetContext.colors.error,
                  ),
                  title: Text(
                    'Delete post',
                    style: TextStyle(color: sheetContext.colors.error),
                  ),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _confirmDeletePost(
                      context,
                      ref,
                      thread.post.eventId,
                      asModerator: asModerator,
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _confirmDeletePost(
    BuildContext context,
    WidgetRef ref,
    String eventId, {
    required bool asModerator,
  }) {
    showBuzzDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete post'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(dialogContext).pop();
              final messenger = ScaffoldMessenger.maybeOf(context);
              try {
                await deleteForumEvent(
                  ref,
                  channelId: channelId,
                  eventId: eventId,
                  asModerator: asModerator,
                );
              } catch (error) {
                messenger?.showSnackBar(
                  SnackBar(content: Text('Failed to delete post: $error')),
                );
                return;
              }
              if (context.mounted) {
                Navigator.of(context).pop();
              }
            },
            style: FilledButton.styleFrom(
              backgroundColor: dialogContext.colors.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}

class _ThreadContent extends HookConsumerWidget {
  final ForumThreadResponse thread;
  final String channelId;
  final String? currentPubkey;
  final bool isMember;
  final bool isArchived;
  final Future<void> Function() onRefresh;
  final String? initialMessageId;
  final ThreadReply? initialReply;
  final Set<String> deletedReplyIds;
  final ValueChanged<String> onReplyDeleted;

  const _ThreadContent({
    required this.thread,
    required this.channelId,
    required this.currentPubkey,
    required this.isMember,
    required this.isArchived,
    required this.onRefresh,
    required this.deletedReplyIds,
    required this.onReplyDeleted,
    this.initialMessageId,
    this.initialReply,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Background media delivery may outlive this route's WidgetRef.
    final providerContainer = ProviderScope.containerOf(context, listen: false);
    final forumDelivery = ForumEventDelivery.capture(providerContainer);
    final post = thread.post;
    // The notification may point outside the relay's newest reply window, so
    // its reply is kept as a seed. Keep the seed only while it is older than
    // every loaded reply: inside the loaded window, its absence means it was
    // deleted. A reply deleted from this page is dropped at once.
    final seed = initialReply;
    final keepSeed =
        seed != null &&
        !deletedReplyIds.contains(seed.eventId) &&
        thread.replies.isNotEmpty &&
        !thread.replies.any((reply) => reply.eventId == seed.eventId) &&
        thread.replies.every((reply) => seed.createdAt < reply.createdAt);
    final replies =
        [
          ...thread.replies.where(
            (reply) => !deletedReplyIds.contains(reply.eventId),
          ),
          if (keepSeed) seed,
        ]..sort((a, b) {
          final byTime = a.createdAt.compareTo(b.createdAt);
          return byTime == 0 ? a.eventId.compareTo(b.eventId) : byTime;
        });

    // Preload profiles for all participants and tagged mentions.
    final allPubkeys = useMemoized(() {
      final pks = <String>{
        post.pubkey.toLowerCase(),
        ...post.mentionPubkeys.map((pubkey) => pubkey.toLowerCase()),
      };
      for (final reply in replies) {
        pks
          ..add(reply.pubkey.toLowerCase())
          ..addAll(reply.mentionPubkeys.map((pubkey) => pubkey.toLowerCase()));
      }
      return pks.toList()..sort();
    }, [post, replies]);
    final allPubkeysKey = allPubkeys.join('\u0000');

    useEffect(() {
      if (allPubkeys.isNotEmpty) {
        ref.read(userCacheProvider.notifier).preload(allPubkeys);
      }
      return null;
    }, [allPubkeysKey]);

    // Opening the thread reads it: advance `thread:<postId>` to the newest
    // loaded reply, and again as newer replies (including our own) load.
    final readStateReady = ref.watch(
      readStateProvider.select((state) => state.isReady),
    );
    // The post list underneath, when open, holds the relay's summary for this
    // post. Only consult it if it already exists; don't start a list fetch.
    final listedSummary = ref.exists(forumPostsProvider(channelId))
        ? ref.watch(
            forumPostsProvider(channelId).select(
              (posts) => _listedSummary(posts.asData?.value, post.eventId),
            ),
          )
        : null;
    final readAt = forumThreadReadAt(
      post: post,
      replies: replies,
      listedSummary: listedSummary,
    );
    useEffect(() {
      if (!readStateReady) return null;
      return deferReadStateUpdate(context, () {
        ref
            .read(readStateProvider.notifier)
            .markContextRead(threadContextKey(post.eventId), readAt);
      });
    }, [post.eventId, readStateReady, readAt]);

    // Joined so unrelated typing churn does not rebuild the thread.
    final workingKey = ref.watch(
      channelTypingProvider(channelId).select(
        (entries) => forumTypingPubkeys(
          entries,
          threadHeadId: post.eventId,
          currentPubkey: currentPubkey,
        ).join(','),
      ),
    );

    final scrollController = useMemoized(ItemScrollController.new);
    final positionsListener = useMemoized(ItemPositionsListener.create);
    final jumped = useRef(false);
    final highlighted = useState<String?>(null);
    final targetIndex = initialMessageId == post.eventId
        ? 0
        : replies.indexWhere((reply) => reply.eventId == initialMessageId) + 2;
    final targetExists =
        initialMessageId != null &&
        (initialMessageId == post.eventId || targetIndex >= 2);
    useEffect(() {
      if (!targetExists || jumped.value) return null;
      var disposed = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (disposed || !scrollController.isAttached) return;
        jumped.value = true;
        scrollController.jumpTo(index: targetIndex, alignment: 0.2);
        highlighted.value = initialMessageId;
      });
      return () {
        disposed = true;
      };
    }, [initialMessageId, targetExists, targetIndex]);
    useEffect(() {
      if (highlighted.value == null) return null;
      final timer = Timer(
        const Duration(seconds: 3),
        () => highlighted.value = null,
      );
      return timer.cancel;
    }, [highlighted.value]);

    Widget highlight(String id, Widget child) => ColoredBox(
      key: ValueKey('forum-message-$id'),
      color: highlighted.value == id
          ? context.colors.primary.withValues(alpha: 0.12)
          : Colors.transparent,
      child: child,
    );
    final rows = [
      highlight(post.eventId, _OriginalPost(post: post)),

      Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Grid.gutter,
          vertical: Grid.xxs,
        ),
        child: Row(
          children: [
            Icon(
              LucideIcons.messageSquare,
              size: 16,
              color: context.colors.onSurfaceVariant,
            ),
            const SizedBox(width: Grid.half),
            Text(
              '${replies.length} ${replies.length == 1 ? 'reply' : 'replies'}',
              style: context.textTheme.labelMedium?.copyWith(
                color: context.colors.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),

      // Reply list
      if (replies.isEmpty)
        Padding(
          padding: const EdgeInsets.all(Grid.sm),
          child: Text(
            'No replies yet. Be the first to respond.',
            style: context.textTheme.bodyMedium?.copyWith(
              color: context.colors.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        )
      else
        for (final reply in replies)
          highlight(
            reply.eventId,
            _ReplyRow(
              reply: reply,
              currentPubkey: currentPubkey,
              channelId: channelId,
              rootEventId: post.eventId,
              isArchived: isArchived,
              onDeleted: onReplyDeleted,
            ),
          ),
      // Zero-height end marker: jumping to it with alignment 1.0 puts the
      // end of the thread at the bottom of the viewport.
      const SizedBox.shrink(key: ValueKey('forum-thread-end')),
    ];
    final endIndex = rows.length - 1;

    final isAtLatest = useState(true);
    useEffect(() {
      void update() {
        // The list does not report the zero-height end marker, so check the
        // last real row. Rows with no reported position are off screen.
        isAtLatest.value = positionsListener.itemPositions.value.any(
          (item) =>
              item.index == endIndex - 1 && item.itemTrailingEdge <= 1.001,
        );
      }

      positionsListener.itemPositions.addListener(update);
      return () => positionsListener.itemPositions.removeListener(update);
    }, [positionsListener, endIndex]);

    void scrollToLatest() {
      if (!scrollController.isAttached) return;
      final reduceMotion = MediaQuery.disableAnimationsOf(context);
      if (reduceMotion) {
        scrollController.jumpTo(index: endIndex, alignment: 1);
        return;
      }
      unawaited(
        scrollController.scrollTo(
          index: endIndex,
          alignment: 1,
          duration: jumpToLatestScrollDuration,
          curve: jumpToLatestScrollCurve,
        ),
      );
    }

    return Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              BeeRefreshIndicator(
                edgeOffset: frostedAppBarHeight(context),
                onRefresh: onRefresh,
                child: ScrollablePositionedList.builder(
                  itemScrollController: scrollController,
                  itemPositionsListener: positionsListener,
                  padding: EdgeInsets.only(
                    top: frostedAppBarHeight(context),
                    bottom: Grid.xs,
                  ),
                  itemCount: rows.length,
                  itemBuilder: (context, index) => rows[index],
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: Grid.xs,
                child: Center(
                  child: JumpToLatestSwitcher(
                    id: 'forum-thread',
                    visible: replies.isNotEmpty && !isAtLatest.value,
                    onPressed: scrollToLatest,
                  ),
                ),
              ),
            ],
          ),
        ),

        AnimatedSize(
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          alignment: Alignment.bottomCenter,
          child: workingKey.isEmpty
              ? const SizedBox.shrink()
              : ForumWorkingIndicator(
                  key: const ValueKey('forum-thread-working'),
                  channelId: channelId,
                  pubkeys: workingKey.split(','),
                  scope: ForumWorkingScope.reply,
                  contained: true,
                ),
        ),

        // Reply composer
        if (isMember && !isArchived)
          ComposeBar(
            channelId: channelId,
            hintText: 'Reply to this post\u2026',
            onSend:
                (
                  content,
                  mentionPubkeys, {
                  mediaTags = const <List<String>>[],
                }) => forumDelivery.createReply(
                  channelId: channelId,
                  parentEventId: post.eventId,
                  content: content,
                  mentionPubkeys: mentionPubkeys,
                  mediaTags: mediaTags,
                ),
          ),
      ],
    );
  }
}

class _OriginalPost extends ConsumerWidget {
  final ForumPost post;

  const _OriginalPost({required this.post});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pk = post.pubkey.toLowerCase();
    final profile =
        ref.watch(userCacheProvider.select((cache) => cache[pk])) ??
        ref.read(userCacheProvider.notifier).get(pk);
    final displayName = profile?.label ?? shortPubkey(post.pubkey);

    final userCache = ref.watch(userCacheProvider);
    final agentMentionPubkeys = agentPubkeysWithProfileOwners(
      knownAgentPubkeys: ref.watch(agentMentionPubkeysProvider(post.channelId)),
      profileOwnedAgentPubkeys: [
        for (final profile in userCache.values)
          if (profile.ownerPubkey != null) profile.pubkey,
      ],
    );
    final mentionNames = mentionNamesWithDirectoryLabels(
      mentionPubkeys: post.mentionPubkeys,
      profileMentionNames: _buildMentionNames(post.mentionPubkeys, userCache),
      directoryDisplayNames: ref.watch(agentDirectoryDisplayNamesProvider),
      agentMentionPubkeys: agentMentionPubkeys,
    );

    return Padding(
      padding: const EdgeInsets.all(Grid.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              GestureDetector(
                onTap: () => showUserProfileSheet(context, post.pubkey),
                child: _Avatar(
                  key: ValueKey('forum-original-avatar-${post.eventId}'),
                  profile: profile,
                  pubkey: post.pubkey,
                  radius: 16,
                  isAgent: agentMentionPubkeys.contains(pk),
                ),
              ),
              const SizedBox(width: Grid.xxs),
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: () => showUserProfileSheet(context, post.pubkey),
                        child: Text(
                          displayName,
                          maxLines: 1,
                          style: messageUsernameTextStyle,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    const SizedBox(width: Grid.xxs),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: Grid.xxl),
                      child: Text(
                        formatRelativeTime(post.createdAt),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: messageTimestampTextStyle.copyWith(
                          color: context.colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: Grid.xxs),
          MessageContent(
            content: post.content,
            mentionNames: mentionNames,
            agentMentionPubkeys: agentMentionPubkeys,
            tags: post.tags,
            baseStyle: messageBodyTextStyle.copyWith(
              color: context.colors.onSurface,
            ),
            onMentionTap: (pubkey) => showUserProfileSheet(context, pubkey),
          ),
        ],
      ),
    );
  }
}

class _ReplyRow extends ConsumerWidget {
  final ThreadReply reply;
  final String? currentPubkey;
  final String channelId;
  final String rootEventId;
  final bool isArchived;

  /// Called after this reply is deleted, so the page can drop it at once.
  final ValueChanged<String>? onDeleted;

  const _ReplyRow({
    required this.reply,
    required this.currentPubkey,
    required this.channelId,
    required this.rootEventId,
    required this.isArchived,
    this.onDeleted,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pk = reply.pubkey.toLowerCase();
    final profile =
        ref.watch(userCacheProvider.select((cache) => cache[pk])) ??
        ref.read(userCacheProvider.notifier).get(pk);
    final displayName = profile?.label ?? shortPubkey(reply.pubkey);
    // Community and forum owners/admins may delete other members' replies,
    // except in an archived forum, where the relay refuses moderator deletes.
    final canModerate =
        !isArchived && ref.watch(canModerateForumProvider(channelId));

    final userCache = ref.watch(userCacheProvider);
    final agentMentionPubkeys = agentPubkeysWithProfileOwners(
      knownAgentPubkeys: ref.watch(agentMentionPubkeysProvider(channelId)),
      profileOwnedAgentPubkeys: [
        for (final profile in userCache.values)
          if (profile.ownerPubkey != null) profile.pubkey,
      ],
    );
    final mentionNames = mentionNamesWithDirectoryLabels(
      mentionPubkeys: reply.mentionPubkeys,
      profileMentionNames: _buildMentionNames(reply.mentionPubkeys, userCache),
      directoryDisplayNames: ref.watch(agentDirectoryDisplayNamesProvider),
      agentMentionPubkeys: agentMentionPubkeys,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Grid.gutter,
        vertical: Grid.xxs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              GestureDetector(
                onTap: () => showUserProfileSheet(context, reply.pubkey),
                child: _Avatar(
                  key: ValueKey('forum-reply-avatar-${reply.eventId}'),
                  profile: profile,
                  pubkey: reply.pubkey,
                  radius: 12,
                  isAgent: agentMentionPubkeys.contains(pk),
                ),
              ),
              const SizedBox(width: Grid.xxs),
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: () =>
                            showUserProfileSheet(context, reply.pubkey),
                        child: Text(
                          displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: messageUsernameTextStyle,
                        ),
                      ),
                    ),
                    const SizedBox(width: Grid.xxs),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: Grid.xxl),
                      child: Text(
                        formatRelativeTime(reply.createdAt),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: messageTimestampTextStyle.copyWith(
                          color: context.colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 28,
                height: 28,
                child: IconButton(
                  onPressed: () =>
                      _showActions(context, ref, canModerate: canModerate),
                  icon: Icon(
                    LucideIcons.ellipsis,
                    size: 16,
                    color: context.colors.onSurfaceVariant,
                  ),
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 32, top: Grid.half),
            child: MessageContent(
              content: reply.content,
              mentionNames: mentionNames,
              agentMentionPubkeys: agentMentionPubkeys,
              tags: reply.tags,
              baseStyle: messageBodyTextStyle.copyWith(
                color: context.colors.onSurface,
              ),
              onMentionTap: (pubkey) => showUserProfileSheet(context, pubkey),
            ),
          ),
        ],
      ),
    );
  }

  void _showActions(
    BuildContext context,
    WidgetRef ref, {
    required bool canModerate,
  }) {
    final isOwn =
        currentPubkey != null &&
        reply.pubkey.toLowerCase() == currentPubkey!.toLowerCase();
    final asModerator = !isOwn && canModerate;

    showBuzzModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: IconTheme.merge(
          data: const IconThemeData(size: 22),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              Grid.gutter,
              0,
              Grid.gutter,
              Grid.xs,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(LucideIcons.copy),
                  title: const Text('Copy text'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    Clipboard.setData(ClipboardData(text: reply.content));
                  },
                ),
                if (isOwn || asModerator)
                  ListTile(
                    leading: Icon(
                      LucideIcons.trash2,
                      color: sheetContext.colors.error,
                    ),
                    title: Text(
                      'Delete reply',
                      style: TextStyle(color: sheetContext.colors.error),
                    ),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      _confirmDelete(context, ref, asModerator: asModerator);
                    },
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _confirmDelete(
    BuildContext context,
    WidgetRef ref, {
    required bool asModerator,
  }) {
    showBuzzDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete reply'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(dialogContext).pop();
              final messenger = ScaffoldMessenger.maybeOf(context);
              try {
                await deleteForumEvent(
                  ref,
                  channelId: channelId,
                  eventId: reply.eventId,
                  rootEventId: rootEventId,
                  asModerator: asModerator,
                );
              } catch (error) {
                messenger?.showSnackBar(
                  SnackBar(content: Text('Failed to delete reply: $error')),
                );
                return;
              }
              if (context.mounted) onDeleted?.call(reply.eventId);
            },
            style: FilledButton.styleFrom(
              backgroundColor: dialogContext.colors.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final UserProfile? profile;
  final String pubkey;
  final double radius;
  final bool isAgent;

  const _Avatar({
    super.key,
    required this.profile,
    required this.pubkey,
    required this.radius,
    required this.isAgent,
  });

  @override
  Widget build(BuildContext context) {
    final initial =
        profile?.initial ?? (pubkey.isNotEmpty ? pubkey[0].toUpperCase() : '?');
    final avatarUrl = profile?.avatarUrl;

    return AvatarImage(
      imageUrl: avatarUrl,
      radius: radius,
      backgroundColor: context.colors.primaryContainer,
      fallback: Text(
        initial,
        style: TextStyle(
          fontSize: radius * 0.75,
          fontWeight: FontWeight.w600,
          color: context.colors.onPrimaryContainer,
        ),
      ),
      isAgent: isAgent,
    );
  }
}

ForumThreadSummary? _listedSummary(
  ForumPostsResponse? response,
  String postId,
) {
  if (response == null) return null;
  for (final post in response.posts) {
    if (post.eventId == postId) return post.threadSummary;
  }
  return null;
}

Map<String, String> _buildMentionNames(
  List<String> mentionPubkeys,
  Map<String, UserProfile> userCache,
) {
  final names = <String, String>{};
  for (final pk in mentionPubkeys) {
    final p = userCache[pk.toLowerCase()];
    if (p?.displayName != null) {
      names[pk.toLowerCase()] = p!.displayName!;
    }
  }
  return names;
}
