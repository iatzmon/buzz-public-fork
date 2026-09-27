import type { TranscriptItem } from "@/features/agents/ui/agentSessionTypes";
import type { ReportedUsage } from "@/shared/api/tauriArchive";

/**
 * Compact token count from a decimal `u64` string ("12.3k", "1.2M").
 * Returns null when the value is unknown or not a decimal integer.
 */
export function formatTokenCount(value: string | null): string | null {
  if (value === null || !/^\d+$/.test(value)) return null;
  const count = BigInt(value);
  if (count < 1_000n) return count.toString();
  // Display precision only; the exact value stays in the string.
  const approx = Number(count);
  if (approx < 1_000_000) return `${trimDecimal(approx / 1_000)}k`;
  if (approx < 1_000_000_000) return `${trimDecimal(approx / 1_000_000)}M`;
  return `${trimDecimal(approx / 1_000_000_000)}B`;
}

function trimDecimal(value: number): string {
  return value >= 100 ? Math.round(value).toString() : value.toFixed(1);
}

/** Session usage as one short line, or null when nothing is known yet. */
export function formatSessionUsage(usage: ReportedUsage | null): string | null {
  if (!usage) return null;
  const tokens = formatTokenCount(usage.totalTokens.value);
  if (!tokens) return null;
  const lowerBound = usage.totalTokens.incomplete ? "≥ " : "";
  const cost = usage.estimatedCostUsd.value;
  const costText =
    cost === null
      ? ""
      : ` · ${usage.estimatedCostUsd.incomplete ? "≥ " : ""}$${cost.toFixed(2)}`;
  return `${lowerBound}${tokens} tokens${costText}`;
}

/**
 * What the turn is doing now, from the agent's live transcript: the newest
 * transcript item that belongs to this turn. Null when the turn has no
 * visible activity yet.
 */
export function describeCurrentActivity(
  items: readonly TranscriptItem[],
  turnId: string,
): string | null {
  for (let index = items.length - 1; index >= 0; index -= 1) {
    const item = items[index];
    if (item.turnId !== turnId) continue;
    switch (item.type) {
      case "tool":
        return item.descriptor.label || item.title;
      case "thought":
        return "Thinking";
      case "message":
        return item.role === "assistant"
          ? "Writing a reply"
          : "Reading the request";
      case "plan":
        return "Planning";
      case "lifecycle":
        return item.title;
      default:
        continue;
    }
  }
  return null;
}
