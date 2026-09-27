/**
 * Community/channel owners and admins get the existing "Delete" action (and
 * its existing confirmation) on other people's messages, sent as the NIP-29
 * kind:9005 moderator delete (`asModerator: true`). Edit stays on the author
 * rule: a moderator never sees Edit on someone else's message. The viewer's
 * own messages keep the author's kind:5 path.
 *
 * Fixtures: in #random and #watercooler the mock identity is a plain channel
 * member (alice owns both), so only `mock.relayRole` decides moderator
 * standing there. In #agents the identity owns the channel, isolating the
 * channel-role path.
 *
 * Run: pnpm test:e2e:smoke -- tests/e2e/moderator-message-delete.spec.ts
 */
import { expect, type Page, test } from "@playwright/test";

import { installMockBridge, TEST_IDENTITIES } from "../helpers/bridge";

const RANDOM_CHANNEL_ID = "9dae0116-799b-5071-a0a8-fdd30a91a35d";
const AGENTS_CHANNEL_ID = "94a444a4-c0a3-5966-ab05-530c6ddc2301";
const WATERCOOLER_CHANNEL_ID = "a27e1ee9-76a6-5bdf-a5d5-1d85610dad11";
const CURRENT_PUBKEY = "deadbeef".repeat(8);
const BOB_ROOT_ID = "b0".repeat(32);
const BOB_REPLY_ID = "b1".repeat(32);
const OWN_MESSAGE_ID = "d0".repeat(32);
const INBOX_FOREIGN_ID = "e0".repeat(32);

type RelayRole = "owner" | "admin" | "member";

type MockWindow = Window & {
  __BUZZ_E2E_COMMAND_PAYLOADS__?: Array<{ command: string; payload: unknown }>;
  __BUZZ_E2E_EMIT_MOCK_MESSAGE__?: (input: {
    channelName: string;
    content: string;
    createdAt?: number;
    id?: string;
    parentEventId?: string | null;
    pubkey?: string;
  }) => unknown;
  __BUZZ_E2E_PUSH_MOCK_FEED_ITEM__?: (item: Record<string, unknown>) => void;
};

async function openApp(page: Page, relayRole: RelayRole) {
  // The community role is read from the NIP-43 membership snapshot, which the
  // desktop only consults when the relay enforces membership.
  await installMockBridge(page, { relayRequiresMembership: true, relayRole });
  await page.goto("/");
  await page.waitForFunction(() => {
    const win = window as MockWindow;
    return (
      typeof win.__BUZZ_E2E_EMIT_MOCK_MESSAGE__ === "function" &&
      typeof win.__BUZZ_E2E_PUSH_MOCK_FEED_ITEM__ === "function"
    );
  });
}

/**
 * Seed an own message, Bob's root + thread reply, then two later Alice
 * messages into #random's history. The trailing messages keep the rows under
 * test clear of the composer overlay at the bottom of the timeline.
 */
async function seedRandomMessages(page: Page) {
  await page.evaluate(
    ({ alice, bob, bobRootId, bobReplyId, currentPubkey, ownId }) => {
      const emit = (window as MockWindow).__BUZZ_E2E_EMIT_MOCK_MESSAGE__;
      if (!emit) throw new Error("Mock emit helper is not installed.");
      const now = Math.floor(Date.now() / 1_000);
      emit({
        channelName: "random",
        content: "My own message in random.",
        createdAt: now - 300,
        id: ownId,
        pubkey: currentPubkey,
      });
      emit({
        channelName: "random",
        content: "Bob's message for moderation.",
        createdAt: now - 240,
        id: bobRootId,
        pubkey: bob,
      });
      emit({
        channelName: "random",
        content: "Bob's thread reply for moderation.",
        createdAt: now - 230,
        id: bobReplyId,
        parentEventId: bobRootId,
        pubkey: bob,
      });
      for (const [index, offset] of [120, 60].entries()) {
        emit({
          channelName: "random",
          content: `Alice follow-up ${index + 1}.`,
          createdAt: now - offset,
          pubkey: alice,
        });
      }
    },
    {
      alice: TEST_IDENTITIES.alice.pubkey,
      bob: TEST_IDENTITIES.bob.pubkey,
      bobRootId: BOB_ROOT_ID,
      bobReplyId: BOB_REPLY_ID,
      currentPubkey: CURRENT_PUBKEY,
      ownId: OWN_MESSAGE_ID,
    },
  );
}

async function openChannel(page: Page, name: string) {
  await page.getByTestId(`channel-${name}`).click();
  await expect(page.getByTestId("chat-title")).toHaveText(name);
}

