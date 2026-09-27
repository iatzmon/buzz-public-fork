import '../channels/channel_typing_provider.dart';
import 'forum_models.dart';

/// Pubkeys of other people typing in one forum scope, lowercased, deduped,
/// and sorted so the rendered order does not shuffle as indicators refresh.
///
/// [threadHeadId] selects a post's thread; `null` selects channel-level
/// entries (a new post, or an agent harness that does not tag the post).
List<String> forumTypingPubkeys(
  List<TypingEntry> entries, {
  required String? threadHeadId,
  required String? currentPubkey,
}) {
  final self = currentPubkey?.toLowerCase();
  final pubkeys = <String>{
    for (final entry in entries)
      if (entry.threadHeadId == threadHeadId &&
          entry.pubkey.toLowerCase() != self)
        entry.pubkey.toLowerCase(),
  };
  return pubkeys.toList()..sort();
}

/// Whether a post card should flag replies newer than the reader has seen.
///
/// The baseline is the post's own `thread:<postId>` read marker when one
/// exists; otherwise the forum channel's read marker as captured when the
/// post list opened. With neither marker there is nothing to compare, so no
/// post is flagged. All timestamps are Unix seconds.
bool forumPostHasNewReplies({
  required ForumThreadSummary? summary,
  required int? threadReadAt,
  required int? channelReadSnapshot,
}) {
  final lastReplyAt = summary?.lastReplyAt;
  if (summary == null || summary.replyCount <= 0 || lastReplyAt == null) {
    return false;
  }
  final baseline = threadReadAt ?? channelReadSnapshot;
  return baseline != null && lastReplyAt > baseline;
}

/// The `thread:<postId>` read timestamp (Unix seconds) for an open thread.
///
/// Covers the post and every loaded reply. The relay stamps a summary's
/// `last_reply_at` with its own clock when the reply is stored, which can
/// land a second or more after the reply's signed `created_at`; marking
/// only at `created_at` would leave the card's new-reply dot lit after the
/// thread was read. The summary fetched with the thread
/// (`post.threadSummary`) and the post list's summary ([listedSummary]) are
/// therefore adopted too, each only when every direct reply it counts is
/// already loaded here — a newer summary must not mark an unseen reply read.
int forumThreadReadAt({
  required ForumPost post,
  required List<ThreadReply> replies,
  ForumThreadSummary? listedSummary,
}) {
  var readAt = post.createdAt;
  var directReplies = 0;
  for (final reply in replies) {
    if (reply.createdAt > readAt) readAt = reply.createdAt;
    if (reply.parentEventId == post.eventId) directReplies++;
  }
  for (final summary in [post.threadSummary, listedSummary]) {
    final lastReplyAt = summary?.lastReplyAt;
    if (lastReplyAt != null &&
        summary!.replyCount <= directReplies &&
        lastReplyAt > readAt) {
      readAt = lastReplyAt;
    }
  }
  return readAt;
}
