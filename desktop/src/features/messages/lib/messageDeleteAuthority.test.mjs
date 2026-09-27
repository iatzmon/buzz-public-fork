import assert from "node:assert/strict";
import test from "node:test";

import {
  canModerateChannelMessages,
  deleteRequiresModerator,
  resolveMessageManagePermissions,
} from "./messageDeleteAuthority.ts";

const VIEWER = "a".repeat(64);
const OWNED_AGENT = "b".repeat(64);
const OTHER_PERSON = "c".repeat(64);
const OTHER_AGENT = "d".repeat(64);

const KIND_STREAM_MESSAGE = 9;
const KIND_FORUM_POST = 45001;
const KIND_FORUM_COMMENT = 45003;
const KIND_HUDDLE_STARTED = 48100;

const profiles = {
  [OWNED_AGENT]: { isAgent: true, ownerPubkey: VIEWER },
  [OTHER_AGENT]: { isAgent: true, ownerPubkey: OTHER_PERSON },
};

const ROLES = ["owner", "admin", "member", null];

const TARGETS = [
  { name: "self", pubkey: VIEWER, isAuthor: true, isSelf: true },
  { name: "own agent", pubkey: OWNED_AGENT, isAuthor: true, isSelf: false },
  {
    name: "other person",
    pubkey: OTHER_PERSON,
    isAuthor: false,
    isSelf: false,
  },
  {
    name: "other person's agent",
    pubkey: OTHER_AGENT,
    isAuthor: false,
    isSelf: false,
  },
];

const isModeratorRole = (role) => role === "owner" || role === "admin";

test("canModerateChannelMessages: community or channel owner/admin only", () => {
  for (const communityRole of [...ROLES, undefined]) {
    for (const channelRole of [...ROLES, "guest", "bot", undefined]) {
      assert.equal(
        canModerateChannelMessages({ communityRole, channelRole }),
        isModeratorRole(communityRole) || isModeratorRole(channelRole),
        `community=${communityRole} channel=${channelRole}`,
      );
    }
  }
});

test("permissions table: community role x channel role x author x kind", () => {
  for (const communityRole of ROLES) {
    for (const channelRole of ROLES) {
      const canModerate = canModerateChannelMessages({
        communityRole,
        channelRole,
      });
      for (const target of TARGETS) {
        for (const kind of [
          KIND_STREAM_MESSAGE,
          KIND_FORUM_POST,
          KIND_FORUM_COMMENT,
          KIND_HUDDLE_STARTED,
        ]) {
          const label = `community=${communityRole} channel=${channelRole} target=${target.name} kind=${kind}`;
          const permissions = resolveMessageManagePermissions(
            { kind, pubkey: target.pubkey },
            VIEWER,
            profiles,
            canModerate,
          );

          if (kind === KIND_HUDDLE_STARTED) {
            // Huddle-started rows stay immutable for everyone.
            assert.deepEqual(
              permissions,
              { canEdit: false, deleteAuthority: null },
              label,
            );
            continue;
          }

          // Edit never widens: only the author rule grants it, whatever the
          // viewer's moderator role.
          assert.equal(permissions.canEdit, target.isAuthor, label);
          // Only a self-authored message keeps kind:5 for a moderator; their
          // own agent's message goes out as kind:9005 (see the helper doc).
          const expectedDelete = target.isSelf
            ? "author"
            : canModerate
              ? "moderator"
              : target.isAuthor
                ? "author"
                : null;
          assert.equal(permissions.deleteAuthority, expectedDelete, label);
        }
      }
    }
  }
});

test("a moderator's own message keeps the author (kind:5) path", () => {
  const permissions = resolveMessageManagePermissions(
    { kind: KIND_STREAM_MESSAGE, pubkey: VIEWER },
    VIEWER,
    profiles,
    true,
  );
  assert.equal(permissions.deleteAuthority, "author");
  assert.equal(
    deleteRequiresModerator(
      { kind: KIND_STREAM_MESSAGE, pubkey: VIEWER },
      VIEWER,
      profiles,
      true,
    ),
    false,
  );
});

test("author match is case-insensitive", () => {
  assert.equal(
    resolveMessageManagePermissions(
      { kind: KIND_STREAM_MESSAGE, pubkey: VIEWER.toUpperCase() },
      VIEWER,
      profiles,
      true,
    ).deleteAuthority,
    "author",
  );
});

test("moderator delete needs a delivered, attributed message and a viewer", () => {
  const other = { kind: KIND_STREAM_MESSAGE, pubkey: OTHER_PERSON };
  assert.equal(
    resolveMessageManagePermissions(
      { ...other, pending: true },
      VIEWER,
      profiles,
      true,
    ).deleteAuthority,
    null,
  );
  assert.equal(
    resolveMessageManagePermissions(
      { kind: KIND_STREAM_MESSAGE },
      VIEWER,
      profiles,
      true,
    ).deleteAuthority,
    null,
  );
  assert.equal(
    resolveMessageManagePermissions(other, undefined, profiles, true)
      .deleteAuthority,
    null,
  );
});

test("own agent's message: kind:9005 for a moderator, kind:5 otherwise, Edit either way", () => {
  const ownAgent = { kind: KIND_STREAM_MESSAGE, pubkey: OWNED_AGENT };
  assert.deepEqual(
    resolveMessageManagePermissions(ownAgent, VIEWER, profiles, true),
    { canEdit: true, deleteAuthority: "moderator" },
  );
  assert.deepEqual(
    resolveMessageManagePermissions(ownAgent, VIEWER, profiles, false),
    { canEdit: true, deleteAuthority: "author" },
  );
  // A still-sending own-agent message has no delivered event to 9005.
  assert.equal(
    resolveMessageManagePermissions(
      { ...ownAgent, pending: true },
      VIEWER,
      profiles,
      true,
    ).deleteAuthority,
    "author",
  );
});

test("deleteRequiresModerator: kind:9005 for others and a moderator's own agent", () => {
  const other = { kind: KIND_STREAM_MESSAGE, pubkey: OTHER_PERSON };
  const ownAgent = { kind: KIND_STREAM_MESSAGE, pubkey: OWNED_AGENT };
  assert.equal(deleteRequiresModerator(other, VIEWER, profiles, true), true);
  assert.equal(deleteRequiresModerator(other, VIEWER, profiles, false), false);
  assert.equal(deleteRequiresModerator(ownAgent, VIEWER, profiles, true), true);
  assert.equal(
    deleteRequiresModerator(ownAgent, VIEWER, profiles, false),
    false,
  );
  // The empty-edit shorthand deletes by bare id: always the author path.
  assert.equal(
    deleteRequiresModerator({ id: "x" }, VIEWER, profiles, true),
    false,
  );
});
