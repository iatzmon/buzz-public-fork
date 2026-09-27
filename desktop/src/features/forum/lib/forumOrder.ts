/**
 * Orders a post's replies oldest first, so the newest sits at the bottom
 * next to the reply composer, as in a conversation.
 *
 * The relay returns forum events newest first. The sort is stable, so events
 * that share a `createdAt` second keep the relay's order.
 */
export function sortForumOldestFirst<T extends { createdAt: number }>(
  items: readonly T[],
): T[] {
  return [...items].sort((a, b) => a.createdAt - b.createdAt);
}

/**
 * Latest activity on a forum post (unix seconds): its newest reply, or the
 * post itself when it has no replies.
 */
export function forumPostActivityAt(post: {
  createdAt: number;
  threadSummary?: { lastReplyAt?: number | null } | null;
}): number {
  return Math.max(post.createdAt, post.threadSummary?.lastReplyAt ?? 0);
}

/**
 * Orders forum posts by latest activity, newest first, so the post with the
 * newest reply sits at the top. Ties fall back to the newer post, then event
 * id, so refreshes do not shuffle the list.
 */
export function sortForumPostsByActivity<
  T extends {
    createdAt: number;
    eventId: string;
    threadSummary?: { lastReplyAt?: number | null } | null;
  },
>(posts: readonly T[]): T[] {
  return [...posts].sort(
    (a, b) =>
      forumPostActivityAt(b) - forumPostActivityAt(a) ||
      b.createdAt - a.createdAt ||
      (a.eventId < b.eventId ? -1 : a.eventId > b.eventId ? 1 : 0),
  );
}
