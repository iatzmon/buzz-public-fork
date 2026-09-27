import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../shared/mentions/agent_identity_provider.dart';
import '../../shared/read_state/read_state_format.dart';
import '../../shared/read_state/read_state_provider.dart';
import '../../shared/theme/theme.dart';
import '../../shared/widgets/avatar_image.dart';
import '../../shared/widgets/modal_presentation.dart';
import '../channels/channel_typing_provider.dart';
import '../channels/message_content.dart';
import '../../shared/profile/user_cache_provider.dart';
import '../../shared/utils/string_utils.dart';
import '../profile/user_profile_sheet.dart';
import '../../shared/profile/user_profile.dart';
import 'forum_activity.dart';
import 'forum_models.dart';
import 'forum_provider.dart';
import 'forum_working_indicator.dart';

/// Card displaying a forum post preview in the posts list.
///
/// Long-press opens an action sheet (copy, delete) matching the stream
/// message pattern from channel_detail_page.dart. Delete is offered on the
/// viewer's own posts and, for community or forum owners/admins, on everyone
/// else's; [onDelete] receives `asModerator: true` for the latter.
///
/// The card flags replies newer than the reader has seen (see
/// [forumPostHasNewReplies]) and shows who is currently writing a reply.
class ForumPostCard extends HookConsumerWidget {
  final ForumPost post;
  final String? currentPubkey;
  final VoidCallback onTap;
  final void Function(String eventId, {required bool asModerator})? onDelete;

  /// The forum channel's read marker (Unix seconds) captured once when the
  /// post list opened; the new-reply baseline for posts never opened.
  final int? channelReadSnapshot;

