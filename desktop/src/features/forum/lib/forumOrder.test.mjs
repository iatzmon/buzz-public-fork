import assert from "node:assert/strict";
import { test } from "node:test";

import { sortForumOldestFirst } from "./forumOrder.ts";

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
