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

test("a reply newer than the post's own read marker is unread", () => {
  assert.equal(
    hasUnreadForumReplies({
      lastReplyAt: 200,
      threadReadAt: 100,
      channelBaselineAt: 300,
    }),
    true,
  );
});

test("the post's own read marker wins over the channel baseline", () => {
  assert.equal(
    hasUnreadForumReplies({
      lastReplyAt: 200,
      threadReadAt: 200,
      channelBaselineAt: 50,
    }),
    false,
  );
});

test("an unopened post falls back to the channel baseline", () => {
  assert.equal(
    hasUnreadForumReplies({
      lastReplyAt: 200,
      threadReadAt: null,
      channelBaselineAt: 150,
    }),
    true,
  );
  assert.equal(
    hasUnreadForumReplies({
      lastReplyAt: 100,
      threadReadAt: null,
      channelBaselineAt: 150,
    }),
    false,
  );
});

test("no baseline or no replies never flags a post", () => {
  assert.equal(
    hasUnreadForumReplies({
      lastReplyAt: 200,
      threadReadAt: null,
      channelBaselineAt: null,
    }),
    false,
  );
  assert.equal(
    hasUnreadForumReplies({
      lastReplyAt: null,
      threadReadAt: null,
      channelBaselineAt: 10,
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
