/**
 * Forum moderator deletes, end to end through the production hooks.
 *
 * Mounts the real `useForumPostsQuery` / `useForumThreadQuery` alongside the
 * real delete mutations against a stubbed Tauri IPC bridge that behaves like
 * the relay: a kind:5 (`asModerator: false`) delete is accepted only from the
 * author, while a kind:9005 (`asModerator: true`) delete is accepted from a
 * moderator. The forum lists are served from that shared relay store, so the
 * assertions prove the deleted post/reply is gone after the post-delete
 * refetch, after an explicit reload, and for a second viewer with a fresh
 * cache — and that a rejected delete surfaces an error and leaves it listed.
 */

import assert from "node:assert/strict";
import { afterEach, beforeEach, test } from "node:test";

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

const CHANNEL_ID = "a27e1ee9-76a6-5bdf-a5d5-1d85610dad11";
const VIEWER = "a".repeat(64);
const ALICE = "c".repeat(64);
const POST_ID = "1".repeat(64);
const OTHER_POST_ID = "2".repeat(64);
const REPLY_ID = "3".repeat(64);

let relayEvents;
let invokeCalls;

function rawEvent(id, pubkey, kind, tags = [["h", CHANNEL_ID]]) {
  return {
    event_id: id,
    pubkey,
    content: `event ${id.slice(0, 4)}`,
    kind,
    created_at: 1_700_000_000,
    channel_id: CHANNEL_ID,
    tags,
    sig: "sig",
  };
}

function resetRelay() {
  relayEvents = [
    rawEvent(POST_ID, ALICE, 45001),
    rawEvent(OTHER_POST_ID, ALICE, 45001),
    rawEvent(REPLY_ID, ALICE, 45003, [
      ["h", CHANNEL_ID],
      ["e", POST_ID, "", "root"],
    ]),
  ];
  invokeCalls = [];
}

/** Relay authz for deletes: kind:5 author-only, kind:9005 author or moderator. */
function relayDelete({ eventId, asModerator }, { viewerIsModerator }) {
  const target = relayEvents.find((event) => event.event_id === eventId);
  if (!target) throw new Error("target event not found");
  const isAuthor = target.pubkey === VIEWER;
  if (!isAuthor && !(asModerator && viewerIsModerator)) {
    throw new Error(
      asModerator
        ? "must be event author, channel owner/admin, or community owner/admin"
        : "kind:5 deletion rejected: not the author",
    );
  }
  relayEvents = relayEvents.filter((event) => event.event_id !== eventId);
}

function installRelayStub({ viewerIsModerator }) {
  const internals = {
    invoke: async (command, args) => {
      invokeCalls.push({ command, args });
      switch (command) {
        case "get_forum_posts":
          return {
            messages: relayEvents
              .filter((event) => event.kind === 45001)
              .map((event) => ({ ...event, thread_summary: null })),
            next_cursor: null,
          };
        case "get_forum_thread": {
          const root = relayEvents.find(
            (event) => event.event_id === args.eventId,
          );
          if (!root) throw new Error("thread not found");
          const replies = relayEvents
            .filter((event) => event.kind === 45003)
            .map((event) => ({
              ...event,
              parent_event_id: POST_ID,
              root_event_id: POST_ID,
              depth: 1,
            }));
          return {
            root: { ...root, thread_summary: null },
            replies,
            total_replies: replies.length,
            next_cursor: null,
          };
        }
        case "delete_message":
          relayDelete(args, { viewerIsModerator });
          return null;
        default:
          throw new Error(`unmocked Tauri command: ${command}`);
      }
    },
    transformCallback: () => Math.random(),
  };
  globalThis.__TAURI_INTERNALS__ = internals;
  dom.window.__TAURI_INTERNALS__ = internals;
}

const { act, cleanup, renderHook, waitFor } = await import(
  "@testing-library/react"
);
const { createElement } = await import("react");
const { QueryClient, QueryClientProvider } = await import(
  "@tanstack/react-query"
);
const { toast } = await import("sonner");
const {
  useDeleteForumPostMutation,
  useDeleteForumReplyMutation,
  useForumPostsQuery,
  useForumThreadQuery,
} = await import("./hooks.ts");
const { relaySelfQueryKey } = await import("@/features/moderation/hooks");

const channel = { id: CHANNEL_ID, channelType: "forum" };
let toastErrors;
const originalToastError = toast.error;
// Every client is cleared after each test: a live QueryClient's gc/poll
// timers would otherwise keep the test process from exiting. clear() does not
// cancel mutation gc timers, so mutations also use gcTime 0.
const viewerClients = [];

function newViewerClient() {
  const queryClient = new QueryClient({
    defaultOptions: {
      queries: { retry: false },
      mutations: { retry: false, gcTime: 0 },
    },
  });
  queryClient.setQueryData(relaySelfQueryKey, null);
  viewerClients.push(queryClient);
  const wrapper = ({ children }) =>
    createElement(QueryClientProvider, { client: queryClient }, children);
  return { queryClient, wrapper };
}

function mountPostsWithDelete() {
  const { queryClient, wrapper } = newViewerClient();
  const hook = renderHook(
    () => ({
      posts: useForumPostsQuery(channel),
      deletePost: useDeleteForumPostMutation(channel),
    }),
    { wrapper },
  );
  return { ...hook, queryClient };
}

