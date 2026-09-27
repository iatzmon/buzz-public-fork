import { expect, test, type Locator, type Page } from "@playwright/test";

import { installMockBridge } from "../helpers/bridge";

// Desktop forums read like a conversation: the post list (by latest reply)
// and a post's replies run oldest first, open at the bottom, and follow new
// entries there. The mock
// bridge returns posts and replies newest first, as the relay does.

const FORUM = "watercooler";
const RELEASE_POST = "mock-forum-release-thread";
const OFFSITE_POST = "mock-forum-offsite-thread";
const OLDEST_REPLY = "mock-forum-release-reply";
const NEWEST_REPLY = "mock-forum-release-deeplink";
const ALICE_PUBKEY =
  "953d3363262e86b770419834c53d2446409db6d918a57f8f339d495d54ab001f";
// The forum polls an open post every 10 seconds; a reply from someone else
// shows up on the next poll.
const THREAD_POLL_TIMEOUT_MS = 20_000;

function distanceFromBottom(scroll: Locator) {
  return scroll.evaluate(
    (el) => el.scrollHeight - el.clientHeight - el.scrollTop,
  );
}

async function expectPinnedToBottom(scroll: Locator) {
  await expect.poll(() => distanceFromBottom(scroll)).toBeLessThanOrEqual(2);
}

async function scrollToTop(scroll: Locator) {
  await scroll.hover();
  await scroll.evaluate((el) => {
    el.scrollTop = 0;
    el.dispatchEvent(new Event("scroll"));
  });
  await expect.poll(() => scroll.evaluate((el) => el.scrollTop)).toBe(0);
}

/** Adds older posts so the post list overflows its viewport. */
async function seedOlderPosts(page: Page, count: number) {
  await page.evaluate(
    ({ channelName, count }) => {
      const now = Math.floor(Date.now() / 1000);
      for (let index = 0; index < count; index += 1) {
        window.__BUZZ_E2E_EMIT_MOCK_MESSAGE__?.({
          channelName,
          content: `Older seeded post ${index + 1}.`,
          createdAt: now - (200 - index) * 60,
          kind: 45001,
        });
      }
    },
    { channelName: FORUM, count },
  );
}

async function emitIncomingReply(page: Page, content: string) {
  await page.evaluate(
    ({ channelName, content, parentEventId, pubkey }) =>
      window.__BUZZ_E2E_EMIT_MOCK_MESSAGE__?.({
        channelName,
        content,
        kind: 45003,
        parentEventId,
        pubkey,
      }),
    {
      channelName: FORUM,
      content,
      parentEventId: RELEASE_POST,
      pubkey: ALICE_PUBKEY,
    },
  );
}

async function openForum(page: Page, { olderPosts = 0 } = {}) {
  await page.goto("/");
  if (olderPosts > 0) {
    await expect(page.getByTestId(`channel-${FORUM}`)).toBeVisible();
    await seedOlderPosts(page, olderPosts);
  }
  await page.getByTestId(`channel-${FORUM}`).click();
  await expect(
    page.getByTestId(`forum-post-card-${RELEASE_POST}`),
  ).toBeVisible();
}

async function openReleasePost(page: Page) {
  await openForum(page);
  await page.getByTestId(`forum-post-card-${RELEASE_POST}`).click();
  await expect(
    page.locator(`[data-forum-event-id="${NEWEST_REPLY}"]`),
  ).toBeAttached();
}

async function submitForumComposer(page: Page, content: string) {
  const forum = page.getByRole("region", { name: "Forum posts" });
  const editor = forum.locator(".rich-text-composer [contenteditable='true']");
  await editor.click();
  await page.keyboard.type(content);
  await forum.getByTestId("send-message").click();
}

test.beforeEach(async ({ page }) => {
  await installMockBridge(page);
});

test("the post list runs by latest activity with the new-post box below it", async ({
  page,
}) => {
  await openForum(page, { olderPosts: 10 });

  const cards = page.locator('[data-testid^="forum-post-card-"]');
  await expect(cards).toHaveCount(12);
  const cardIds = await cards.evaluateAll((els) =>
    els.map((el) => el.getAttribute("data-testid")),
  );
  // The release post is older than the offsite post, but its newest reply is
  // newer than both, so it sits last.
  expect(cardIds.slice(-2)).toEqual([
    `forum-post-card-${OFFSITE_POST}`,
    `forum-post-card-${RELEASE_POST}`,
  ]);
  await expect(cards.first()).toContainText("Older seeded post 1.");

  // Twelve cards overflow the list, so being at the bottom is a real scroll.
  const list = page.getByTestId("forum-post-list");
  await expectPinnedToBottom(list);
  expect(await list.evaluate((el) => el.scrollTop)).toBeGreaterThan(0);

  const newest = await page
    .getByTestId(`forum-post-card-${RELEASE_POST}`)
    .boundingBox();
  const startPost = await page
    .getByRole("button", { name: "Start a new post..." })
    .boundingBox();
  if (!newest || !startPost) throw new Error("forum list not laid out");
  expect(startPost.y).toBeGreaterThan(newest.y + newest.height);
});

test("a new post lands last and the list follows it to the bottom", async ({
  page,
}) => {
  await openForum(page, { olderPosts: 10 });
  const list = page.getByTestId("forum-post-list");
  await expectPinnedToBottom(list);
  await scrollToTop(list);

  await page.getByRole("button", { name: "Start a new post..." }).click();
  await submitForumComposer(page, "Newest post goes at the bottom.");

  const cards = page.locator('[data-testid^="forum-post-card-"]');
  await expect(cards).toHaveCount(13);
  await expect(cards.last()).toContainText("Newest post goes at the bottom.");
  await expectPinnedToBottom(list);
  expect(await list.evaluate((el) => el.scrollTop)).toBeGreaterThan(0);
});

