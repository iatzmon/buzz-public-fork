import { READ_STATE_HORIZON_SECONDS } from "@/features/channels/readState/readStateFormat";
import type { TypingIndicatorEntry } from "@/features/messages/useChannelTyping";
import type { ForumThreadResponse, ThreadSummary } from "@/shared/api/types";

export type ForumTypingGroups = {
  /** Typing pubkeys keyed by the forum post they are replying under. */
  byPostId: Map<string, string[]>;
  /** Typing pubkeys with no post reference (channel-level typing). */
  channelLevel: string[];
};

/**
 * Groups forum-channel typing entries by the post they belong to.
 *
 * A reply to a nested comment carries the post as its thread root, so the root
 * wins over the direct parent. Entries without any thread reference stay
 * channel-level: agents on an older harness still announce work on a new
 * top-level post that way.
 */
export function groupForumTypingByPost(
  entries: readonly TypingIndicatorEntry[],
): ForumTypingGroups {
  const byPostId = new Map<string, string[]>();
  const channelLevel: string[] = [];

  for (const entry of entries) {
    const postId = entry.threadRootId ?? entry.threadHeadId;
    if (!postId) {
      if (!channelLevel.includes(entry.pubkey)) {
        channelLevel.push(entry.pubkey);
      }
      continue;
    }

    const pubkeys = byPostId.get(postId) ?? [];
    if (!pubkeys.includes(entry.pubkey)) {
      pubkeys.push(entry.pubkey);
    }
    byPostId.set(postId, pubkeys);
  }

  return { byPostId, channelLevel };
}

/**
 * Whether a forum post has replies newer than the viewer last read.
 *
 * `threadReadAt` is the post's own `thread:<postId>` read marker, set when the
 * viewer opens the post. A post without one stays flagged until it is opened:
 * leaving and re-opening the forum does not clear it. Only replies newer than
 * the read-state horizon count: post read markers older than it are dropped,
 * so a missing marker cannot mean "never opened" past it.
 */
export function hasUnreadForumReplies({
  lastReplyAt,
  threadReadAt,
  nowSeconds,
}: {
  lastReplyAt: number | null | undefined;
  threadReadAt: number | null;
  nowSeconds: number;
}): boolean {
  if (lastReplyAt === null || lastReplyAt === undefined) {
    return false;
  }

  const baseline = threadReadAt ?? nowSeconds - READ_STATE_HORIZON_SECONDS;
  return lastReplyAt > baseline;
}

/**
 * Newest activity time (unix seconds) the viewer has seen in an open post: the
 * post itself and every loaded reply.
 *
 * A reply summary's `lastReplyAt` counts too, but only when every reply it
 * covers is loaded. The relay stamps `lastReplyAt` with its own clock when it
 * stores a reply, which can be a second or more after the reply's
 * `createdAt`; without it, the post can stay marked after it was read. With
 * replies still unloaded, trusting it would mark unseen replies read.
 */
export function latestForumThreadActivityAt(
  thread: Pick<ForumThreadResponse, "post" | "replies">,
  listSummary: Pick<ThreadSummary, "lastReplyAt" | "replyCount"> | null,
): number {
  let latest = thread.post.createdAt;
  for (const reply of thread.replies) {
    if (reply.createdAt > latest) {
      latest = reply.createdAt;
    }
  }

  const loadedDirectReplies = thread.replies.filter(
    (reply) => reply.parentEventId === thread.post.eventId,
  ).length;
  for (const summary of [thread.post.threadSummary, listSummary]) {
    if (
      summary?.lastReplyAt !== null &&
      summary?.lastReplyAt !== undefined &&
      summary.replyCount <= loadedDirectReplies &&
      summary.lastReplyAt > latest
    ) {
      latest = summary.lastReplyAt;
    }
  }
  return latest;
}