const postIds = (result) =>
  result.current.posts.data?.posts.map((post) => post.eventId) ?? [];

beforeEach(() => {
  resetRelay();
  toastErrors = [];
  toast.error = (message) => {
    toastErrors.push(message);
  };
});

afterEach(() => {
  cleanup();
  for (const queryClient of viewerClients.splice(0)) queryClient.clear();
  toast.error = originalToastError;
});

test("moderator post delete sends asModerator, drops the post after refetch, reload, and for another viewer", async () => {
  installRelayStub({ viewerIsModerator: true });
  const { result } = mountPostsWithDelete();
  await waitFor(() =>
    assert.deepEqual(postIds(result), [POST_ID, OTHER_POST_ID]),
  );

  await act(async () => {
    await result.current.deletePost.mutateAsync({
      eventId: POST_ID,
      asModerator: true,
    });
  });

  assert.deepEqual(
    invokeCalls.find((call) => call.command === "delete_message")?.args,
    { channelId: CHANNEL_ID, eventId: POST_ID, asModerator: true },
  );
  // onSuccess invalidation refetches from the relay: the post is gone.
  await waitFor(() => assert.deepEqual(postIds(result), [OTHER_POST_ID]));

  // A reload (explicit refetch) still reads it gone.
  await act(async () => {
    await result.current.posts.refetch();
  });
  assert.deepEqual(postIds(result), [OTHER_POST_ID]);

  // A second viewer with a cold cache never sees it.
  const secondViewer = renderHook(() => useForumPostsQuery(channel), {
    wrapper: newViewerClient().wrapper,
  });
  await waitFor(() =>
    assert.deepEqual(
      secondViewer.result.current.data?.posts.map((post) => post.eventId),
      [OTHER_POST_ID],
    ),
  );
  assert.deepEqual(toastErrors, []);
});

test("a rejected post delete surfaces a toast and the post stays listed", async () => {
  // The viewer is not a moderator: the relay refuses the kind:9005.
  installRelayStub({ viewerIsModerator: false });
  const { result } = mountPostsWithDelete();
  await waitFor(() =>
    assert.deepEqual(postIds(result), [POST_ID, OTHER_POST_ID]),
  );

  await act(async () => {
    await result.current.deletePost
      .mutateAsync({ eventId: POST_ID, asModerator: true })
      .catch(() => {});
  });

  assert.equal(toastErrors.length, 1);
  assert.match(toastErrors[0], /^Failed to delete post: /);
  await act(async () => {
    await result.current.posts.refetch();
  });
  assert.deepEqual(postIds(result), [POST_ID, OTHER_POST_ID]);
});

test("without asModerator a moderator's delete of another author's post is the rejected kind:5", async () => {
  installRelayStub({ viewerIsModerator: true });
  const { result } = mountPostsWithDelete();
  await waitFor(() => assert.equal(postIds(result).length, 2));

  await act(async () => {
    await result.current.deletePost
      .mutateAsync({ eventId: POST_ID })
      .catch(() => {});
  });

  assert.deepEqual(
    invokeCalls.find((call) => call.command === "delete_message")?.args,
    { channelId: CHANNEL_ID, eventId: POST_ID, asModerator: false },
  );
  assert.match(toastErrors[0] ?? "", /not the author/);
  assert.deepEqual(postIds(result), [POST_ID, OTHER_POST_ID]);
});

test("moderator reply delete sends asModerator and the refetched thread drops the reply", async () => {
  installRelayStub({ viewerIsModerator: true });
  const { wrapper } = newViewerClient();
  const { result } = renderHook(
    () => ({
      thread: useForumThreadQuery(CHANNEL_ID, POST_ID),
      deleteReply: useDeleteForumReplyMutation(channel, POST_ID),
    }),
    { wrapper },
  );
  const replyIds = () =>
    result.current.thread.data?.replies.map((reply) => reply.eventId) ?? [];
  await waitFor(() => assert.deepEqual(replyIds(), [REPLY_ID]));

  await act(async () => {
    await result.current.deleteReply.mutateAsync({
      eventId: REPLY_ID,
      asModerator: true,
    });
  });

  assert.deepEqual(
    invokeCalls.find((call) => call.command === "delete_message")?.args,
    { channelId: CHANNEL_ID, eventId: REPLY_ID, asModerator: true },
  );
  await waitFor(() => assert.deepEqual(replyIds(), []));
  await act(async () => {
    await result.current.thread.refetch();
  });
  assert.deepEqual(replyIds(), []);

  const secondViewer = renderHook(
    () => useForumThreadQuery(CHANNEL_ID, POST_ID),
    { wrapper: newViewerClient().wrapper },
  );
  await waitFor(() =>
    assert.deepEqual(secondViewer.result.current.data?.replies, []),
  );
});

test("a rejected reply delete surfaces a toast", async () => {
  installRelayStub({ viewerIsModerator: false });
  const { wrapper } = newViewerClient();
  const { result } = renderHook(
    () => useDeleteForumReplyMutation(channel, POST_ID),
    { wrapper },
  );

  await act(async () => {
    await result.current
      .mutateAsync({ eventId: REPLY_ID, asModerator: true })
      .catch(() => {});
  });

  assert.equal(toastErrors.length, 1);
  assert.match(toastErrors[0], /^Failed to delete reply: /);
  assert.ok(relayEvents.some((event) => event.event_id === REPLY_ID));
});