  const ForumPostCard({
    super.key,
    required this.post,
    required this.currentPubkey,
    required this.onTap,
    this.onDelete,
    this.channelReadSnapshot,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mentionPubkeys = useMemoized(
      () =>
          post.mentionPubkeys.map((pubkey) => pubkey.toLowerCase()).toSet()
            ..remove(post.pubkey.toLowerCase()),
      [post],
    );
    final mentionPubkeysKey = (mentionPubkeys.toList()..sort()).join('\u0000');

    useEffect(() {
      if (mentionPubkeys.isNotEmpty) {
        ref.read(userCacheProvider.notifier).preload(mentionPubkeys.toList());
      }
      return null;
    }, [mentionPubkeysKey]);

    final pk = post.pubkey.toLowerCase();
    final profile =
        ref.watch(userCacheProvider.select((cache) => cache[pk])) ??
        ref.read(userCacheProvider.notifier).get(pk);
    final displayName = profile?.label ?? shortPubkey(post.pubkey);
    final isAgent =
        ref.watch(agentMentionPubkeysProvider(post.channelId)).contains(pk) ||
        profile?.ownerPubkey != null;
    final profileMentionNames = ref.watch(
      userCacheProvider.select(
        (cache) => _buildMentionNames(post.mentionPubkeys, cache),
      ),
    );
    final profileOwnedMentionPubkeys = ref.watch(
      userCacheProvider.select(
        (cache) =>
            (post.mentionPubkeys
                    .where(
                      (pubkey) =>
                          cache[pubkey.toLowerCase()]?.ownerPubkey != null,
                    )
                    .map((pubkey) => pubkey.toLowerCase())
                    .toList()
                  ..sort())
                .join('\u0000'),
      ),
    );
    final agentMentionPubkeys = agentPubkeysWithProfileOwners(
      knownAgentPubkeys: ref.watch(agentMentionPubkeysProvider(post.channelId)),
      profileOwnedAgentPubkeys: profileOwnedMentionPubkeys.isEmpty
          ? const <String>[]
          : profileOwnedMentionPubkeys.split('\u0000'),
    );
    final mentionNames = mentionNamesWithDirectoryLabels(
      mentionPubkeys: post.mentionPubkeys,
      profileMentionNames: profileMentionNames,
      directoryDisplayNames: ref.watch(agentDirectoryDisplayNamesProvider),
      agentMentionPubkeys: agentMentionPubkeys,
    );
    final preview = post.content.length > 200
        ? '${post.content.substring(0, 200)}...'
        : post.content;
    final summary = post.threadSummary;
    final threadReadAt = ref.watch(
      readStateProvider.select(
        (state) => state.effectiveTimestamp(threadContextKey(post.eventId)),
      ),
    );
    final hasNewReplies = forumPostHasNewReplies(
      summary: summary,
      threadReadAt: threadReadAt,
      channelReadSnapshot: channelReadSnapshot,
    );
    // Joined so unrelated typing churn does not rebuild every card.
    final workingKey = ref.watch(
      channelTypingProvider(post.channelId).select(
        (entries) => forumTypingPubkeys(
          entries,
          threadHeadId: post.eventId,
          currentPubkey: currentPubkey,
        ).join(','),
      ),
    );
    final workingPubkeys = workingKey.isEmpty
        ? const <String>[]
        : workingKey.split(',');
    final canModerate = ref.watch(canModerateForumProvider(post.channelId));

    return GestureDetector(
      onTap: onTap,
      onLongPress: () => _showActions(context, canModerate: canModerate),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(Grid.twelve),
        decoration: BoxDecoration(
          color: context.colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(Radii.lg),
          border: Border.all(
            color: context.colors.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Author row
            Row(
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => showUserProfileSheet(context, post.pubkey),
                  child: _PostAvatar(
                    profile: profile,
                    pubkey: post.pubkey,
                    isAgent: isAgent,
                  ),
                ),
                const SizedBox(width: Grid.xxs),
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
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
                const SizedBox(width: Grid.half),
                SizedBox(
                  width: 24,
                  height: 24,
                  child: IconButton(
                    onPressed: () =>
                        _showActions(context, canModerate: canModerate),
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
            const SizedBox(height: Grid.xxs),

            ShaderMask(
              shaderCallback: (bounds) => const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.white, Colors.white, Colors.transparent],
                stops: [0.0, 0.75, 1.0],
              ).createShader(bounds),
              blendMode: BlendMode.dstIn,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 120),
                child: IgnorePointer(
                  child: MessageContent(
                    content: preview,
                    mentionNames: mentionNames,
                    agentMentionPubkeys: agentMentionPubkeys,
                    tags: post.tags,
                    baseStyle: messageBodyTextStyle.copyWith(
                      color: context.colors.onSurface,
                    ),
                  ),
                ),
              ),
            ),

            // Thread summary
            if (summary != null && summary.replyCount > 0) ...[
              const SizedBox(height: Grid.xxs),
              _ReplySummary(summary: summary, hasNewReplies: hasNewReplies),
            ],
            if (workingPubkeys.isNotEmpty) ...[
              const SizedBox(height: Grid.xxs),
              ForumWorkingIndicator(
                key: ValueKey('forum-post-working-${post.eventId}'),
                channelId: post.channelId,
                pubkeys: workingPubkeys,
                scope: ForumWorkingScope.reply,
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _showActions(BuildContext context, {required bool canModerate}) {
    final isOwn =
        currentPubkey != null &&
        post.pubkey.toLowerCase() == currentPubkey!.toLowerCase();
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
                    Clipboard.setData(ClipboardData(text: post.content));
                  },
                ),
                if ((isOwn || asModerator) && onDelete != null)
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
                      _confirmDelete(context, asModerator: asModerator);
                    },
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _confirmDelete(BuildContext context, {required bool asModerator}) {
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
            onPressed: () {
              Navigator.of(dialogContext).pop();
              onDelete?.call(post.eventId, asModerator: asModerator);
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

/// "N replies · last 5m ago", emphasized with a dot when replies are new.
///
/// One screen-reader stop: the label carries the count, recency, and the
/// "new replies" flag; the dot and icon are decorative.
class _ReplySummary extends StatelessWidget {
  final ForumThreadSummary summary;
  final bool hasNewReplies;

  const _ReplySummary({required this.summary, required this.hasNewReplies});

  @override
  Widget build(BuildContext context) {
    final countText =
        '${summary.replyCount} ${summary.replyCount == 1 ? 'reply' : 'replies'}';
    final lastReplyAt = summary.lastReplyAt;
    final lastText = lastReplyAt == null
        ? null
        : 'last ${formatRelativeTime(lastReplyAt)}';
    final textColor = hasNewReplies
        ? context.colors.onSurface
        : context.colors.onSurfaceVariant;
    final textStyle = context.textTheme.labelSmall?.copyWith(
      color: textColor,
      fontWeight: hasNewReplies ? FontWeight.w700 : null,
    );

    return Semantics(
      container: true,
      label: [
        countText,
        ?lastText,
        if (hasNewReplies) 'new replies',
      ].join(', '),
      excludeSemantics: true,
      child: Row(
        children: [
          if (hasNewReplies) ...[
            Container(
              key: const ValueKey('forum-post-new-replies-dot'),
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: context.colors.primary,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: Grid.half),
          ],
          Icon(
            LucideIcons.messageSquare,
            size: 14,
            color: hasNewReplies
                ? context.colors.primary
                : context.colors.onSurfaceVariant,
          ),
          const SizedBox(width: Grid.half),
          Text(countText, style: textStyle),
          if (lastText != null) ...[
            const SizedBox(width: Grid.half),
            Text(
              '\u00b7',
              style: context.textTheme.labelSmall?.copyWith(
                color: context.colors.onSurfaceVariant.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(width: Grid.half),
            Text(lastText, style: textStyle),
          ],
        ],
      ),
    );
  }
}

class _PostAvatar extends StatelessWidget {
  final UserProfile? profile;
  final String pubkey;
  final bool isAgent;

  const _PostAvatar({
    required this.profile,
    required this.pubkey,
    required this.isAgent,
  });

  @override
  Widget build(BuildContext context) {
    final initial =
        profile?.initial ?? (pubkey.isNotEmpty ? pubkey[0].toUpperCase() : '?');
    final avatarUrl = profile?.avatarUrl;

    return AvatarImage(
      imageUrl: avatarUrl,
      radius: 14,
      backgroundColor: context.colors.primaryContainer,
      fallback: Text(
        initial,
        style: context.textTheme.labelSmall?.copyWith(
          color: context.colors.onPrimaryContainer,
          fontWeight: FontWeight.w600,
        ),
      ),
      isAgent: isAgent,
    );
  }
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