/** Open a row's More-actions menu, scoped to `scope` (timeline or thread). */
async function openMoreActions(
  page: Page,
  scope: ReturnType<Page["locator"]>,
  messageId: string,
) {
  const row = scope.locator(`[data-message-id="${messageId}"]`).first();
  await expect(row).toBeVisible();
  await row.hover();
  await scope.getByTestId(`more-actions-${messageId}`).first().click();
  await expect(page.getByRole("menu")).toBeVisible();
}

async function closeMenu(page: Page) {
  await page.keyboard.press("Escape");
  await expect(page.getByRole("menu")).toHaveCount(0);
}

async function confirmMessageDelete(page: Page) {
  const dialog = page.getByRole("alertdialog");
  await expect(dialog).toContainText("Delete message?");
  await dialog.getByRole("button", { name: "Delete" }).click();
  await expect(dialog).toBeHidden();
}

async function deletePayloads(page: Page) {
  return page.evaluate(() =>
    ((window as MockWindow).__BUZZ_E2E_COMMAND_PAYLOADS__ ?? [])
      .filter((entry) => entry.command === "delete_message")
      .map((entry) => entry.payload),
  );
}

test.describe("channel timeline and thread panel", () => {
  test("community admin gets Delete but never Edit on another member's message, sent as moderator", async ({
    page,
  }) => {
    await openApp(page, "admin");
    await seedRandomMessages(page);
    await openChannel(page, "random");
    const timeline = page.getByTestId("message-timeline");

    await openMoreActions(page, timeline, BOB_ROOT_ID);
    await expect(page.getByTestId(`edit-message-${BOB_ROOT_ID}`)).toHaveCount(
      0,
    );
    const deleteItem = page.getByTestId(`delete-message-${BOB_ROOT_ID}`);
    await expect(deleteItem).toBeVisible();
    await expect(deleteItem).toHaveText("Delete message");
    await deleteItem.click();
    await confirmMessageDelete(page);

    await expect(
      timeline.locator(`[data-message-id="${BOB_ROOT_ID}"]`),
    ).toHaveCount(0);
    expect(await deletePayloads(page)).toEqual([
      {
        channelId: RANDOM_CHANNEL_ID,
        eventId: BOB_ROOT_ID,
        asModerator: true,
      },
    ]);
  });

  test("community admin gets Delete but never Edit in the thread panel, sent as moderator", async ({
    page,
  }) => {
    await openApp(page, "admin");
    await seedRandomMessages(page);
    await openChannel(page, "random");

    const rootRow = page
      .getByTestId("message-timeline")
      .locator(`[data-message-id="${BOB_ROOT_ID}"]`)
      .first();
    await rootRow.hover();
    await rootRow.getByRole("button", { name: "Reply" }).click();
    const threadPanel = page.getByTestId("message-thread-panel");
    await expect(threadPanel).toBeVisible();

    // Thread head: Delete offered, Edit withheld.
    await openMoreActions(
      page,
      threadPanel.getByTestId("message-thread-head"),
      BOB_ROOT_ID,
    );
    await expect(page.getByTestId(`edit-message-${BOB_ROOT_ID}`)).toHaveCount(
      0,
    );
    await expect(
      page.getByTestId(`delete-message-${BOB_ROOT_ID}`),
    ).toBeVisible();
    await closeMenu(page);

    // Thread reply: Delete offered, Edit withheld, confirm sends moderator.
    await openMoreActions(
      page,
      threadPanel.getByTestId("message-thread-body"),
      BOB_REPLY_ID,
    );
    await expect(page.getByTestId(`edit-message-${BOB_REPLY_ID}`)).toHaveCount(
      0,
    );
    await page.getByTestId(`delete-message-${BOB_REPLY_ID}`).click();
    await confirmMessageDelete(page);

    // The mock bridge does not stream deletion events live, so the open
    // thread keeps its cached reply; the sent command is the contract here.
    await expect
      .poll(() => deletePayloads(page))
      .toEqual([
        {
          channelId: RANDOM_CHANNEL_ID,
          eventId: BOB_REPLY_ID,
          asModerator: true,
        },
      ]);
  });

  test("a moderator's own message keeps Edit and the author delete path", async ({
    page,
  }) => {
    await openApp(page, "admin");
    await seedRandomMessages(page);
    await openChannel(page, "random");
    const timeline = page.getByTestId("message-timeline");

    await openMoreActions(page, timeline, OWN_MESSAGE_ID);
    await expect(
      page.getByTestId(`edit-message-${OWN_MESSAGE_ID}`),
    ).toBeVisible();
    await page.getByTestId(`delete-message-${OWN_MESSAGE_ID}`).click();
    await confirmMessageDelete(page);

    await expect(
      timeline.locator(`[data-message-id="${OWN_MESSAGE_ID}"]`),
    ).toHaveCount(0);
    expect(await deletePayloads(page)).toEqual([
      {
        channelId: RANDOM_CHANNEL_ID,
        eventId: OWN_MESSAGE_ID,
        asModerator: false,
      },
    ]);
  });

  test("a plain member sees neither Edit nor Delete on other people's messages", async ({
    page,
  }) => {
    await openApp(page, "member");
    await seedRandomMessages(page);
    await openChannel(page, "random");
    const timeline = page.getByTestId("message-timeline");

    await openMoreActions(page, timeline, BOB_ROOT_ID);
    await expect(page.getByTestId(`edit-message-${BOB_ROOT_ID}`)).toHaveCount(
      0,
    );
    await expect(page.getByTestId(`delete-message-${BOB_ROOT_ID}`)).toHaveCount(
      0,
    );
    await closeMenu(page);

    const rootRow = timeline
      .locator(`[data-message-id="${BOB_ROOT_ID}"]`)
      .first();
    await rootRow.hover();
    await rootRow.getByRole("button", { name: "Reply" }).click();
    const threadPanel = page.getByTestId("message-thread-panel");
    await openMoreActions(
      page,
      threadPanel.getByTestId("message-thread-body"),
      BOB_REPLY_ID,
    );
    await expect(page.getByTestId(`edit-message-${BOB_REPLY_ID}`)).toHaveCount(
      0,
    );
    await expect(
      page.getByTestId(`delete-message-${BOB_REPLY_ID}`),
    ).toHaveCount(0);
  });

  test("a channel owner without a community role deletes an agent's message as moderator", async ({
    page,
  }) => {
    // #agents is owned by the mock identity; the seeded Charlie message is
    // from a bot the identity does not own.
    const charlieMessageId = "mock-agents-charlie";
    await openApp(page, "member");
    await openChannel(page, "agents");
    const timeline = page.getByTestId("message-timeline");

    await openMoreActions(page, timeline, charlieMessageId);
    await expect(
      page.getByTestId(`edit-message-${charlieMessageId}`),
    ).toHaveCount(0);
    await page.getByTestId(`delete-message-${charlieMessageId}`).click();
    await confirmMessageDelete(page);

    await expect(
      timeline.locator(`[data-message-id="${charlieMessageId}"]`),
    ).toHaveCount(0);
    expect(await deletePayloads(page)).toEqual([
      {
        channelId: AGENTS_CHANNEL_ID,
        eventId: charlieMessageId,
        asModerator: true,
      },
    ]);
  });
});

