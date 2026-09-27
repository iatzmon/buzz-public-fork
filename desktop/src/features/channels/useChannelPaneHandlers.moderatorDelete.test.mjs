/**
 * The channel timeline and thread panel both confirm Delete through
 * `useChannelPaneHandlers().handleDelete`. It must send the moderator
 * (kind:9005) delete for someone else's message and keep the author's kind:5
 * for the viewer's own or own-agent message and for the empty-edit shorthand's
 * bare id. Mounts the real hook with a recording delete mutation.
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

const { act, cleanup, renderHook } = await import("@testing-library/react");
const { useChannelPaneHandlers } = await import("./useChannelPaneHandlers.ts");

const VIEWER = "a".repeat(64);
const OWNED_AGENT = "b".repeat(64);
const OTHER_PERSON = "c".repeat(64);
const profiles = {
  [OWNED_AGENT]: { isAgent: true, ownerPubkey: VIEWER },
};

const noop = () => {};
const noopMutation = { mutateAsync: async () => {} };

function mountHandlers({ canModerateMessages }) {
  const deleteCalls = [];
  const deleteMessageMutation = {
    mutateAsync: async (variables) => {
      deleteCalls.push(variables);
    },
  };
  const hook = renderHook(
    (props) =>
      useChannelPaneHandlers({
        canModerateMessages: props.canModerateMessages,
        currentPubkey: VIEWER,
        deleteMessageMutation,
        editMessageMutation: noopMutation,
        editTargetId: null,
        editTargetIsThreadReply: false,
        expandedThreadReplyIds: new Set(),
        getFirstReplyIdForMessage: () => null,
        getReplyDescendantIdsForMessage: () => [],
        markRevealedRepliesRead: noop,
        profiles,
        recordThreadInteraction: noop,
        onOptimisticOpenThreadHeadIdChange: noop,
        onRequestEmptyEditDelete: noop,
        openThreadHeadId: null,
        sendMessageMutation: noopMutation,
        setExpandedThreadReplyIds: noop,
        setEditTargetId: noop,
        setOpenThreadHeadId: noop,
        setThreadReplyTargetId: noop,
        setThreadScrollTargetId: noop,
        threadReplyTargetId: null,
        toggleReactionMutation: noopMutation,
      }),
    { initialProps: { canModerateMessages } },
  );
  return { ...hook, deleteCalls };
}

const message = (id, pubkey) => ({ id, kind: 9, pubkey });

afterEach(() => {
  cleanup();
});

test("a moderator's Delete on someone else's message sends asModerator", async () => {
  const { result, deleteCalls } = mountHandlers({ canModerateMessages: true });
  await act(async () => {
    await result.current.handleDelete(message("other", OTHER_PERSON));
  });
  assert.deepEqual(deleteCalls, [{ eventId: "other", asModerator: true }]);
});

test("a moderator's own message keeps the author path; their agent's goes moderator", async () => {
  const { result, deleteCalls } = mountHandlers({ canModerateMessages: true });
  await act(async () => {
    await result.current.handleDelete(message("mine", VIEWER));
    await result.current.handleDelete(message("agent", OWNED_AGENT));
    // Empty-edit shorthand: ChannelScreen confirms with a bare id.
    await result.current.handleDelete({ id: "empty-edit" });
  });
  assert.deepEqual(deleteCalls, [
    { eventId: "mine", asModerator: false },
    { eventId: "agent", asModerator: true },
    { eventId: "empty-edit", asModerator: false },
  ]);
});

test("the handler reads the latest moderator role without re-creating itself", async () => {
  const { result, rerender, deleteCalls } = mountHandlers({
    canModerateMessages: false,
  });
  const initialHandleDelete = result.current.handleDelete;
  await act(async () => {
    await result.current.handleDelete(message("before", OTHER_PERSON));
    await result.current.handleDelete(message("agent-before", OWNED_AGENT));
  });
  rerender({ canModerateMessages: true });
  assert.equal(result.current.handleDelete, initialHandleDelete);
  await act(async () => {
    await result.current.handleDelete(message("after", OTHER_PERSON));
  });
  assert.deepEqual(deleteCalls, [
    { eventId: "before", asModerator: false },
    { eventId: "agent-before", asModerator: false },
    { eventId: "after", asModerator: true },
  ]);
});
