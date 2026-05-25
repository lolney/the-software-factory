import { Agent, RunContext, run, setDefaultOpenAIClient, tool } from "@openai/agents";
import type { MCPServer } from "@openai/agents";
import type { SessionEvent, SkillCatalogItem } from "@multiagent/shared";
import OpenAI from "openai";
import { readFile } from "node:fs/promises";
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
  openAI?: {
    apiKey: string;
    baseURL?: string;
    defaultHeaders?: Record<string, string>;
  };
  workflowTools?: {
    listWorkflows?: () => unknown;
    createPlan?: (plan: unknown) => Promise<string>;
    instantiatePlan?: (planId: string) => Promise<string>;
    startWorkflow?: (workflowId: string, anchorNodeId?: string) => Promise<string>;
    stopWorkflow?: (workflowInstanceId: string, reason: string) => Promise<string>;
    stopAgent?: (agentId: string, reason: string, artifact?: unknown) => Promise<string>;
    stopSelf?: (reason: string, artifact?: unknown, completedCriteria?: string[]) => Promise<string>;
    inspectAgents?: () => unknown;
    readWorkspaceFile?: (relativePath: string) => Promise<string>;
    writeWorkspaceFile?: (relativePath: string, content: string) => Promise<string>;
    sendAgentMessage?: (agentId: string, text: string) => Promise<string>;
  };
  mcpServers?: MCPServer[];
  skills?: SkillCatalogItem[];
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
    const connection = input.openAI ?? (input.apiKey || process.env.OPENAI_API_KEY ? { apiKey: input.apiKey ?? process.env.OPENAI_API_KEY! } : undefined);
    if (!connection?.apiKey) {
      throw new Error("OpenAI authentication is required for non-debug sessions. Connect OpenAI OAuth in Settings or add an API key.");
    }
    const client = new OpenAI({
      apiKey: connection.apiKey,
      baseURL: connection.baseURL,
      defaultHeaders: connection.defaultHeaders
    }) as unknown as Parameters<typeof setDefaultOpenAIClient>[0];
    setDefaultOpenAIClient(client);

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
        description: "Create a plan made of workflows, agent prompts, and done criteria. Provide planJson as a JSON string matching the workflow engine PlanSpec shape.",
        parameters: z.object({ planJson: z.string() }),
        execute: async (args) => input.workflowTools?.createPlan?.(JSON.parse(args.planJson)) ?? "Plan tools unavailable."
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
    if (input.workflowTools?.startWorkflow) {
      tools.push(tool({
        name: "workflow_start",
        description: "Start a predefined workflow in the current session graph. Returns a workflow instance id that must complete before you can stop.",
        parameters: z.object({ workflowId: z.string(), anchorNodeId: z.string().nullable() }),
        execute: async (args) => input.workflowTools?.startWorkflow?.(args.workflowId, args.anchorNodeId ?? undefined) ?? "Workflow start tool unavailable."
      }));
    }
    if (input.workflowTools?.stopWorkflow) {
      tools.push(tool({
        name: "workflow_stop",
        description: "Stop a workflow instance you started before all agents complete it.",
        parameters: z.object({ workflowInstanceId: z.string(), reason: z.string() }),
        execute: async (args) => input.workflowTools?.stopWorkflow?.(args.workflowInstanceId, args.reason) ?? "Workflow stop tool unavailable."
      }));
    }
    if (input.workflowTools?.stopAgent) {
      tools.push(tool({
        name: "agent_stop",
        description: "Stop an individual agent in the current session graph.",
        parameters: z.object({ agentId: z.string(), reason: z.string(), artifact: z.string().nullable() }),
        execute: async (args) => input.workflowTools?.stopAgent?.(args.agentId, args.reason, args.artifact ?? undefined) ?? "Agent stop tool unavailable."
      }));
    }
    if (input.workflowTools?.stopSelf) {
      tools.push(tool({
        name: "workflow_stop_self",
        description: "Call this when your workflow responsibilities are complete. Include the artifact or summary you are handing back and the completion criteria you satisfied.",
        parameters: z.object({ reason: z.string(), artifact: z.string().nullable(), completedCriteria: z.array(z.string()) }),
        execute: async (args) => input.workflowTools?.stopSelf?.(args.reason, args.artifact ?? undefined, args.completedCriteria) ?? "Stop tool unavailable."
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
    if (input.workflowTools?.writeWorkspaceFile) {
      tools.push(tool({
        name: "workspace_write_file",
        description: "Write a file inside the session workspace through the engine. The engine records a durable diff in the session event log.",
        parameters: z.object({ path: z.string(), content: z.string() }),
        execute: async (args) => input.workflowTools?.writeWorkspaceFile?.(args.path, args.content) ?? "Write tool unavailable."
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
    if (connection.baseURL?.includes("/wham")) {
      return runWhamTurn(input, connection, tools);
    }
    if (input.skills?.length) {
      const skills = input.skills;
      tools.push(tool({
        name: "codex_skill_catalog",
        description: "List installed Codex skills available in this local environment, including names, descriptions, and SKILL.md paths.",
        parameters: z.object({}),
        execute: async () => JSON.stringify(skills)
      }));
      tools.push(tool({
        name: "codex_skill_read",
        description: "Read the SKILL.md instructions for an installed Codex skill by id. Use this before applying a skill.",
        parameters: z.object({ skillId: z.string() }),
        execute: async (args) => {
          const skill = skills.find((candidate) => candidate.id === args.skillId);
          if (!skill) return `Unknown skill ${args.skillId}.`;
          return readFile(skill.path, "utf8");
        }
      }));
    }
    const agent = new Agent({
      name: input.roleName ?? input.agentId,
      instructions: input.instructions ?? "You are a role-specific coding agent in a local multiagent coding workflow. Be concise, operational, and report concrete progress.",
      modelSettings: { store: false },
      toolUseBehavior: input.agentId === "orchestrator" ? "stop_on_first_tool" : "run_llm_again",
      tools,
      mcpServers: input.mcpServers ?? [],
      mcpConfig: {
        includeServerInToolNames: true,
        convertSchemasToStrict: true
      }
    });
    const result = await run(agent, input.prompt, {
      signal: input.signal,
      maxTurns: 16,
      toolNotFoundBehavior: "return_error_to_model",
      stream: true
    });
    await result.completed;
    if (result.error) {
      throw result.error;
    }
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

async function runWhamTurn(
  input: AgentTurnInput,
  connection: NonNullable<AgentTurnInput["openAI"]>,
  tools: Array<Record<string, any>>
): Promise<SessionEvent[]> {
  const events: SessionEvent[] = [statusEvent(input, "working")];
  const callableTools = tools.filter((candidate) => candidate.type === "function" && typeof candidate.invoke === "function");
  const toolByName = new Map(callableTools.map((candidate) => [candidate.name, candidate]));
  const responseTools = callableTools.map((candidate) => ({
    type: "function",
    name: candidate.name,
    description: candidate.description,
    parameters: candidate.parameters,
    strict: candidate.strict
  }));
  const conversation: Array<Record<string, unknown>> = [{
    role: "user",
    content: [{ type: "input_text", text: input.prompt }]
  }];
  const maxTurns = 12;
  for (let turn = 0; turn < maxTurns; turn += 1) {
    const { outputText, functionCalls } = await whamResponsesRequest(connection, {
      model: process.env.MULTIAGENT_WHAM_MODEL ?? "gpt-5.4",
      instructions: input.instructions ?? "You are a role-specific coding agent in a local multiagent coding workflow. Be concise, operational, and report concrete progress.",
      input: conversation,
      tools: responseTools,
      tool_choice: responseTools.length ? "auto" : "none",
      parallel_tool_calls: true,
      store: false,
      stream: true
    });
    if (!functionCalls.length) {
      events.push({
        eventId: makeEventId(),
        sessionId: input.sessionId,
        agentId: input.agentId,
        timestamp: new Date().toISOString(),
        type: "agent.message",
        payload: { text: outputText || "Completed.", runtime: "openai-wham" },
        causationId: input.causationId
      });
      events.push(statusEvent(input, "idle"));
      return events;
    }
    for (const call of functionCalls) {
      const callId = stringValue(call.call_id) ?? stringValue(call.callId) ?? stringValue(call.id) ?? `call_${crypto.randomUUID()}`;
      const toolName = stringValue(call.name) ?? "";
      const args = stringValue(call.arguments) ?? "{}";
      const localTool = toolByName.get(toolName);
      events.push({
        eventId: makeEventId(),
        sessionId: input.sessionId,
        agentId: input.agentId,
        timestamp: new Date().toISOString(),
        type: "agent.tool_call",
        payload: { callId, toolName, input: safeJson(args) },
        causationId: input.causationId
      });
      const output = localTool
        ? String(await localTool.invoke(new RunContext(), args, { toolCall: call as never, signal: input.signal }))
        : `Unknown tool: ${toolName}`;
      events.push({
        eventId: makeEventId(),
        sessionId: input.sessionId,
        agentId: input.agentId,
        timestamp: new Date().toISOString(),
        type: "agent.tool_result",
        payload: { callId, toolName, output },
        causationId: input.causationId
      });
      conversation.push(call);
      conversation.push({ type: "function_call_output", call_id: callId, output });
    }
  }
  throw new Error(`WHAM run exceeded ${maxTurns} turns.`);
}

async function whamResponsesRequest(connection: NonNullable<AgentTurnInput["openAI"]>, body: Record<string, unknown>) {
  const response = await fetch(`${connection.baseURL}/responses`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${connection.apiKey}`,
      "content-type": "application/json",
      ...(connection.defaultHeaders ?? {}),
      session_id: crypto.randomUUID()
    },
    body: JSON.stringify(body)
  });
  if (!response.ok || !response.body) {
    throw new Error(`WHAM Responses request failed with HTTP ${response.status}: ${await response.text()}`);
  }
  const output: string[] = [];
  const functionCalls: Array<Record<string, unknown>> = [];
  let buffer = "";
  const decoder = new TextDecoder();
  for await (const chunk of response.body as unknown as AsyncIterable<Uint8Array>) {
    buffer += decoder.decode(chunk, { stream: true });
    let boundary = buffer.indexOf("\n\n");
    while (boundary >= 0) {
      const frame = buffer.slice(0, boundary);
      buffer = buffer.slice(boundary + 2);
      const data = frame.split("\n").find((line) => line.startsWith("data: "))?.slice(6);
      if (data && data !== "[DONE]") {
        const event = safeJson(data);
        if (isRecord(event)) {
          if (event.type === "response.output_text.delta" && typeof event.delta === "string") {
            output.push(event.delta);
          }
          if (event.type === "response.output_item.done" && isRecord(event.item) && event.item.type === "function_call") {
            functionCalls.push(event.item);
          }
        }
      }
      boundary = buffer.indexOf("\n\n");
    }
  }
  return { outputText: output.join(""), functionCalls };
}

function safeJson(raw: string): unknown {
  try {
    return JSON.parse(raw);
  } catch {
    return raw;
  }
}

function stringValue(value: unknown) {
  return typeof value === "string" ? value : undefined;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
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
