import { Agent, run } from "@openai/agents";
import type { SessionEvent } from "@multiagent/shared";
import { makeEventId } from "./eventStore.js";

export interface AgentTurnInput {
  sessionId: string;
  agentId: string;
  prompt: string;
  debugMode: boolean;
  causationId?: string;
}

export interface AgentRuntime {
  runTurn(input: AgentTurnInput): Promise<SessionEvent[]>;
}

export class OpenAIAgentRuntime implements AgentRuntime {
  async runTurn(input: AgentTurnInput): Promise<SessionEvent[]> {
    if (input.debugMode || !process.env.OPENAI_API_KEY) {
      return new DeterministicAgentRuntime().runTurn(input);
    }

    const startedAt = new Date().toISOString();
    const agent = new Agent({
      name: "Orchestrator",
      instructions: "You are the long-running orchestrator for a local multiagent coding workflow engine. Be concise, operational, and explicit about next agent actions."
    });
    const result = await run(agent, input.prompt);
    const output = String(result.finalOutput ?? "");

    return [
      statusEvent(input, "working", startedAt),
      {
        eventId: makeEventId(),
        sessionId: input.sessionId,
        agentId: input.agentId,
        timestamp: new Date().toISOString(),
        type: "agent.message",
        payload: { text: output, runtime: "openai-agents" },
        causationId: input.causationId
      },
      statusEvent(input, "idle")
    ];
  }
}

export class DeterministicAgentRuntime implements AgentRuntime {
  async runTurn(input: AgentTurnInput): Promise<SessionEvent[]> {
    const plan = deterministicPlan(input.prompt);
    const callId = `call_${crypto.randomUUID()}`;
    return [
      statusEvent(input, "working"),
      {
        eventId: makeEventId(),
        sessionId: input.sessionId,
        agentId: input.agentId,
        timestamp: new Date().toISOString(),
        type: "agent.reasoning",
        payload: {
          summary: "Debug runtime selected a pre-programmed response path.",
          runtime: "deterministic"
        },
        causationId: input.causationId
      },
      {
        eventId: makeEventId(),
        sessionId: input.sessionId,
        agentId: input.agentId,
        timestamp: new Date().toISOString(),
        type: "agent.tool_call",
        payload: {
          callId,
          toolName: "debug.inspect_goal",
          input: { prompt: input.prompt }
        },
        causationId: input.causationId
      },
      {
        eventId: makeEventId(),
        sessionId: input.sessionId,
        agentId: input.agentId,
        timestamp: new Date().toISOString(),
        type: "agent.tool_result",
        payload: {
          callId,
          toolName: "debug.inspect_goal",
          output: plan.toolResult
        },
        causationId: input.causationId
      },
      {
        eventId: makeEventId(),
        sessionId: input.sessionId,
        agentId: input.agentId,
        timestamp: new Date().toISOString(),
        type: "agent.message",
        payload: {
          text: plan.message,
          runtime: "deterministic"
        },
        causationId: input.causationId
      },
      statusEvent(input, "idle")
    ];
  }
}

function statusEvent(input: AgentTurnInput, status: string, timestamp = new Date().toISOString()): SessionEvent {
  return {
    eventId: makeEventId(),
    sessionId: input.sessionId,
    agentId: input.agentId,
    timestamp,
    type: "agent.status",
    payload: { status },
    causationId: input.causationId
  };
}

function deterministicPlan(prompt: string) {
  const lower = prompt.toLowerCase();
  if (lower.includes("test") || lower.includes("qa")) {
    return {
      toolResult: "Detected QA-oriented goal; next simulated step is to run checks and request reviewer feedback.",
      message: "Debug orchestrator: I will start the implementor/QA workflow, collect check results, and stop only after QA reports acceptance."
    };
  }
  if (lower.includes("review")) {
    return {
      toolResult: "Detected review-oriented goal; next simulated step is parallel implementor and reviewer coordination.",
      message: "Debug orchestrator: I will run the implementor and reviewer in parallel, route reviewer findings back as messages, and track file ownership."
    };
  }
  return {
    toolResult: "Detected general implementation goal; next simulated step is planner handoff followed by implementation.",
    message: "Debug orchestrator: I will ask the planner for a workflow, launch the selected agents, and keep the session log durable for replay."
  };
}
