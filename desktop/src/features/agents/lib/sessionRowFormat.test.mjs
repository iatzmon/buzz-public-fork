import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  describeCurrentActivity,
  formatSessionUsage,
  formatTokenCount,
} from "./sessionRowFormat.ts";

function usage(totalTokens, cost, { tokensIncomplete = false, costIncomplete = false } = {}) {
  return {
    totalTokens: { value: totalTokens, incomplete: tokensIncomplete },
    estimatedCostUsd: { value: cost, incomplete: costIncomplete },
  };
}

describe("formatTokenCount", () => {
  it("keeps small counts exact and compacts large ones", () => {
    assert.equal(formatTokenCount("0"), "0");
    assert.equal(formatTokenCount("999"), "999");
    assert.equal(formatTokenCount("1500"), "1.5k");
    assert.equal(formatTokenCount("250000"), "250k");
    assert.equal(formatTokenCount("1200000"), "1.2M");
    assert.equal(formatTokenCount("3000000000"), "3.0B");
  });

  it("returns null for unknown or non-decimal values", () => {
    assert.equal(formatTokenCount(null), null);
    assert.equal(formatTokenCount("-5"), null);
    assert.equal(formatTokenCount("1e6"), null);
    assert.equal(formatTokenCount(""), null);
  });
});

describe("formatSessionUsage", () => {
  it("shows tokens and cost", () => {
    assert.equal(formatSessionUsage(usage("1500", 0.12)), "1.5k tokens · $0.12");
  });

  it("omits an unknown cost", () => {
    assert.equal(formatSessionUsage(usage("42", null)), "42 tokens");
  });

  it("marks incomplete totals as lower bounds", () => {
    assert.equal(
      formatSessionUsage(
        usage("2000", 1, { tokensIncomplete: true, costIncomplete: true }),
      ),
      "≥ 2.0k tokens · ≥ $1.00",
    );
  });

  it("returns null when nothing is known", () => {
    assert.equal(formatSessionUsage(null), null);
    assert.equal(formatSessionUsage(usage(null, 0.5)), null);
  });
});

describe("describeCurrentActivity", () => {
  const tool = (turnId, label) => ({
    type: "tool",
    turnId,
    title: "Tool call",
    descriptor: { label },
  });

  it("uses the newest item of the given turn only", () => {
    const items = [
      tool("turn-a", "Read file"),
      { type: "thought", turnId: "turn-a" },
      tool("turn-b", "Run tests"),
    ];
    assert.equal(describeCurrentActivity(items, "turn-a"), "Thinking");
    assert.equal(describeCurrentActivity(items, "turn-b"), "Run tests");
  });

  it("falls back to the tool title without a label", () => {
    assert.equal(describeCurrentActivity([tool("t", "")], "t"), "Tool call");
  });

  it("names message direction", () => {
    const reply = { type: "message", role: "assistant", turnId: "t" };
    const request = { type: "message", role: "user", turnId: "t" };
    assert.equal(describeCurrentActivity([reply], "t"), "Writing a reply");
    assert.equal(describeCurrentActivity([request], "t"), "Reading the request");
  });

  it("returns null when the turn has no items", () => {
    assert.equal(describeCurrentActivity([tool("other", "x")], "t"), null);
    assert.equal(describeCurrentActivity([], "t"), null);
  });
});
