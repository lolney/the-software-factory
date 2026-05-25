import { Agent, OpenAIProvider, RunContext, run, tool } from "@openai/agents";
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
  model?: string;
  reasoningEffort?: "none" | "minimal" | "low" | "medium" | "high" | "xhigh";
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
    inspectAgents?: () => unknown | Promise<unknown>;
    readWorkspaceFile?: (relativePath: string) => Promise<string>;
    writeWorkspaceFile?: (relativePath: string, content: string) => Promise<string>;
    runWorkspaceCommand?: (command: string, args?: string[], cwd?: string) => Promise<string>;
    sendAgentMessage?: (agentId: string, text: string) => Promise<string>;
  };
  mcpServers?: MCPServer[];
  skills?: SkillCatalogItem[];
  signal?: AbortSignal;
  causationId?: string;
  emitEvent?: (event: SessionEvent) => Promise<void>;
}

export interface AgentRuntime {
  runTurn(input: AgentTurnInput): Promise<SessionEvent[]>;
}

type RuntimeTool = any;

interface RuntimeAdapter {
  readonly runtimeName: string;
  runTurn(input: AgentTurnInput, connection: NonNullable<AgentTurnInput["openAI"]>, tools: RuntimeTool[]): Promise<SessionEvent[]>;
}

const defaultInstructions = "You are a role-specific coding agent in a local multiagent coding workflow. Be concise, operational, and report concrete progress.";

export class OpenAIAgentRuntime implements AgentRuntime {
  constructor(private readonly options: { fetch?: typeof fetch; timeoutMs?: number } = {}) {}

