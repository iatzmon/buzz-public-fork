# Conversation recipient policy

The optional `--recipient-policy conversation` flag (or
`BUZZ_ACP_RECIPIENT_POLICY=conversation`) changes **agent wake selection** for
stream messages (kinds 9 and 40002), forum posts, and forum comments. The default is `legacy`.
It applies after the existing author permission gate and before queuing,
seen reactions, or steering an active turn.

Precedence:

1. A message with `p` tags addresses only those identities.
2. A reply without `p` tags addresses the thread's root author and identities
   that have authored or been mentioned in the root or replies.
3. A top-level message without `p` tags addresses subscribed channel members.

Receiving a broadcast does not by itself join a thread. A targeted reply does
not remove previous participants. The sender never wakes itself. Unmentioned
messages from agents carrying NIP-OA attestations or `bot: true` profiles do
not wake other agents. Explicit agent delegation still requires the existing
author permissions. Unknown non-owner profiles fail closed; an explicit
mention remains available.

## Enable and roll back

Use the switch on a rebuilt `buzz-acp`, keeping the existing subscription mode,
channel rules, event kinds, and `--respond-to` settings. For example:

```sh
buzz-acp <existing arguments> --recipient-policy conversation
```

This is independent of `--session-policy thread`; the latter controls provider
session isolation, not message recipients. In config subscription mode, channel,
kind, and expression filters remain in force; conversation routing replaces
`require_mention` for supported channel chat events only. Confirmed DMs,
workflow/control events, and other kinds retain their existing local filters.
The WebSocket subscription omits `#p` so the harness can evaluate unmentioned
messages. Rejected events do not start model turns.

Revert the switch to `legacy` (or remove it) and restart the harness to roll
back. No new event kinds, schema changes, relay service, or client notification
changes are included. Desktop settings do not yet expose this switch; the
managed launcher must pass the argument or environment variable through.

## History and failure behavior

Participation is derived from signed relay events using channel-scoped queries
for the root and the agent's authored/mentioned replies. It works on a fresh
process and does not depend on the prompt context window. Existing NIP-10
root/reply parsing determines the canonical thread, including nested replies.
Plain quote tags do not count as participation.

The existing exhaustive-query helper uses 500-event pages, a composite
`(until, before_id)` cursor, and a 10,000-event bound per participant query.
The whole recipient lookup is bounded to five seconds. A missing root,
unavailable/malformed profile, query error, invalid signature, timeout, or
history bound failure prevents implicit admission and logs the event ID and
reason. It does not manufacture an empty authoritative history or a broadcast.
The operator can explicitly mention the agent to retry the request; this
policy does not add a persistent retry queue. Evidence removed from the relay
is no longer participation evidence.

The first version deliberately has no participant cache. It trades narrow
relay reads for simple restart and deletion semantics. Existing `p` tags are
treated as addressing, including client-inserted automatic addresses; it does
not infer intent from message text. Clients wishing to exclude a recipient
must remove its `p` tag.

## Maintain the patch

Keep this patch separate from mobile/foldable/FCM changes. The policy and its
regressions live in `src/recipient_routing.rs` and `src/recipient_routing/tests.rs`;
existing-file hooks are limited to harness configuration and normal listener
admission. Rebase the hooks and run the complete package suite, not only the
new tests:

```sh
python3 - <<'PYTEST'
import os, subprocess
# Managed sessions carry CLI defaults and a live Git keyfile configuration.
# Tests must use their own synthetic settings and temporary keys.
env = {k: v for k, v in os.environ.items()
       if not k.startswith(("BUZZ_", "GIT_"))}
subprocess.run(["cargo", "test", "-p", "buzz-acp", "--locked", "--",
                "--test-threads=1"], env=env, check=True)
PYTEST
cargo clippy -p buzz-acp --all-targets --locked -- -D warnings
cargo fmt -p buzz-acp --check
```

The tests exercise real signed HTTP history queries through the normal author
and subscription admission boundary, with fresh routing state on each call.
They do not establish deployment or live provider response delivery.