test.describe("forum", () => {
  const OFFSITE_POST = "Team offsite planning and travel notes.";
  const RELEASE_POST = "Release checklist: async feedback thread.";
  const RELEASE_REPLY_ID = "mock-forum-release-reply";

  function postCard(page: Page, text: string) {
    return page.getByRole("button").filter({ hasText: text });
  }

  test("community admin deletes another member's forum post; it stays gone after a reload of the list", async ({
    page,
  }) => {
    await openApp(page, "admin");
    await page.getByTestId("channel-watercooler").click();
    const card = postCard(page, OFFSITE_POST);
    await expect(card).toBeVisible();

    await card.hover();
    await card.getByRole("button", { name: "More actions for post" }).click();
    await page.getByRole("menuitem", { name: "Delete post" }).click();
    const dialog = page.getByRole("alertdialog");
    await expect(dialog).toContainText("Delete post?");
    await dialog.getByRole("button", { name: "Delete post" }).click();

    await expect(postCard(page, OFFSITE_POST)).toHaveCount(0);
    expect(await deletePayloads(page)).toEqual([
      {
        channelId: WATERCOOLER_CHANNEL_ID,
        eventId: "mock-forum-offsite-thread",
        asModerator: true,
      },
    ]);

    // Leave and come back: the list is refetched and the post stays gone.
    await openChannel(page, "random");
    await page.getByTestId("channel-watercooler").click();
    await expect(postCard(page, RELEASE_POST)).toBeVisible();
    await expect(postCard(page, OFFSITE_POST)).toHaveCount(0);
  });

  test("community admin deletes another member's forum reply; reopening the thread keeps it gone", async ({
    page,
  }) => {
    await openApp(page, "admin");
    await page.getByTestId("channel-watercooler").click();
    await postCard(page, RELEASE_POST).click();
    const reply = page.locator(`[data-forum-event-id="${RELEASE_REPLY_ID}"]`);
    await expect(reply).toBeVisible();

    await reply.hover();
    await reply.getByRole("button", { name: "More actions for reply" }).click();
    await page.getByRole("menuitem", { name: "Delete reply" }).click();
    const dialog = page.getByRole("alertdialog");
    await expect(dialog).toContainText("Delete reply?");
    await dialog.getByRole("button", { name: "Delete reply" }).click();

    await expect(reply).toHaveCount(0);
    expect(await deletePayloads(page)).toEqual([
      {
        channelId: WATERCOOLER_CHANNEL_ID,
        eventId: RELEASE_REPLY_ID,
        asModerator: true,
      },
    ]);

    await page.getByRole("button", { name: "Back to posts" }).click();
    await postCard(page, RELEASE_POST).click();
    await expect(
      page.locator('[data-forum-event-id="mock-forum-release-thread"]'),
    ).toBeVisible();
    await expect(
      page.locator(`[data-forum-event-id="${RELEASE_REPLY_ID}"]`),
    ).toHaveCount(0);
  });

  test("a plain forum member gets no delete action on other people's posts or replies", async ({
    page,
  }) => {
    await openApp(page, "member");
    await page.getByTestId("channel-watercooler").click();
    const card = postCard(page, OFFSITE_POST);
    await expect(card).toBeVisible();
    await expect(
      card.getByRole("button", { name: "More actions for post" }),
    ).toHaveCount(0);

    await postCard(page, RELEASE_POST).click();
    const reply = page.locator(`[data-forum-event-id="${RELEASE_REPLY_ID}"]`);
    await expect(reply).toBeVisible();
    await expect(
      reply.getByRole("button", { name: "More actions for reply" }),
    ).toHaveCount(0);
  });
});

