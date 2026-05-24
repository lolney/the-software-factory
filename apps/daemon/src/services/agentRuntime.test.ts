import { describe, expect, it } from "vitest";
import { DeterministicAgentRuntime } from "./agentRuntime.js";

describe("DeterministicAgentRuntime", () => {
  it("emits stable status, reasoning, tool, message events", async () => {
    const runtime = new DeterministicAgentRuntime();
    const events = await runtime.runTurn({
      sessionId: "sess_debug",
      agentId: "orchestrator",
      prompt: "please run QA",
      debugMode: true
    });

    expect(events.map((event) => event.type)).toEqual([
      "agent.status",
      "agent.reasoning",
      "agent.tool_call",
      "agent.tool_result",
      "agent.message",
      "agent.status"
    ]);
    expect(events[4]?.payload.text).toContain("Debug QA");
  });
});

describe("OpenAIAgentRuntime", () => {
  it("does not silently fall back to deterministic mode for unauthenticated non-debug runs", async () => {
    const { OpenAIAgentRuntime } = await import("./agentRuntime.js");
    const original = process.env.OPENAI_API_KEY;
    delete process.env.OPENAI_API_KEY;
    try {
      await expect(new OpenAIAgentRuntime().runTurn({
        sessionId: "sess_live",
        agentId: "orchestrator",
        prompt: "run live",
        debugMode: false
      })).rejects.toThrow("OpenAI authentication is required");
    } finally {
      if (original) {
        process.env.OPENAI_API_KEY = original;
      }
    }
  });
});
