import { canManageMessageForCurrentUser } from "@/features/messages/lib/canManageMessage";
import type { TimelineMessage } from "@/features/messages/types";
import type { UserProfileLookup } from "@/features/profile/lib/identity";
import { KIND_HUDDLE_STARTED } from "@/shared/constants/kinds";
import { normalizePubkey } from "@/shared/lib/pubkey";

/**
 * Which relay path a delete must take.
 *
 * - `author`: the viewer wrote the message (or owns the agent that did). The
 *   delete is a NIP-09 kind:5, exactly as before moderator deletes existed —
 *   no tombstone.
 * - `moderator`: the viewer is a community or channel owner/admin deleting
 *   someone else's message. The relay accepts only a NIP-29 kind:9005 for this.
 */
export type MessageDeleteAuthority = "author" | "moderator";

/** The message fields the manage predicates read. */
export type ManageableMessage = Pick<
  TimelineMessage,
  "kind" | "pending" | "pubkey"
>;

export type MessageManagePermissions = {
  /** Edit stays on the author rule (self or own agent) — never moderators. */
  canEdit: boolean;
  deleteAuthority: MessageDeleteAuthority | null;
};

const MODERATOR_ROLES = new Set(["owner", "admin"]);

/**
 * Whether the viewer may moderate messages in a channel: a community
 * owner/admin (relay membership role) or an owner/admin of that channel.
 */
export function canModerateChannelMessages(roles: {
  communityRole: string | null | undefined;
  channelRole: string | null | undefined;
}): boolean {
  return (
    MODERATOR_ROLES.has(roles.communityRole ?? "") ||
    MODERATOR_ROLES.has(roles.channelRole ?? "")
  );
}

/**
 * Edit and delete permissions for one message, shared by every message
 * surface (channel timeline, thread panel, Inbox, forum posts and replies).
 *
 * Edit is the author rule only. Delete is the author rule, or — when the
 * viewer can moderate the channel — a moderator delete of anyone else's
 * delivered message. Huddle-started messages are immutable either way.
 *
 * A moderator deleting their own agent's message also takes the moderator
 * path: the relay accepts kind:5 from an agent owner only via its own
 * ownership record, which can disagree with the profile `ownerPubkey` this
 * app reads, while kind:9005 accepts the agent owner and the moderator alike.
 * Self-authored messages always keep the author path (no tombstone).
 */
export function resolveMessageManagePermissions(
  message: ManageableMessage,
  currentPubkey: string | undefined,
  profiles: UserProfileLookup | undefined,
  canModerate: boolean,
): MessageManagePermissions {
  const canModeratorDelete =
    canModerate &&
    message.kind !== KIND_HUDDLE_STARTED &&
    !message.pending &&
    Boolean(currentPubkey) &&
    Boolean(message.pubkey);
  if (canManageMessageForCurrentUser(message, currentPubkey, profiles)) {
    const isSelfAuthored =
      normalizePubkey(message.pubkey ?? "") ===
      normalizePubkey(currentPubkey ?? "");
    return {
      canEdit: true,
      deleteAuthority:
        !isSelfAuthored && canModeratorDelete ? "moderator" : "author",
    };
  }
  return {
    canEdit: false,
    deleteAuthority: canModeratorDelete ? "moderator" : null,
  };
}

/**
 * Whether confirming Delete on `message` must send the moderator (kind:9005)
 * delete: someone else's message, or a moderator's own agent's message. A
 * self-authored target — or one carrying no author at all, like the
 * empty-edit shorthand's bare id — keeps the kind:5 path.
 */
export function deleteRequiresModerator(
  message: ManageableMessage,
  currentPubkey: string | undefined,
  profiles: UserProfileLookup | undefined,
  canModerate: boolean,
): boolean {
  return (
    resolveMessageManagePermissions(
      message,
      currentPubkey,
      profiles,
      canModerate,
    ).deleteAuthority === "moderator"
  );
}
