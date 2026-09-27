import * as React from "react";
import { MessageSquare, Octagon } from "lucide-react";
import { toast } from "sonner";

import { useAppNavigation } from "@/app/navigation/useAppNavigation";
import type { ActiveTurnDetail } from "@/features/agents/activeAgentTurnsStore";
import { awaitCancelTurnOutcome } from "@/features/agents/lib/cancelTurnOutcome";
import {
  describeCurrentActivity,
  formatSessionUsage,
} from "@/features/agents/lib/sessionRowFormat";
import {
  ensureRelayObserverSubscription,
  subscribeControlResults,
} from "@/features/agents/observerRelayStore";
import { formatElapsed } from "@/features/agents/ui/agentSessionUtils";
import { useAgentSessionUsage } from "@/features/agents/ui/useAgentSessionUsage";
import { useAgentTranscript } from "@/features/agents/ui/useObserverEvents";
import { cancelManagedAgentTurn } from "@/shared/api/agentControl";
import { Button } from "@/shared/ui/button";

type AgentSessionRowProps = {
  agentName: string;
  channelName: string | null;
  now: number;
  turn: ActiveTurnDetail;
};

/** One running agent turn with its run time, activity, usage, and Stop. */
export function AgentSessionRow({
  agentName,
  channelName,
  now,
  turn,
}: AgentSessionRowProps) {
  const { goChannel } = useAppNavigation();
  const transcript = useAgentTranscript(true, turn.agentPubkey);
  const activity = React.useMemo(
    () => describeCurrentActivity(transcript, turn.turnId),
    [transcript, turn.turnId],
  );
  const usageState = useAgentSessionUsage(turn.agentPubkey, turn.sessionId);
  const usageText = describeUsage(
    formatSessionUsage(usageState.usage),
    usageState.failed,
  );
  const [isStopping, setIsStopping] = React.useState(false);
  const channelLabel = channelName ? `#${channelName}` : "Unknown channel";
  // A runtime without exact-turn Stop can only stop "whatever runs in this
  // channel", which may already be a later turn than the row shows.
  const canStop = turn.cancelByTurnId;

  async function handleStop() {
    if (!canStop) return;
    setIsStopping(true);
    try {
      const requestId = crypto.randomUUID();
      const outcome = await awaitCancelTurnOutcome({
        requestId,
        channelId: turn.channelId,
        subscribe: (listener) =>
          subscribeControlResults(turn.agentPubkey, listener),
        sendCancel: async () => {
          await ensureRelayObserverSubscription();
          await cancelManagedAgentTurn(
            turn.agentPubkey,
            turn.channelId,
            requestId,
            turn.turnId,
          );
        },
        scheduleTimeout: (onTimeout) => {
          const timeout = window.setTimeout(onTimeout, 8_000);
          return () => window.clearTimeout(timeout);
        },
      });
      if (outcome === "sent") {
        // Keep the row marked until the turn's terminal frame removes it.
        toast.success(`Stop signal sent to ${agentName}.`);
        return;
      }
      setIsStopping(false);
      if (outcome === "no_active_turn") {
        // NIP-AO: no_active_turn also covers a turn an earlier Stop is still
        // finishing, so it does not prove the turn ended.
        toast.info(
          `${agentName} has no running turn with this ID. It may have ended, or an earlier Stop may still be finishing.`,
        );
      } else {
        toast.info("Stop requested, but the agent hasn't confirmed it.");
      }
    } catch (error) {
      setIsStopping(false);
      toast.error(
        error instanceof Error
          ? error.message
          : `Failed to stop ${agentName}'s turn.`,
      );
    }
  }

  return (
    <li
      className="flex items-center gap-4 rounded-lg border border-border/60 px-4 py-3"
      data-testid="agent-session-row"
      data-turn-id={turn.turnId}
    >
      <div className="min-w-0 flex-1 space-y-0.5">
        <p className="truncate text-sm font-medium">
          {agentName}
          <span className="font-normal text-muted-foreground">
            {" "}
            in {channelLabel}
          </span>
        </p>
        <p
          className="truncate text-sm text-muted-foreground"
          data-testid="agent-session-activity"
        >
          {isStopping ? "Stopping…" : (activity ?? "Working")}
        </p>
        {canStop ? null : (
          <p
            className="truncate text-xs text-muted-foreground"
            data-testid="agent-session-stop-unavailable"
            id={`stop-unavailable-${turn.turnId}`}
          >
            Update {agentName} to stop a single turn from here.
          </p>
        )}
      </div>
      <div className="shrink-0 text-right">
        <p className="text-sm tabular-nums" data-testid="agent-session-runtime">
          {formatElapsed(Math.max(0, now - turn.anchorAt))}
        </p>
        <p
          className="text-xs tabular-nums text-muted-foreground"
          data-testid="agent-session-usage"
        >
          {usageText}
        </p>
      </div>
      <div className="flex shrink-0 gap-2">
        <Button
          aria-label={`Open ${channelLabel}`}
          onClick={() =>
            void goChannel(
              turn.channelId,
              turn.triggeringEventId
                ? { messageId: turn.triggeringEventId }
                : undefined,
            )
          }
          size="sm"
          variant="outline"
        >
          <MessageSquare />
          Open
        </Button>
        <Button
          aria-describedby={
            canStop ? undefined : `stop-unavailable-${turn.turnId}`
          }
          aria-label={`Stop ${agentName}'s turn in ${channelLabel}`}
          data-testid="agent-session-stop"
          disabled={isStopping || !canStop}
          onClick={() => void handleStop()}
          size="sm"
          variant="outline"
        >
          <Octagon />
          Stop
        </Button>
      </div>
    </li>
  );
}

/** Usage line for a row; a failed read never reads as "no usage". */
function describeUsage(formatted: string | null, failed: boolean): string {
  if (failed) {
    return formatted
      ? `${formatted} (may be out of date)`
      : "Usage unavailable";
  }
  return formatted ?? "No usage reported yet";
}
