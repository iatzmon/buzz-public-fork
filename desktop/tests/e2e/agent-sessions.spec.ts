import { expect, test, type Page } from "@playwright/test";

import { installMockBridge, TEST_IDENTITIES } from "../helpers/bridge";

const AGENT_PUBKEY = TEST_IDENTITIES.charlie.pubkey;
const CHANNEL_AGENTS = "94a444a4-c0a3-5966-ab05-530c6ddc2301";
const CHANNEL_GENERAL = "9a1657ac-f7aa-5db0-b632-d8bbeb6dfb50";

type ControlRequest = {
  agentPubkey: string;
  payload: {
    type: string;
    channelId?: string;
    requestId?: string;
    turnId?: string;
  };
};

type SeedInput = {
  channelId: string;
  turnId: string;
  kind?: "turn_started" | "turn_liveness" | "turn_completed";
  sessionId?: string | null;
  payload?: unknown;
};

async function seedTurn(page: Page, input: SeedInput) {
  await page.evaluate(
    ({ agentPubkey, input }) => {
      window.__BUZZ_E2E_SEED_ACTIVE_TURNS__?.({ agentPubkey, ...input });
    },
    { agentPubkey: AGENT_PUBKEY, input },
  );
}

async function readControlRequests(page: Page): Promise<ControlRequest[]> {
  return page.evaluate(
    () => (window.__BUZZ_E2E_OBSERVER_CONTROLS__ ?? []) as ControlRequest[],
  );
}

function row(page: Page, turnId: string) {
  return page.locator(
    `[data-testid="agent-session-row"][data-turn-id="${turnId}"]`,
  );
}

test.describe("Sessions view", () => {
  test.use({ viewport: { width: 1280, height: 720 } });

  test("lists each running turn and stops only one exact turn", async ({
    page,
  }) => {
    await installMockBridge(page, {
      managedAgents: [
        {
          name: "Charlie",
          personaId: "sessions-persona",
          pubkey: AGENT_PUBKEY,
          status: "running",
          channelNames: ["agents", "general"],
        },
      ],
      observerControlResults: [
        { type: "cancel_turn", status: "sent" },
        { type: "cancel_turn", status: "sent" },
      ],
      sessionUsage: [
        {
          agentPubkey: AGENT_PUBKEY,
          sessionId: "sess-b",
          totalTokens: "1500",
          costUsd: 0.12,
          reportCount: 2,
        },
      ],
    });
    await page.goto("/", { waitUntil: "domcontentloaded" });
    await page.waitForFunction(
      () => typeof window.__BUZZ_E2E_SEED_ACTIVE_TURNS__ === "function",
      null,
      { timeout: 10_000 },
    );

    await page.getByTestId("open-sessions-view").click();
    await expect(page.getByTestId("agent-sessions-empty")).toBeVisible();

    // Two sibling turns in one channel, both on a runtime that supports
    // exact-turn Stop; turn B learns its session from a liveness frame.
    const supported = { cancelByTurnId: true };
    await seedTurn(page, {
      channelId: CHANNEL_AGENTS,
      turnId: "turn-a",
      payload: { ...supported, triggeringEventIds: [] },
    });
    await seedTurn(page, {
      channelId: CHANNEL_AGENTS,
      turnId: "turn-b",
      payload: supported,
    });
    await seedTurn(page, {
      channelId: CHANNEL_AGENTS,
      turnId: "turn-b",
      kind: "turn_liveness",
      sessionId: "sess-b",
      payload: supported,
    });
    // An older runtime: no support advertised.
    await seedTurn(page, { channelId: CHANNEL_GENERAL, turnId: "turn-old" });

    await expect(page.getByTestId("agent-session-row")).toHaveCount(3);
    await expect(row(page, "turn-a")).toContainText("Charlie in #agents");
    await expect(row(page, "turn-old")).toContainText("#general");
    await expect(
      row(page, "turn-b").getByTestId("agent-session-usage"),
    ).toHaveText("1.5k tokens · $0.12");
    await expect(
      row(page, "turn-a").getByTestId("agent-session-usage"),
    ).toHaveText("No usage reported yet");
    await expect(
      row(page, "turn-a").getByTestId("agent-session-runtime"),
    ).toHaveText(/^\d+s$/);

    await row(page, "turn-b").getByTestId("agent-session-stop").click();
    await expect
      .poll(async () =>
        (await readControlRequests(page)).map((entry) => entry.payload),
      )
      .toEqual([
        expect.objectContaining({
          type: "cancel_turn",
          channelId: CHANNEL_AGENTS,
          turnId: "turn-b",
          requestId: expect.any(String),
        }),
      ]);
    await expect(
      row(page, "turn-b").getByTestId("agent-session-activity"),
    ).toHaveText("Stopping…");
    await expect(
      row(page, "turn-a").getByTestId("agent-session-activity"),
    ).not.toHaveText("Stopping…");

    // Without advertised support, the old runtime could only stop "the turn
    // running in this channel", which may already be a later turn than the
    // row shows. Stop stays disabled and explains why; nothing is sent.
    const legacyStop = row(page, "turn-old").getByTestId("agent-session-stop");
    await expect(legacyStop).toBeDisabled();
    await expect(
      row(page, "turn-old").getByTestId("agent-session-stop-unavailable"),
    ).toHaveText("Update Charlie to stop a single turn from here.");
    await legacyStop.click({ force: true });
    await page.waitForTimeout(300);
    expect(await readControlRequests(page)).toHaveLength(1);

    // A later turn in the same channel gets its own row; Stop on it names
    // that turn, never "whatever runs in the channel".
    await seedTurn(page, {
      channelId: CHANNEL_AGENTS,
      turnId: "turn-a",
      kind: "turn_completed",
    });
    await seedTurn(page, {
      channelId: CHANNEL_AGENTS,
      turnId: "turn-c",
      payload: supported,
    });
    await expect(row(page, "turn-a")).toHaveCount(0);
    await row(page, "turn-c").getByTestId("agent-session-stop").click();
    await expect
      .poll(async () => (await readControlRequests(page)).length)
      .toBe(2);
    const [, second] = await readControlRequests(page);
    expect(second.payload).toMatchObject({
      type: "cancel_turn",
      channelId: CHANNEL_AGENTS,
      turnId: "turn-c",
    });
  });

  test("shows a failed usage read as unavailable, not as no usage", async ({
    page,
  }) => {
    await installMockBridge(page, {
      managedAgents: [
        {
          name: "Charlie",
          personaId: "sessions-persona",
          pubkey: AGENT_PUBKEY,
          status: "running",
          channelNames: ["agents"],
        },
      ],
      sessionUsageError: "archive unavailable",
    });
    await page.goto("/", { waitUntil: "domcontentloaded" });
    await page.waitForFunction(
      () => typeof window.__BUZZ_E2E_SEED_ACTIVE_TURNS__ === "function",
      null,
      { timeout: 10_000 },
    );
    await page.getByTestId("open-sessions-view").click();
    await seedTurn(page, {
      channelId: CHANNEL_AGENTS,
      turnId: "turn-x",
      sessionId: "sess-x",
      payload: { cancelByTurnId: true },
    });

    await expect(
      row(page, "turn-x").getByTestId("agent-session-usage"),
    ).toHaveText("Usage unavailable", { timeout: 15_000 });
  });
});
