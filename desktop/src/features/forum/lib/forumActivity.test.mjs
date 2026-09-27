import assert from "node:assert/strict";
import { test } from "node:test";

import {
  groupForumTypingByPost,
  hasUnreadForumReplies,
  latestForumThreadActivityAt,
} from "./forumActivity.ts";

const POST = "a".repeat(64);
const OTHER_POST = "b".repeat(64);
const NESTED_REPLY = "c".repeat(64);

test("typing on a direct reply to a post groups under that post", () => {
  const groups = groupForumTypingByPost([
    { pubkey: "agent", threadHeadId: POST, threadRootId: POST },
  ]);
  assert.deepEqual(groups.byPostId.get(POST), ["agent"]);
  assert.deepEqual(groups.channelLevel, []);
});

test("typing on a nested reply groups under the thread root, not the parent", () => {
  const groups = groupForumTypingByPost([
    { pubkey: "agent", threadHeadId: NESTED_REPLY, threadRootId: POST },
  ]);
  assert.deepEqual(groups.byPostId.get(POST), ["agent"]);
  assert.equal(groups.byPostId.has(NESTED_REPLY), false);
});

test("typing without a thread reference stays channel-level", () => {
  const groups = groupForumTypingByPost([
    { pubkey: "agent", threadHeadId: null, threadRootId: null },
    { pubkey: "other", threadHeadId: OTHER_POST, threadRootId: OTHER_POST },
  ]);
  assert.deepEqual(groups.channelLevel, ["agent"]);
  assert.equal(groups.byPostId.has(POST), false);
  assert.deepEqual(groups.byPostId.get(OTHER_POST), ["other"]);
});

test("one agent typing in two scopes of the same post is listed once", () => {
  const groups = groupForumTypingByPost([
    { pubkey: "agent", threadHeadId: POST, threadRootId: POST },
    { pubkey: "agent", threadHeadId: NESTED_REPLY, threadRootId: POST },
  ]);
  assert.deepEqual(groups.byPostId.get(POST), ["agent"]);
});

const NOW = 1_790_539_200;
const WEEK = 7 * 24 * 60 * 60;

test("a reply newer than the post's own read marker is unread", () => {
  assert.equal(
    hasUnreadForumReplies({
      lastReplyAt: NOW - 100,
      threadReadAt: NOW - 200,
      nowSeconds: NOW,
    }),
    true,
  );
});

test("a reply the post's read marker covers is read", () => {
  assert.equal(
    hasUnreadForumReplies({
      lastReplyAt: NOW - 200,
      threadReadAt: NOW - 200,
      nowSeconds: NOW,
    }),
    false,
  );
});

test("an unopened post stays unread however often the forum is visited", () => {
  // No channel marker is consulted: only opening the post clears it.
  for (const nowSeconds of [NOW, NOW + 60, NOW + 3_600]) {
    assert.equal(
      hasUnreadForumReplies({
        lastReplyAt: NOW - 100,
        threadReadAt: null,
        nowSeconds,
      }),
      true,
    );
  }
});

test("an unopened post with only replies past the marker horizon is not flagged", () => {
  assert.equal(
    hasUnreadForumReplies({
      lastReplyAt: NOW - WEEK - 1,
      threadReadAt: null,
      nowSeconds: NOW,
    }),
    false,
  );
});

test("a post without replies is never flagged", () => {
  assert.equal(
    hasUnreadForumReplies({
      lastReplyAt: null,
      threadReadAt: null,
      nowSeconds: NOW,
    }),
    false,
  );
});

function thread({ postCreatedAt, summary = null, replies = [] }) {
  return {
    post: {
      eventId: POST,
      createdAt: postCreatedAt,
      threadSummary: summary,
    },
    replies: replies.map(({ createdAt, parentEventId = POST }) => ({
      createdAt,
      parentEventId,
    })),
  };
}

function summary(replyCount, lastReplyAt) {
  return {
    replyCount,
    descendantCount: replyCount,
    lastReplyAt,
    participants: [],
  };
}

test("latest thread activity takes the newest of the post and loaded replies", () => {
  assert.equal(
    latestForumThreadActivityAt(thread({ postCreatedAt: 10 }), null),
    10,
  );
  assert.equal(
    latestForumThreadActivityAt(
      thread({
        postCreatedAt: 10,
        replies: [{ createdAt: 20 }, { createdAt: 40 }, { createdAt: 30 }],
      }),
      null,
    ),
    40,
  );
});

test("a summary's relay-clock time counts when every direct reply is loaded", () => {
  // The relay stamps lastReplyAt when it stores the reply, after createdAt.
  assert.equal(
    latestForumThreadActivityAt(
      thread({ postCreatedAt: 10, replies: [{ createdAt: 20 }] }),
      summary(1, 22),
    ),
    22,
  );
  assert.equal(
    latestForumThreadActivityAt(
      thread({
        postCreatedAt: 10,
        replies: [{ createdAt: 20 }],
        summary: summary(1, 23),
      }),
      null,
    ),
    23,
  );
});

test("a summary covering unloaded replies does not advance the read time", () => {
  assert.equal(
    latestForumThreadActivityAt(
      thread({ postCreatedAt: 10, replies: [{ createdAt: 20 }] }),
      summary(2, 60),
    ),
    20,
  );
});

test("nested replies do not count toward the loaded direct replies", () => {
  assert.equal(
    latestForumThreadActivityAt(
      thread({
        postCreatedAt: 10,
        replies: [{ createdAt: 20, parentEventId: NESTED_REPLY }],
      }),
      summary(1, 60),
    ),
    20,
  );
});
