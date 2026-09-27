/**
 * Orders forum posts or replies oldest first, so the newest sits at the
 * bottom next to the composer, as in a conversation.
 *
 * The relay returns forum events newest first. The sort is stable, so events
 * that share a `createdAt` second keep the relay's order.
 */
export function sortForumOldestFirst<T extends { createdAt: number }>(
  items: readonly T[],
): T[] {
  return [...items].sort((a, b) => a.createdAt - b.createdAt);
}
