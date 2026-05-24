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
