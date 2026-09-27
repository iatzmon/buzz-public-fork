import { useQuery } from "@tanstack/react-query";

import { getAgentSessionUsage } from "@/shared/api/tauriArchive";
import type { ReportedUsage } from "@/shared/api/tauriArchive";

/** Usage reports arrive once per completed turn; a slow poll is enough. */
const SESSION_USAGE_REFRESH_MS = 15_000;

export type AgentSessionUsageState = {
  /** Last successful read; null when none yet or no turn has reported. */
  usage: ReportedUsage | null;
  /** The newest read failed. `usage`, when present, is from an older read. */
  failed: boolean;
};

/**
 * Tokens and cost reported so far by the completed turns of one agent
 * session. A failed read is reported, never shown as "no usage"; the poll
 * keeps retrying.
 */
export function useAgentSessionUsage(
  agentPubkey: string,
  sessionId: string | null,
): AgentSessionUsageState {
  const query = useQuery({
    enabled: sessionId !== null,
    queryKey: ["agent-session-usage", agentPubkey, sessionId],
    queryFn: async () => {
      const [usage] = await getAgentSessionUsage({
        agentPubkey,
        sessionIds: sessionId ? [sessionId] : [],
      });
      return usage?.usage ?? null;
    },
    refetchInterval: SESSION_USAGE_REFRESH_MS,
  });
  return { usage: query.data ?? null, failed: query.isError };
}
