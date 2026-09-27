import * as React from "react";

import { useChannelMembersQuery } from "@/features/channels/hooks";
import { useMyRelayMembershipQuery } from "@/features/community-members/hooks";
import { canModerateChannelMessages } from "@/features/messages/lib/messageDeleteAuthority";
import { useIdentityQuery } from "@/shared/api/hooks";
import { normalizePubkey } from "@/shared/lib/pubkey";

/**
 * Whether the signed-in identity may moderator-delete other people's
 * messages in `channelId`: a community owner/admin, or an owner/admin of the
 * channel itself. Both queries are ones every message surface already holds
 * (the members bar and composer read the same roster), so this shares their
 * cache rather than fetching again. Unknown roles fail closed.
 */
export function useCanModerateChannelMessages(
  channelId: string | null,
): boolean {
  const relayMembershipQuery = useMyRelayMembershipQuery();
  const membersQuery = useChannelMembersQuery(channelId);
  const identityQuery = useIdentityQuery();

  const communityRole = relayMembershipQuery.data?.role ?? null;
  const members = membersQuery.data;
  const selfPubkey = identityQuery.data?.pubkey ?? null;
  // Memoized: rosters can be 10k+ members and message surfaces re-render on
  // every live event; the scan runs once per roster/identity change.
  return React.useMemo(() => {
    const normalizedSelf = selfPubkey ? normalizePubkey(selfPubkey) : null;
    const channelRole = normalizedSelf
      ? (members?.find(
          (member) => normalizePubkey(member.pubkey) === normalizedSelf,
        )?.role ?? null)
      : null;
    return canModerateChannelMessages({ communityRole, channelRole });
  }, [communityRole, members, selfPubkey]);
}
