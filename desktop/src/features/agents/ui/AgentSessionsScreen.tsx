import * as React from "react";

import { useActiveTurnDetails } from "@/features/agents/activeAgentTurnsStore";
import { useManagedAgentsQuery } from "@/features/agents/hooks";
import { AgentSessionRow } from "@/features/agents/ui/AgentSessionRow";
import { useChannelReferences } from "@/features/channels/openChannelDirectory";
import { normalizePubkey, truncateNpub } from "@/shared/lib/pubkey";
import { useNow } from "@/shared/lib/useNow";
import { PageHeader } from "@/shared/ui/PageHeader";

/** Every running turn across the owner's agents, one row per turn. */
export function AgentSessionsScreen() {
  const turns = useActiveTurnDetails();
  const agentsQuery = useManagedAgentsQuery();
  const agentNames = React.useMemo(() => {
    const names = new Map<string, string>();
    for (const agent of agentsQuery.data ?? []) {
      names.set(normalizePubkey(agent.pubkey), agent.name);
    }
    return names;
  }, [agentsQuery.data]);
  const channelIds = React.useMemo(
    () => turns.map((turn) => turn.channelId),
    [turns],
  );
  const { channelsById } = useChannelReferences(channelIds);
  const now = useNow(1_000);

  return (
    <div className="flex-1 overflow-y-auto overflow-x-hidden overscroll-contain px-4 py-7 sm:px-6 sm:py-8">
      <div
        className="mx-auto w-full max-w-4xl space-y-6"
        data-testid="agent-sessions-page"
      >
        <PageHeader
          description="Agent turns running now. Tokens come from the usage reports of each session on this computer; the current turn is added when it ends."
          title="Sessions"
        />
        {turns.length === 0 ? (
          <p
            className="text-sm text-muted-foreground"
            data-testid="agent-sessions-empty"
          >
            No agent is working right now.
          </p>
        ) : (
          <ul aria-label="Running agent turns" className="space-y-2">
            {turns.map((turn) => (
              <AgentSessionRow
                agentName={
                  agentNames.get(turn.agentPubkey) ??
                  truncateNpub(turn.agentPubkey)
                }
                channelName={channelsById.get(turn.channelId)?.name ?? null}
                key={`${turn.agentPubkey}:${turn.turnId}`}
                now={now}
                turn={turn}
              />
            ))}
          </ul>
        )}
      </div>
    </div>
  );
}