  async runTurn(input: AgentTurnInput): Promise<SessionEvent[]> {
    if (input.signal?.aborted) return [statusEvent(input, "cancelled")];
    if (input.debugMode) {
      return new DeterministicAgentRuntime().runTurn(input);
    }
    const connection = input.openAI ?? (input.apiKey || process.env.OPENAI_API_KEY ? { apiKey: input.apiKey ?? process.env.OPENAI_API_KEY! } : undefined);
    if (!connection?.apiKey) {
      throw new Error("OpenAI authentication is required for non-debug sessions. Connect OpenAI OAuth in Settings or add an API key.");
    }

    const tools: RuntimeTool[] = [];
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
        description: "Start a predefined workflow in the current session graph and run it to quiescence before returning. The result includes the created agent ids and completion state.",
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
        execute: async () => JSON.stringify(await input.workflowTools?.inspectAgents?.() ?? {})
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
    if (input.workflowTools?.runWorkspaceCommand) {
      tools.push(tool({
        name: "workspace_run_command",
        description: "Run a command inside the session workspace. Provide the executable as command and arguments as args. Use this for tests, linters, and local verification.",
        parameters: z.object({ command: z.string(), args: z.array(z.string()).default([]), cwd: z.string().nullable() }),
        execute: async (args) => input.workflowTools?.runWorkspaceCommand?.(args.command, args.args, args.cwd ?? undefined) ?? "Command tool unavailable."
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
    const adapter: RuntimeAdapter = connection.baseURL?.includes("/wham")
      ? new WhamCompatibilityAdapter(this.options)
      : new AgentsSdkRuntimeAdapter(this.options);
    return adapter.runTurn(input, connection, tools);
  }
}

class AgentsSdkRuntimeAdapter implements RuntimeAdapter {
  readonly runtimeName = "openai-agents";

  constructor(private readonly options: { timeoutMs?: number } = {}) {}

  async runTurn(input: AgentTurnInput, connection: NonNullable<AgentTurnInput["openAI"]>, tools: RuntimeTool[]): Promise<SessionEvent[]> {
    const startedAt = new Date().toISOString();
    const startedMs = Date.now();
    const client = new OpenAI({
      apiKey: connection.apiKey,
      baseURL: connection.baseURL,
      defaultHeaders: connection.defaultHeaders
    });
    const provider = new OpenAIProvider({ openAIClient: client as never, cacheResponsesWebSocketModels: false });

    const agent = new Agent({
      name: input.roleName ?? input.agentId,
      instructions: input.instructions ?? defaultInstructions,
      model: input.model,
      modelSettings: { store: false, reasoning: input.reasoningEffort ? { effort: input.reasoningEffort } : undefined },
      toolUseBehavior: input.agentId === "orchestrator" ? "stop_on_first_tool" : "run_llm_again",
      tools,
      mcpServers: input.mcpServers ?? [],
      mcpConfig: {
        includeServerInToolNames: true,
        convertSchemasToStrict: true
      }
    });
    const signal = combinedSignal(input.signal, this.options.timeoutMs ?? 120_000);
    const runOptions: any = {
      signal,
      modelProvider: provider,
      toolNotFoundBehavior: "return_error_to_model",
      stream: true
    };
    if (input.agentId !== "orchestrator") {
      runOptions.maxTurns = 24;
    }
    try {
      const { result, attempts } = await retryOpenAIRun(async () => {
        const result: any = await run(agent, input.prompt, runOptions);
        await result.completed;
        if (result.error) {
          throw result.error;
        }
        return result;
      }, signal);
      const output = String(result.finalOutput ?? "");
      return [
        statusEvent(input, "working", startedAt),
        {
          eventId: makeEventId(),
          sessionId: input.sessionId,
          agentId: input.agentId,
          timestamp: new Date().toISOString(),
          type: "agent.message",
          payload: {
            text: output,
            runtime: this.runtimeName,
            model: input.model,
            reasoningEffort: input.reasoningEffort,
            attempts,
            durationMs: Date.now() - startedMs
          },
          causationId: input.causationId
        },
        statusEvent(input, "idle")
      ];
    } finally {
      await provider.close();
    }
  }
}

class WhamCompatibilityAdapter implements RuntimeAdapter {
  readonly runtimeName = "openai-wham";

  constructor(private readonly options: { fetch?: typeof fetch; timeoutMs?: number } = {}) {}

  runTurn(input: AgentTurnInput, connection: NonNullable<AgentTurnInput["openAI"]>, tools: RuntimeTool[]) {
    return runWhamTurn(input, connection, tools, this.options);
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
  tools: RuntimeTool[],
  options: { fetch?: typeof fetch; timeoutMs?: number } = {}
): Promise<SessionEvent[]> {
  const events: SessionEvent[] = [];
  await emitOrCollect(input, events, statusEvent(input, "working"));
  const startedMs = Date.now();
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
  const usageSamples: unknown[] = [];
  let totalAttempts = 0;
  let totalRequestDurationMs = 0;
  const maxTurns = input.agentId === "orchestrator" ? Number.POSITIVE_INFINITY : 24;
  for (let turn = 0; turn < maxTurns; turn += 1) {
    if (input.signal?.aborted) {
      await emitOrCollect(input, events, statusEvent(input, "cancelled"));
      return events;
    }
    const { outputText, functionCalls, usage, attempts, durationMs } = await whamResponsesRequest(connection, {
      model: input.model ?? process.env.MULTIAGENT_WHAM_MODEL ?? "gpt-5.4",
      ...(input.reasoningEffort ? { reasoning: { effort: input.reasoningEffort } } : {}),
      instructions: input.instructions ?? defaultInstructions,
      input: conversation,
      tools: responseTools,
      tool_choice: responseTools.length ? "auto" : "none",
      parallel_tool_calls: true,
      store: false,
      stream: true
    }, { fetch: options.fetch, signal: input.signal, timeoutMs: options.timeoutMs });
    totalAttempts += attempts;
    totalRequestDurationMs += durationMs;
    if (usage !== undefined) {
      usageSamples.push(usage);
    }
    if (!functionCalls.length) {
      await emitOrCollect(input, events, {
        eventId: makeEventId(),
        sessionId: input.sessionId,
        agentId: input.agentId,
        timestamp: new Date().toISOString(),
        type: "agent.message",
        payload: {
          text: outputText || "Completed.",
          runtime: "openai-wham",
          model: input.model ?? process.env.MULTIAGENT_WHAM_MODEL ?? "gpt-5.4",
          reasoningEffort: input.reasoningEffort,
          usage,
          usageSamples,
          attempts: totalAttempts,
          requestDurationMs: totalRequestDurationMs,
          durationMs: Date.now() - startedMs
        },
        causationId: input.causationId
      });
      await emitOrCollect(input, events, statusEvent(input, "idle"));
      return events;
    }
    for (const call of functionCalls) {
      const callId = stringValue(call.call_id) ?? stringValue(call.callId) ?? stringValue(call.id) ?? `call_${crypto.randomUUID()}`;
      const toolName = stringValue(call.name) ?? "";
      const args = stringValue(call.arguments) ?? "{}";
      const localTool = toolByName.get(toolName);
      await emitOrCollect(input, events, {
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
      await emitOrCollect(input, events, {
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

async function emitOrCollect(input: AgentTurnInput, events: SessionEvent[], event: SessionEvent) {
  if (input.emitEvent) {
    await input.emitEvent(event);
    return;
  }
  events.push(event);
}

async function whamResponsesRequest(
  connection: NonNullable<AgentTurnInput["openAI"]>,
  body: Record<string, unknown>,
  options: { fetch?: typeof fetch; signal?: AbortSignal; timeoutMs?: number } = {}
) {
  const requestBody = JSON.stringify(body);
  let response: Response | undefined;
  let lastError: unknown;
  const maxAttempts = 5;
  const fetchImpl = options.fetch ?? fetch;
  const startedMs = Date.now();
  let attempts = 0;
  for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
    attempts = attempt + 1;
    const timeout = AbortSignal.timeout(options.timeoutMs ?? 120_000);
    const signal = options.signal ? AbortSignal.any([options.signal, timeout]) : timeout;
    try {
      response = await fetchImpl(`${connection.baseURL}/responses`, {
        method: "POST",
        headers: {
          authorization: `Bearer ${connection.apiKey}`,
          "content-type": "application/json",
          ...(connection.defaultHeaders ?? {}),
          session_id: crypto.randomUUID()
        },
        body: requestBody,
        signal
      });
      if (response.ok || !isRetryableStatus(response.status)) break;
      lastError = `HTTP ${response.status}: ${await response.text()}`;
    } catch (error) {
      if (options.signal?.aborted || isAbortError(error)) {
        throw error;
      }
      lastError = error;
    }
    if (attempt < maxAttempts - 1) {
      await sleep(500 * 2 ** attempt);
    }
  }
  if (!response) {
    throw new Error(`WHAM Responses request failed: ${lastError instanceof Error ? lastError.message : String(lastError)}`);
  }
  if (!response.ok || !response.body) {
    const errorText = !response.ok && isRetryableStatus(response.status) && lastError
      ? String(lastError)
      : await response.text();
    throw new Error(`WHAM Responses request failed with HTTP ${response.status}: ${errorText}`);
  }
  const output: string[] = [];
  const functionCalls: Array<Record<string, unknown>> = [];
  let usage: unknown;
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
          if (event.type === "response.completed" && isRecord(event.response) && "usage" in event.response) {
            usage = event.response.usage;
          }
        }
      }
      boundary = buffer.indexOf("\n\n");
    }
  }
  return { outputText: output.join(""), functionCalls, usage, attempts, durationMs: Date.now() - startedMs };
}

function isRetryableStatus(status: number) {
  return status === 429 || status === 502 || status === 503 || status === 504;
}

async function retryOpenAIRun<T>(runOnce: () => Promise<T>, signal?: AbortSignal) {
  let lastError: unknown;
  const maxAttempts = 3;
  for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
    if (signal?.aborted) throw signal.reason ?? new Error("OpenAI run aborted.");
    try {
      return { result: await runOnce(), attempts: attempt + 1 };
    } catch (error) {
      if (signal?.aborted || isAbortError(error) || !isRetryableError(error) || attempt === maxAttempts - 1) {
        throw error;
      }
      lastError = error;
      await sleep(500 * 2 ** attempt);
    }
  }
  throw lastError instanceof Error ? lastError : new Error(String(lastError));
}

function combinedSignal(signal: AbortSignal | undefined, timeoutMs: number) {
  const timeout = AbortSignal.timeout(timeoutMs);
  return signal ? AbortSignal.any([signal, timeout]) : timeout;
}

function isRetryableError(error: unknown) {
  const value = error as { status?: unknown; code?: unknown; message?: unknown };
  if (typeof value.status === "number" && isRetryableStatus(value.status)) return true;
  const text = `${String(value.code ?? "")} ${String(value.message ?? "")}`;
  return /\b(429|502|503|504|ECONNRESET|ETIMEDOUT|timeout|temporar|rate limit)\b/i.test(text);
}

function isAbortError(error: unknown) {
  const value = error as { name?: unknown; code?: unknown };
  return value?.name === "AbortError" || value?.code === "ABORT_ERR";
}

function sleep(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
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
