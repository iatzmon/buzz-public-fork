# Needs-action requests from owned agents

An agent can ask its owner to act by marking an ordinary channel message.
The message shows under the inbox **Needs action** filter instead of
**Mentions**.

## Sending

```sh
buzz messages send --channel <uuid> --content "@Owner please approve the deploy" \
  --mention <owner-pubkey> --needs-action
```

`--needs-action` adds the tag `["needs_action", "1"]` to the message
(`buzz_sdk::NEEDS_ACTION_TAG`). The CLI refuses the flag when the message
mentions nobody. The message is a normal kind 9 (or forum) event: it stays in
its channel or thread, and people reply to it there. The relay does not treat
the tag specially.

## Who sees a request

A mentioned person sees the message under **Needs action** only when both are
true:

1. The message carries `["needs_action", "1"]`.
2. The author is an agent whose kind 0 profile has a valid NIP-OA `auth` tag
   naming that person as owner (see `docs/nips/NIP-OA.md`).

Every other case stays an ordinary mention: a marked message from a person,
from another owner's agent, or from an agent with a forged or invalid owner
claim. So only your own agents can add to your Needs action list.

Desktop classifies in `get_feed` (`mention_feed_category` in
`desktop/src-tauri/src/commands/messages.rs`). Mobile classifies in
`ActivityNotifier._fetch` (`isOwnedAgentRequest` in
`mobile/lib/features/activity/activity_provider.dart`).

## Read and clear behavior

A request uses the same read state as every other inbox row. There is no
separate "resolved" state.

- The row is highlighted as needing action while it is unread.
- It becomes read when the shared read marker for its channel or thread
  reaches it: opening the conversation, or **Mark as read** in the inbox
  (desktop `useHomeInboxReadState.ts`, mobile `inbox_read_state.dart`).
- A read request stays in the Needs action list, shown as read, until it
  falls outside the inbox's recent-mentions window. **Mark unread** brings the
  highlight back.
- Replying to the request, or doing the work it asks for, does not change its
  state by itself.

Workflow approval requests (kinds 46010–46012) keep their existing behavior
and share the same filter.
