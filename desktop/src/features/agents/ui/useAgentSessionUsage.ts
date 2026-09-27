import { useQuery } from "@tanstack/react-query";

import { getAgentSessionUsage } from "@/shared/api/tauriArchive";
import type { ReportedUsage } from "@/shared/api/tauriArchive";

/** Usage reports arrive once per completed turn; a slow poll is enough. */
const SESSION_USAGE_REFRESH_MS = 15_000;

/**
 * Tokens and cost reported so far by the completed turns of one agent
 * session. Null while the session id is unknown or no turn has reported yet.
 */
export function useAgentSessionUsage(
  agentPubkey: string,
  sessionId: string | null,
): ReportedUsage | null {
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
  return query.data ?? null;
}
