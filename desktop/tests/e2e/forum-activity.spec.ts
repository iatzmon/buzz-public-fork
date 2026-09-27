import { expect, test, type Page } from "@playwright/test";

import { waitForAnimations } from "../helpers/animations";
import { installMockBridge } from "../helpers/bridge";

// Forum post list activity: an agent working on a reply shows on the post it
// is replying under, and replies mark the post until the viewer opens it.

const FORUM = "watercooler";
const FORUM_CHANNEL_ID = "a27e1ee9-76a6-5bdf-a5d5-1d85610dad11";
const RELEASE_POST = "mock-forum-release-thread";
const OFFSITE_POST = "mock-forum-offsite-thread";
const TYPING_KIND = 20002;
const READ_STATE_KIND = 30078;
const AGENT_PUBKEY =
  "953d3363262e86b770419834c53d2446409db6d918a57f8f339d495d54ab001f";

async function waitForMockLiveSubscription(
  page: Page,
  channelName: string,
  kind: number,
) {
  // The forum opens several live subscriptions at once; the typing REQ can
  // wait its turn in the client's send queue for a few seconds.
  await expect
    .poll(
      () =>
        page.evaluate(
          ({ channelName, kind }) =>
            window.__BUZZ_E2E_HAS_MOCK_LIVE_SUBSCRIPTION__?.({
              channelName,
              kind,
            }) ?? false,
          { channelName, kind },
        ),
      { timeout: 15_000 },
    )
    .toBe(true);
}

async function emitTyping(page: Page, pubkey: string, threadHeadId?: string) {
  await page.evaluate(
    ({ channelName, pubkey, threadHeadId }) =>
      window.__BUZZ_E2E_EMIT_MOCK_TYPING__?.({
        channelName,
        pubkey,
        threadHeadId,
      }),
    { channelName: FORUM, pubkey, threadHeadId },
  );
}

async function openForum(page: Page) {
  await page.getByTestId(`channel-${FORUM}`).click();
  await expect(
    page.getByTestId(`forum-post-card-${RELEASE_POST}`),
  ).toBeVisible();
}

test.beforeEach(async ({ page }) => {
  await installMockBridge(page);
});

test("shows an agent working on a reply on that post's card", async ({
  page,
}) => {
  await page.goto("/");
  await openForum(page);
  await waitForMockLiveSubscription(page, FORUM, TYPING_KIND);

  await emitTyping(page, AGENT_PUBKEY, OFFSITE_POST);

  const offsiteCard = page.getByTestId(`forum-post-card-${OFFSITE_POST}`);
  const releaseCard = page.getByTestId(`forum-post-card-${RELEASE_POST}`);
  await expect(
    offsiteCard.getByTestId("message-typing-indicator-label"),
  ).toContainText("typing");
  await expect(releaseCard.getByTestId("message-typing-indicator")).toHaveCount(
    0,
  );

  await waitForAnimations(page);
  await offsiteCard.screenshot({
    path: "test-results/forum-activity/01-card-working.png",
  });
});

test("shows channel-level agent work below the post list", async ({ page }) => {
  await page.goto("/");
  await openForum(page);
  await waitForMockLiveSubscription(page, FORUM, TYPING_KIND);

  await emitTyping(page, AGENT_PUBKEY);

  const forumSection = page.getByRole("region", { name: "Forum posts" });
  const typingRows = forumSection.getByTestId("message-typing-indicator");
  await expect(typingRows).toHaveCount(1);
  await expect(
    page
      .getByTestId(`forum-post-card-${RELEASE_POST}`)
      .getByTestId("message-typing-indicator"),
  ).toHaveCount(0);
  await expect(
    page
      .getByTestId(`forum-post-card-${OFFSITE_POST}`)
      .getByTestId("message-typing-indicator"),
  ).toHaveCount(0);
});

test("marks a post with replies until it is opened, across forum visits", async ({
  page,
}) => {
  await page.goto("/");
  await waitForMockLiveSubscription(page, "general", READ_STATE_KIND);
  // The read-state store drops live markers until its startup load settles
  // (same settle wait as badge.spec.ts).
  await page.waitForTimeout(3000);

  // The viewer read the forum channel just now, after every reply. That
  // marker does not clear posts the viewer never opened.
  await page.evaluate(
    ({ channelId, ts }) =>
      window.__BUZZ_E2E_EMIT_MOCK_READ_STATE__?.({
        clientId: "other-device-client-id",
        slotId: "e2e00000000000000000000000000000",
        contexts: { [channelId]: ts },
        createdAt: ts,
      }),
    { channelId: FORUM_CHANNEL_ID, ts: Math.floor(Date.now() / 1000) },
  );

  await openForum(page);

  const releaseDot = page
    .getByTestId(`forum-post-card-${RELEASE_POST}`)
    .getByTestId("forum-post-unread-dot");
  const offsiteDot = page
    .getByTestId(`forum-post-card-${OFFSITE_POST}`)
    .getByTestId("forum-post-unread-dot");
  await expect(releaseDot).toBeVisible();
  await expect(offsiteDot).toHaveCount(0);

  await waitForAnimations(page);
  await page.getByTestId(`forum-post-card-${RELEASE_POST}`).screenshot({
    path: "test-results/forum-activity/02-card-new-replies.png",
  });

  // Leave the forum and come back without opening the post.
  await page.getByTestId("channel-general").click();
  await expect(page.getByTestId(`forum-post-card-${RELEASE_POST}`)).toHaveCount(
    0,
  );
  await openForum(page);
  await expect(releaseDot).toBeVisible();

  await page.getByTestId(`forum-post-card-${RELEASE_POST}`).click();
  await expect(
    page.locator(`[data-forum-event-id="${RELEASE_POST}"]`),
  ).toBeVisible();
  await page.getByRole("button", { name: "Back to posts" }).click();

  await expect(
    page.getByTestId(`forum-post-card-${RELEASE_POST}`),
  ).toBeVisible();
  await expect(releaseDot).toHaveCount(0);
});
