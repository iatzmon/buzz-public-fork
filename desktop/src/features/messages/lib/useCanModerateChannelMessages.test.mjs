/**
 * `useCanModerateChannelMessages` is the one place message surfaces learn the
 * viewer's moderator standing. Mounts the real hook over a QueryClient seeded
 * with the same cache entries the app's membership, roster, and identity
 * queries fill, so no fetch is needed.
 */

import assert from "node:assert/strict";
import { afterEach, test } from "node:test";

import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><body></body></html>", {
  url: "http://localhost",
});
Object.assign(globalThis, {
  IS_REACT_ACT_ENVIRONMENT: true,
  document: dom.window.document,
  HTMLElement: dom.window.HTMLElement,
  window: dom.window,
});
const failingInternals = {
  invoke: (command) =>
    Promise.reject(new Error(`unexpected Tauri command: ${command}`)),
  transformCallback: () => Math.random(),
};
globalThis.__TAURI_INTERNALS__ = failingInternals;
dom.window.__TAURI_INTERNALS__ = failingInternals;

const { cleanup, renderHook } = await import("@testing-library/react");
const { createElement } = await import("react");
const { QueryClient, QueryClientProvider } = await import(
  "@tanstack/react-query"
);
const { myRelayMembershipQueryKey } = await import(
  "@/features/community-members/hooks"
);
const { useCanModerateChannelMessages } = await import(
  "./useCanModerateChannelMessages.ts"
);

const CHANNEL_ID = "9dae0116-799b-5071-a0a8-fdd30a91a35d";
const VIEWER = "a".repeat(64);
const clients = [];

function render({ communityRole, channelRole, channelId = CHANNEL_ID }) {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  });
  clients.push(queryClient);
  queryClient.setQueryData(["identity"], { pubkey: VIEWER.toUpperCase() });
  queryClient.setQueryData(
    myRelayMembershipQueryKey,
    communityRole ? { pubkey: VIEWER, role: communityRole } : null,
  );
  queryClient.setQueryData(
    ["channels", CHANNEL_ID, "members"],
    [
      { pubkey: "c".repeat(64), role: "owner" },
      ...(channelRole ? [{ pubkey: VIEWER, role: channelRole }] : []),
    ],
  );
  const wrapper = ({ children }) =>
    createElement(QueryClientProvider, { client: queryClient }, children);
  return renderHook(() => useCanModerateChannelMessages(channelId), {
    wrapper,
  }).result.current;
}

afterEach(() => {
  cleanup();
  for (const queryClient of clients.splice(0)) queryClient.clear();
});

test("community owner/admin moderate every channel", () => {
  assert.equal(render({ communityRole: "owner", channelRole: null }), true);
  assert.equal(render({ communityRole: "admin", channelRole: "member" }), true);
});

test("channel owner/admin moderate their channel without a community role", () => {
  assert.equal(render({ communityRole: "member", channelRole: "owner" }), true);
  assert.equal(render({ communityRole: null, channelRole: "admin" }), true);
});

test("plain members, guests, and non-members do not moderate", () => {
  assert.equal(
    render({ communityRole: "member", channelRole: "member" }),
    false,
  );
  assert.equal(
    render({ communityRole: "member", channelRole: "guest" }),
    false,
  );
  // Another member owns the channel; the viewer is not on the roster.
  assert.equal(render({ communityRole: "member", channelRole: null }), false);
});