test.describe("inbox", () => {
  async function pushForeignRandomMention(page: Page) {
    await page.evaluate(
      ({ channelId, currentPubkey, foreignId, bob }) => {
        const push = (window as MockWindow).__BUZZ_E2E_PUSH_MOCK_FEED_ITEM__;
        if (!push) throw new Error("Mock feed helper is not installed.");
        push({
          category: "mention",
          channel_id: channelId,
          channel_name: "random",
          content: "Bob mentions you in random.",
          created_at: Math.floor(Date.now() / 1_000),
          id: foreignId,
          kind: 9,
          pubkey: bob,
          tags: [
            ["h", channelId],
            ["p", currentPubkey],
          ],
        });
      },
      {
        bob: TEST_IDENTITIES.bob.pubkey,
        channelId: RANDOM_CHANNEL_ID,
        currentPubkey: CURRENT_PUBKEY,
        foreignId: INBOX_FOREIGN_ID,
      },
    );
    await page.getByTestId(`home-inbox-item-${INBOX_FOREIGN_ID}`).click();
    await expect(page.getByTestId("home-inbox-detail")).toContainText(
      "Bob mentions you in random.",
    );
  }

  test("community admin deletes someone else's message from the Inbox as moderator", async ({
    page,
  }) => {
    await openApp(page, "admin");
    await pushForeignRandomMention(page);
    const detail = page.getByTestId("home-inbox-detail");

    await openMoreActions(page, detail, INBOX_FOREIGN_ID);
    await expect(
      page.getByTestId(`edit-message-${INBOX_FOREIGN_ID}`),
    ).toHaveCount(0);
    await page.getByTestId(`delete-message-${INBOX_FOREIGN_ID}`).click();
    await confirmMessageDelete(page);

    await expect
      .poll(() => deletePayloads(page))
      .toEqual([
        {
          channelId: RANDOM_CHANNEL_ID,
          eventId: INBOX_FOREIGN_ID,
          asModerator: true,
        },
      ]);
  });

  test("a plain member gets no Delete on someone else's Inbox message", async ({
    page,
  }) => {
    await openApp(page, "member");
    await pushForeignRandomMention(page);

    await openMoreActions(
      page,
      page.getByTestId("home-inbox-detail"),
      INBOX_FOREIGN_ID,
    );
    await expect(
      page.getByTestId(`edit-message-${INBOX_FOREIGN_ID}`),
    ).toHaveCount(0);
    await expect(
      page.getByTestId(`delete-message-${INBOX_FOREIGN_ID}`),
    ).toHaveCount(0);
  });
});
