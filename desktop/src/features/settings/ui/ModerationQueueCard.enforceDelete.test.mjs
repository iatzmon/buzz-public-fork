/**
 * The moderation queue's "Delete content" always targets someone else's
 * reported message, so its enforcement must go out as the NIP-29 kind:9005
 * moderator delete (`asModerator: true`). The relay never accepts a kind:5
 * from a moderator, which would leave the report unresolvable.
 */

import assert from "node:assert/strict";
import { beforeEach, test } from "node:test";

let invokeCalls;
let failDelete;
// @tauri-apps/api/core reads `window.__TAURI_INTERNALS__`.
globalThis.window ??= globalThis;
globalThis.__TAURI_INTERNALS__ = {
  invoke: async (command, args) => {
    invokeCalls.push({ command, args });
    if (command === "delete_message") {
      if (failDelete) throw new Error("relay rejected delete");
      return null;
    }
    throw new Error(`unmocked Tauri command: ${command}`);
  },
  transformCallback: () => Math.random(),
};

const { enforceResolution } = await import("./ModerationQueueCard.tsx");

const CHANNEL_ID = "9dae0116-799b-5071-a0a8-fdd30a91a35d";
const TARGET = "e".repeat(64);
const group = {
  targetKey: `event:${TARGET}`,
  targetKind: "event",
  target: TARGET,
  channelId: CHANNEL_ID,
  reports: [],
  maxSeverity: 1,
  latestCreatedAt: "2026-01-01T00:00:00Z",
  priorActions: [],
};
const ban = async () => {
  throw new Error("ban must not run for a delete");
};

beforeEach(() => {
  invokeCalls = [];
  failDelete = false;
});

test("queue Delete content sends the moderator delete for the reported event", async () => {
  await enforceResolution(group, "delete", ban);
  assert.deepEqual(invokeCalls, [
    {
      command: "delete_message",
      args: { channelId: CHANNEL_ID, eventId: TARGET, asModerator: true },
    },
  ]);
});

test("a rejected queue delete propagates so the report stays open", async () => {
  failDelete = true;
  await assert.rejects(
    () => enforceResolution(group, "delete", ban),
    /relay rejected delete/,
  );
});