test("a new reply moves an older post to the bottom of the list", async ({
  page,
}) => {
  test.setTimeout(60_000);
  await openForum(page);
  const cards = page.locator('[data-testid^="forum-post-card-"]');
  await expect(cards.last()).toHaveAttribute(
    "data-testid",
    `forum-post-card-${RELEASE_POST}`,
  );

  await page.evaluate(
    ({ channelName, parentEventId, pubkey }) =>
      window.__BUZZ_E2E_EMIT_MOCK_MESSAGE__?.({
        channelName,
        content: "First reply on the offsite post.",
        kind: 45003,
        parentEventId,
        pubkey,
      }),
    { channelName: FORUM, parentEventId: OFFSITE_POST, pubkey: ALICE_PUBKEY },
  );

  await expect(cards.last()).toHaveAttribute(
    "data-testid",
    `forum-post-card-${OFFSITE_POST}`,
    { timeout: THREAD_POLL_TIMEOUT_MS },
  );
});

test("a post opens at its newest reply, with replies oldest first", async ({
  page,
}) => {
  await openReleasePost(page);

  const scroll = page.getByTestId("forum-thread-scroll");
  const replyIds = await scroll
    .locator("[data-forum-event-id]")
    .evaluateAll((els) => els.map((el) => el.dataset.forumEventId));
  expect(replyIds[0]).toBe(RELEASE_POST);
  expect(replyIds[1]).toBe(OLDEST_REPLY);
  expect(replyIds.at(-1)).toBe(NEWEST_REPLY);

  // 25 replies overflow the panel, so being at the bottom is a real scroll.
  expect(await scroll.evaluate((el) => el.scrollTop)).toBeGreaterThan(0);
  await expectPinnedToBottom(scroll);
  await expect(
    page.getByTestId("forum-thread-scroll-to-latest"),
  ).not.toBeVisible();
});

test("reading older replies shows Jump to latest, which returns to the bottom", async ({
  page,
}) => {
  await openReleasePost(page);
  const scroll = page.getByTestId("forum-thread-scroll");
  await expectPinnedToBottom(scroll);

  await scrollToTop(scroll);
  const jump = page.getByTestId("forum-thread-scroll-to-latest");
  await expect(jump).toHaveText("Jump to latest");

  await jump.click();
  await expectPinnedToBottom(scroll);
  await expect(jump).not.toBeVisible();
});

test("sending a reply from older replies scrolls to the new reply", async ({
  page,
}) => {
  await openReleasePost(page);
  const scroll = page.getByTestId("forum-thread-scroll");
  await expectPinnedToBottom(scroll);
  await scrollToTop(scroll);

  await submitForumComposer(page, "Fresh reply lands at the bottom.");

  const rows = scroll.locator("[data-forum-event-id]");
  await expect(rows.last()).toContainText("Fresh reply lands at the bottom.");
  await expectPinnedToBottom(scroll);
});

test("an incoming reply while pinned to the bottom follows it down", async ({
  page,
}) => {
  test.setTimeout(60_000);
  await openReleasePost(page);
  const scroll = page.getByTestId("forum-thread-scroll");
  await expectPinnedToBottom(scroll);

  await emitIncomingReply(page, "Incoming reply while at the bottom.");

  const rows = scroll.locator("[data-forum-event-id]");
  await expect(rows.last()).toContainText(
    "Incoming reply while at the bottom.",
    { timeout: THREAD_POLL_TIMEOUT_MS },
  );
  await expectPinnedToBottom(scroll);
  await expect(
    page.getByTestId("forum-thread-scroll-to-latest"),
  ).not.toBeVisible();
});

test("an incoming reply while reading older replies keeps the place", async ({
  page,
}) => {
  test.setTimeout(60_000);
  await openReleasePost(page);
  const scroll = page.getByTestId("forum-thread-scroll");
  await expectPinnedToBottom(scroll);
  await scrollToTop(scroll);
  const oldest = scroll.locator(`[data-forum-event-id="${OLDEST_REPLY}"]`);
  const topBefore = await oldest.evaluate(
    (el) => el.getBoundingClientRect().top,
  );

  await emitIncomingReply(page, "Incoming reply while reading older ones.");

  await expect(page.getByTestId("forum-thread-scroll-to-latest")).toHaveText(
    "1 new message",
    { timeout: THREAD_POLL_TIMEOUT_MS },
  );
  expect(await scroll.evaluate((el) => el.scrollTop)).toBe(0);
  expect(
    await oldest.evaluate((el) => el.getBoundingClientRect().top),
  ).toBeCloseTo(topBefore, 0);
  await expect(scroll.locator("[data-forum-event-id]").last()).toContainText(
    "Incoming reply while reading older ones.",
  );
});

test("a reply deep link opens at that reply, not at the bottom", async ({
  page,
}) => {
  await page.goto(
    `/#/channels/a27e1ee9-76a6-5bdf-a5d5-1d85610dad11/posts/${RELEASE_POST}?replyId=${OLDEST_REPLY}`,
  );

  const target = page.locator(`[data-forum-event-id="${OLDEST_REPLY}"]`);
  await expect(target).toBeVisible();
  await expect
    .poll(() =>
      target.evaluate((el) => {
        const rect = el.getBoundingClientRect();
        return rect.top >= 0 && rect.bottom <= window.innerHeight;
      }),
    )
    .toBe(true);
  expect(
    await distanceFromBottom(page.getByTestId("forum-thread-scroll")),
  ).toBeGreaterThan(2);
});
