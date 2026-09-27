import assert from "node:assert/strict";
import { test } from "node:test";

import {
  sortForumOldestFirst,
  sortForumPostsByActivity,
} from "./forumOrder.ts";

test("relay newest-first events render oldest first", () => {
  const relayOrder = [
    { eventId: "newest", createdAt: 300 },
    { eventId: "middle", createdAt: 200 },
    { eventId: "oldest", createdAt: 100 },
  ];

  assert.deepEqual(
    sortForumOldestFirst(relayOrder).map((item) => item.eventId),
    ["oldest", "middle", "newest"],
  );
});

test("events in the same second keep the relay order", () => {
  const relayOrder = [
    { eventId: "later", createdAt: 200 },
    { eventId: "same-a", createdAt: 100 },
    { eventId: "same-b", createdAt: 100 },
  ];

  assert.deepEqual(
    sortForumOldestFirst(relayOrder).map((item) => item.eventId),
    ["same-a", "same-b", "later"],
  );
});

test("the input array is not changed", () => {
  const relayOrder = [
    { eventId: "newest", createdAt: 200 },
    { eventId: "oldest", createdAt: 100 },
  ];

  sortForumOldestFirst(relayOrder);

  assert.deepEqual(
    relayOrder.map((item) => item.eventId),
    ["newest", "oldest"],
  );
});

test("posts order by their newest reply, the most recent first", () => {
  const relayOrder = [
    { eventId: "new-quiet", createdAt: 300, threadSummary: null },
    {
      eventId: "old-active",
      createdAt: 100,
      threadSummary: { lastReplyAt: 500 },
    },
    {
      eventId: "middle-replied",
      createdAt: 200,
      threadSummary: { lastReplyAt: 250 },
    },
  ];

  assert.deepEqual(
    sortForumPostsByActivity(relayOrder).map((post) => post.eventId),
    ["old-active", "new-quiet", "middle-replied"],
  );
});

test("equal activity falls back to the newer post, then event id", () => {
  const posts = [
    { eventId: "b", createdAt: 100, threadSummary: { lastReplyAt: 400 } },
    { eventId: "a", createdAt: 100, threadSummary: { lastReplyAt: 400 } },
    { eventId: "c", createdAt: 50, threadSummary: { lastReplyAt: 400 } },
  ];

  assert.deepEqual(
    sortForumPostsByActivity(posts).map((post) => post.eventId),
    ["a", "b", "c"],
  );
  assert.deepEqual(
    sortForumPostsByActivity([...posts].reverse()).map((post) => post.eventId),
    ["a", "b", "c"],
  );
});
