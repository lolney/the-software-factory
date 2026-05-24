import { Agent, run, setDefaultOpenAIKey, tool } from "@openai/agents";
import type { SessionEvent } from "@multiagent/shared";
import { z } from "zod";
import { makeEventId } from "./eventStore.js";

export interface AgentTurnInput {
  sessionId: string;
  agentId: string;
  prompt: string;
  debugMode: boolean;
  roleName?: string;
  instructions?: string;
  apiKey?: string;
  workflowTools?: {
    listWorkflows?: () => unknown;
    createPlan?: (plan: unknown) => Promise<string>;
    instantiatePlan?: (planId: string) => Promise<string>;
    inspectAgents?: () => unknown;
    readWorkspaceFile?: (relativePath: string) => Promise<string>;
    sendAgentMessage?: (agentId: string, text: string) => Promise<string>;
  };
  signal?: AbortSignal;
  causationId?: string;
}

export interface AgentRuntime {
  runTurn(input: AgentTurnInput): Promise<SessionEvent[]>;
}

export class OpenAIAgentRuntime implements AgentRuntime {
  async runTurn(input: AgentTurnInput): Promise<SessionEvent[]> {
    if (input.signal?.aborted) return [statusEvent(input, "cancelled")];
    if (input.debugMode) {
      return new DeterministicAgentRuntime().runTurn(input);
    }
    const apiKey = input.apiKey ?? process.env.OPENAI_API_KEY;
    if (!apiKey) {
      throw new Error("OpenAI authentication is required for non-debug sessions. Connect OpenAI OAuth in Settings or set OPENAI_API_KEY.");
    }
    setDefaultOpenAIKey(apiKey);

    const startedAt = new Date().toISOString();
    const tools = [];
    if (input.workflowTools?.listWorkflows) {
      const listWorkflows = input.workflowTools.listWorkflows;
      tools.push(tool({
        name: "workflow_list",
        description: "List predefined workflow specs available to instantiate into the current session graph.",
        parameters: z.object({}),
        execute: async () => JSON.stringify(listWorkflows())
      }));
    }
    if (input.workflowTools?.createPlan) {
      tools.push(tool({
        name: "plan_create",
        description: "Create a plan made of workflows, agent prompts, and done criteria.",
        parameters: z.object({ plan: z.unknown() }),
        execute: async (args) => input.workflowTools?.createPlan?.(args.plan) ?? "Plan tools unavailable."
      }));
    }
    if (input.workflowTools?.instantiatePlan) {
      tools.push(tool({
        name: "plan_instantiate",
        description: "Instantiate a planner-created plan into the current session graph.",
        parameters: z.object({ planId: z.string() }),
        execute: async (args) => input.workflowTools?.instantiatePlan?.(args.planId) ?? "Plan tools unavailable."
      }));
    }
    if (input.workflowTools?.inspectAgents) {
      tools.push(tool({
        name: "agent_state_inspect",
        description: "Inspect the current workflow graph, agent statuses, and active tool calls.",
        parameters: z.object({}),
        execute: async () => JSON.stringify(input.workflowTools?.inspectAgents?.() ?? {})
      }));
    }
    if (input.workflowTools?.readWorkspaceFile) {
      tools.push(tool({
        name: "workspace_read_file",
        description: "Read a file inside the session workspace.",
        parameters: z.object({ path: z.string() }),
        execute: async (args) => input.workflowTools?.readWorkspaceFile?.(args.path) ?? "Read tool unavailable."
      }));
    }
    if (input.workflowTools?.sendAgentMessage) {
      tools.push(tool({
        name: "agent_message_send",
        description: "Send a message to another agent in the current workflow graph.",
        parameters: z.object({ agentId: z.string(), text: z.string() }),
        execute: async (args) => input.workflowTools?.sendAgentMessage?.(args.agentId, args.text) ?? "Messaging tool unavailable."
      }));
    }
    const agent = new Agent({
      name: input.roleName ?? input.agentId,
      instructions: input.instructions ?? "You are a role-specific coding agent in a local multiagent coding workflow. Be concise, operational, and report concrete progress.",
      tools
    });
    const result = await run(agent, input.prompt, {
      signal: input.signal,
      maxTurns: 6,
      toolNotFoundBehavior: "return_error_to_model"
    });
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
    if (input.signal?.aborted) return [statusEvent(input, "cancelled")];
    const plan = deterministicPlan(input.prompt, input.agentId, input.roleName);
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

function deterministicPlan(prompt: string, agentId: string, roleName = agentId) {
  const role = `${agentId} ${roleName}`.toLowerCase();
  if (role.includes("planner")) {
    return {
      toolResult: "Planner selected a workflow and role graph for the user goal.",
      message: "Debug planner: I selected the workflow graph, confirmed role responsibilities, and handed the plan back to the orchestrator."
    };
  }
  if (role.includes("reviewer")) {
    return {
      toolResult: "Reviewer inspected transcript and touched files.",
      message: "Debug reviewer: I found one deterministic follow-up and sent it to the implementor."
    };
  }
  if (role.includes("qa")) {
    return {
      toolResult: "QA ran deterministic acceptance checks.",
      message: "Debug QA: acceptance checks completed; hand back only if a deterministic failure appears."
    };
  }
  if (role.includes("implementor")) {
    return {
      toolResult: "Implementor inspected the assigned workspace and recorded a deterministic file touch.",
      message: "Debug implementor: I applied the assigned implementation step and am ready for review or QA."
    };
  }
  const lower = `${prompt} ${agentId} ${roleName}`.toLowerCase();
  if (lower.includes("planner")) {
    return {
      toolResult: "Planner selected a workflow and role graph for the user goal.",
      message: "Debug planner: I selected the workflow graph, confirmed role responsibilities, and handed the plan back to the orchestrator."
    };
  }
  if (lower.includes("reviewer")) {
    return {
      toolResult: "Reviewer inspected transcript and touched files.",
      message: "Debug reviewer: I found one deterministic follow-up and sent it to the implementor."
    };
  }
  if (lower.includes("qa")) {
    return {
      toolResult: "QA ran deterministic acceptance checks.",
      message: "Debug QA: acceptance checks completed; hand back only if a deterministic failure appears."
    };
  }
  if (lower.includes("implementor")) {
    return {
      toolResult: "Implementor inspected the assigned workspace and recorded a deterministic file touch.",
      message: "Debug implementor: I applied the assigned implementation step and am ready for review or QA."
    };
  }
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
