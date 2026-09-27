import type { TranscriptItem } from "@/features/agents/ui/agentSessionTypes";
import type { ReportedUsage, UsageField } from "@/shared/api/tauriArchive";

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

/**
 * Session usage as one short line, or null when nothing is known yet.
 *
 * Shows the reported total when there is one. Some harnesses (Claude Code)
 * report input and output but no total; then each known category is shown on
 * its own, never summed into an invented total. Cost is independent of the
 * token fields. A field marked incomplete is a lower bound ("≥").
 */
export function formatSessionUsage(usage: ReportedUsage | null): string | null {
  if (!usage) return null;
  const parts: string[] = [];
  const total = formatUsageField(usage.totalTokens);
  if (total) {
    parts.push(`${total} tokens`);
  } else {
    const input = formatUsageField(usage.inputTokens);
    const output = formatUsageField(usage.outputTokens);
    if (input) parts.push(`${input} in`);
    if (output) parts.push(`${output} out`);
  }
  const cost = usage.estimatedCostUsd;
  if (cost.value !== null) {
    parts.push(`${cost.incomplete ? "≥ " : ""}$${cost.value.toFixed(2)}`);
  }
  return parts.length > 0 ? parts.join(" · ") : null;
}

function formatUsageField(field: UsageField): string | null {
  const count = formatTokenCount(field.value);
  if (!count) return null;
  return `${field.incomplete ? "≥ " : ""}${count}`;
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
