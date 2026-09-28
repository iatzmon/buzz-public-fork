import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../shared/theme/theme.dart';
import '../../shared/widgets/buzz_loading_indicator.dart';
import '../../shared/widgets/frosted_app_bar.dart';
import '../../shared/widgets/bee_refresh_indicator.dart';
import '../channels/channel.dart';
import '../channels/channel_typing_provider.dart';
import '../channels/compose_bar.dart';
import 'forum_activity.dart';
import 'forum_models.dart';
import 'forum_post_card.dart';
import 'forum_provider.dart';
import 'forum_thread_page.dart';
import 'forum_working_indicator.dart';

/// Main forum view — replaces the old _ForumPlaceholder.
///
/// Shows a list of forum posts for the channel with a FAB to open the compose
/// bar, and navigates to [ForumThreadPage] when a post is tapped.
class ForumPostsView extends HookConsumerWidget {
  final Channel channel;
  final String? currentPubkey;

  /// Opens with the new-post composer showing (and its saved draft), when
  /// the viewer can post.
  final bool startComposing;

  const ForumPostsView({
    super.key,
    required this.channel,
    required this.currentPubkey,
    this.startComposing = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final postsAsync = ref.watch(forumPostsProvider(channel.id));
    final canPost = channel.canPost;
    final isComposing = useState(startComposing && canPost);
    // A queued attachment can finish after this view is popped. Capture the
    // app-level provider container instead of retaining the route's WidgetRef.
    final providerContainer = ProviderScope.containerOf(context, listen: false);
    final forumDelivery = ForumEventDelivery.capture(providerContainer);

    // Periodic refresh (every 15s, matching desktop).
    useEffect(() {
      final timer = Stream.periodic(const Duration(seconds: 15)).listen((_) {
        ref.invalidate(forumPostsProvider(channel.id));
      });
      return timer.cancel;
    }, [channel.id]);

    // People writing without naming a post: a new post, or an agent harness
    // that does not yet tag the post it is replying to.
    final channelWorkingKey = ref.watch(
      channelTypingProvider(channel.id).select(
        (entries) => forumTypingPubkeys(
          entries,
          threadHeadId: null,
          currentPubkey: currentPubkey,
        ).join(','),
      ),
    );
    final channelWorkingPubkeys = channelWorkingKey.isEmpty
        ? const <String>[]
        : channelWorkingKey.split(',');
    final headerCount = channelWorkingPubkeys.isEmpty ? 0 : 1;
    final channelWorking = channelWorkingPubkeys.isEmpty
        ? null
        : ForumWorkingIndicator(
            key: const ValueKey('forum-channel-working'),
            channelId: channel.id,
            pubkeys: channelWorkingPubkeys,
            scope: ForumWorkingScope.forum,
          );

    return Column(
      children: [
        Expanded(
          child: Scaffold(
            // Transparent so the parent Scaffold's background shows through.
            backgroundColor: Colors.transparent,
            floatingActionButton: canPost && !isComposing.value
                ? FloatingActionButton(
                    heroTag: 'forum-fab',
                    onPressed: () => isComposing.value = true,
                    tooltip: 'New post',
                    shape: const CircleBorder(),
                    child: const Icon(LucideIcons.plus),
                  )
                : null,
            body: postsAsync.when(
              loading: () => Padding(
                padding: EdgeInsets.only(top: frostedAppBarHeight(context)),
                child: const Center(
                  child: BuzzLoadingIndicator(
                    size: 44,
                    semanticLabel: 'Loading posts',
                  ),
                ),
              ),
              error: (e, _) => Padding(
                padding: EdgeInsets.only(top: frostedAppBarHeight(context)),
                child: Center(
                  child: Text(
                    'Failed to load posts',
                    style: context.textTheme.bodyMedium?.copyWith(
                      color: context.colors.error,
                    ),
                  ),
                ),
              ),
              data: (response) {
                final posts = response.posts;
                if (posts.isEmpty) {
                  final empty = _EmptyState(
                    isMember: channel.isMember,
                    isArchived: channel.isArchived,
                  );
                  // Someone may be writing the first post.
                  if (channelWorking == null) return empty;
                  return Column(
                    children: [
                      Padding(
                        padding: EdgeInsets.only(
                          top: frostedAppBarHeight(context),
                          left: Grid.gutter,
                          right: Grid.gutter,
                        ),
                        child: channelWorking,
                      ),
                      Expanded(child: empty),
                    ],
                  );
                }
                return BeeRefreshIndicator(
                  onRefresh: () async {
                    ref.invalidate(forumPostsProvider(channel.id));
                    await ref.read(forumPostsProvider(channel.id).future);
                  },
                  child: ListView.separated(
                    padding: EdgeInsets.only(
                      top: frostedAppBarHeight(context),
                      left: Grid.gutter,
                      right: Grid.gutter,
                      bottom: Grid.xs,
                    ),
                    itemCount: posts.length + headerCount,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: Grid.xxs),
                    itemBuilder: (context, index) {
                      if (channelWorking != null && index < headerCount) {
                        return channelWorking;
                      }
                      final post = posts[index - headerCount];
                      return ForumPostCard(
                        key: ValueKey(post.eventId),
                        post: post,
                        currentPubkey: currentPubkey,
                        isArchived: channel.isArchived,
                        onTap: () => _openThread(context, post),
                        onDelete: (eventId, {required asModerator}) async {
                          final messenger = ScaffoldMessenger.maybeOf(context);
                          try {
                            await deleteForumEvent(
                              ref,
                              channelId: channel.id,
                              eventId: eventId,
                              asModerator: asModerator,
                            );
                          } catch (error) {
                            messenger?.showSnackBar(
                              SnackBar(
                                content: Text('Failed to delete post: $error'),
                              ),
                            );
                          }
                        },
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ),
        if (isComposing.value) ...[
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(right: Grid.xxs),
              child: IconButton(
                onPressed: () => isComposing.value = false,
                icon: const Icon(LucideIcons.x, size: 18),
                tooltip: 'Dismiss',
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
          ComposeBar(
            channelId: channel.id,
            hintText: 'Write your post\u2026',
            onSend:
                (
                  content,
                  mentionPubkeys, {
                  mediaTags = const <List<String>>[],
                }) async {
                  await forumDelivery.createPost(
                    channelId: channel.id,
                    content: content,
                    mentionPubkeys: mentionPubkeys,
                    mediaTags: mediaTags,
                  );
                  if (context.mounted) isComposing.value = false;
                },
          ),
        ],
      ],
    );
  }

  void _openThread(BuildContext context, ForumPost post) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ForumThreadPage(
          channelId: channel.id,
          postEventId: post.eventId,
          currentPubkey: currentPubkey,
          isMember: channel.isMember,
          isArchived: channel.isArchived,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final bool isMember;
  final bool isArchived;

  const _EmptyState({required this.isMember, required this.isArchived});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Grid.sm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              LucideIcons.messageSquareText,
              size: Grid.xl,
              color: context.colors.onSurfaceVariant,
            ),
            const SizedBox(height: Grid.xxs),
            Text(
              'No posts yet',
              style: context.textTheme.bodyLarge?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: Grid.half),
            Text(
              isArchived
                  ? 'This forum is archived.'
                  : isMember
                  ? 'Start a discussion by creating the first post.'
                  : 'Join this forum to create posts.',
              style: context.textTheme.bodySmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
