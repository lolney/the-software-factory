import { PlanSpecSchema, type DaemonRequest, type DebugLogEntry, type DebugLogLevel, type PlanSpec, type SessionEvent } from "@multiagent/shared";
import { type GraphState, type SessionSnapshot } from "@multiagent/shared";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import path from "node:path";
import { EventStore, makeEventId, makeLogId } from "./eventStore.js";
import { OpenAIAgentRuntime, type AgentRuntime } from "./agentRuntime.js";
import { WorkflowEngine } from "./workflowEngine.js";
import { WorkspaceCoordinator } from "./workspaceCoordinator.js";
import { AuthManager, CODEX_PUBLIC_CLIENT_ID } from "./authManager.js";
import { CodexIntegrationManager } from "./codexIntegrationManager.js";

const execFileAsync = promisify(execFile);

export class SessionManager {
  private readonly subscribers = new Map<string, Set<(event: SessionEvent) => void>>();
  private readonly logSubscribers = new Map<string, Set<(entry: DebugLogEntry) => void>>();
  private readonly store: EventStore;
  private readonly runtime: AgentRuntime;
  private readonly workflows = new WorkflowEngine();
  private readonly workspace = new WorkspaceCoordinator();
  private readonly integrations = new CodexIntegrationManager();
  private readonly activeRuns = new Map<string, AbortController>();
  private readonly auth = new AuthManager();
  private roleOverridesLoaded = false;

  constructor(private readonly options: { sessionsRoot: string; runtime?: AgentRuntime }) {
    this.store = new EventStore(options.sessionsRoot);
    this.runtime = options.runtime ?? new OpenAIAgentRuntime();
  }

  setPublisher(publish: (event: SessionEvent) => void) {
    this.subscribers.set("*", new Set([publish]));
  }

  async handle(
    request: DaemonRequest,
    publish: (event: SessionEvent) => void = () => {},
    publishLog: (entry: DebugLogEntry) => void = () => {}
  ): Promise<unknown> {
    await this.workflows.loadPredefined();
    await this.loadRoleOverrides();
    switch (request.method) {
      case "listSessions":
        return {
          sessionsRoot: this.options.sessionsRoot,
          workflows: this.workflows.list(),
          roles: this.workflows.listRoles(),
          codexOAuth: await this.auth.status(),
          integrations: await this.integrations.listCatalog(),
          sessions: await this.store.listSessions()
        };
      case "getAuthStatus":
        return this.auth.status();
      case "beginOpenAIOAuth":
        return this.auth.beginOAuth(request.params.port);
      case "disconnectOpenAIOAuth":
        await this.auth.deleteTokens();
        return this.auth.status();
      case "listRoles":
        return { roles: this.workflows.listRoles() };
      case "upsertRole":
        this.workflows.upsertRole(request.params.role);
        await this.saveRoleOverrides();
        return { roles: this.workflows.listRoles() };
      case "deleteRole":
        this.workflows.deleteRole(request.params.roleId);
        await this.saveRoleOverrides();
        return { roles: this.workflows.listRoles() };
      case "listWorkflows":
        return { workflows: this.workflows.list() };
      case "listIntegrations":
        return this.integrations.listCatalog();
      case "beginMCPAuth":
        return this.integrations.beginMCPAuth(request.params.serverId);
      case "reconnectMCPServers":
        return this.integrations.reconnectMCPServers({ serverId: request.params.serverId });
      case "createSession": {
        const sessionId = `sess_${crypto.randomUUID()}`;
        const title = firstLine(request.params.prompt) || "Untitled Session";
        const spec = this.workflows.get(request.params.workflowId ?? "planner-orchestrator");
        const graph: GraphState = this.workflows.graphForSession(sessionId, spec);
        const workspaceRoot = await this.store.workspaceDir(sessionId, request.params.workspaceRoot);
        if (!request.params.debugMode) {
          await this.assertLiveCredentialAvailable();
        }
        const snapshot = await this.store.createSession({
          sessionId,
          title,
          goal: request.params.prompt,
          workspaceRoot,
          workflowId: spec.id,
          debugMode: request.params.debugMode,
          graph
        });
        for (const event of snapshot.transcript) {
          await this.logEvent(event, publishLog);
        }
        await this.initializeWorkspace(workspaceRoot, title);
        await this.appendDebugLog(snapshot.sessionId, "info", "workspace", `Initialized workspace at ${workspaceRoot}`, { workspaceRoot }, publishLog);
        await this.recordOrchestratorTurn(snapshot, request.params.prompt, request.params.debugMode, publish);
        await this.activateWorkflowStart(await this.store.readSnapshot(sessionId), publish);
        return this.store.readSnapshot(sessionId);
      }
      case "getSnapshot":
        await this.store.assertSessionExists(request.params.sessionId);
        return this.store.readSnapshot(request.params.sessionId);
      case "sendMessage": {
        await this.store.assertSessionExists(request.params.sessionId);
        const snapshot = await this.store.readSnapshot(request.params.sessionId);
        const targetAgentId = request.params.targetAgentId ?? "orchestrator";
        this.assertAgentCanReceive(snapshot, targetAgentId);
        const nudge = await this.appendAndPublish({
          eventId: makeEventId(),
          sessionId: request.params.sessionId,
          agentId: targetAgentId,
          timestamp: new Date().toISOString(),
          type: "control.nudge",
          payload: { text: request.params.text }
        }, publish);
        await this.recordAgentTurn(snapshot, targetAgentId, request.params.text, snapshot.debugMode, publish, nudge.eventId);
        return this.store.readSnapshot(request.params.sessionId);
      }
      case "subscribeEvents":
        await this.store.assertSessionExists(request.params.sessionId);
        this.addSubscriber(request.params.sessionId, publish);
        return { events: await this.store.readEvents(request.params.sessionId) };
      case "subscribeDebugLogs":
        await this.store.assertSessionExists(request.params.sessionId);
        this.addLogSubscriber(request.params.sessionId, publishLog);
        return { logs: await this.store.readDebugLogs(request.params.sessionId) };
      case "pauseAgent":
        await this.store.assertSessionExists(request.params.sessionId);
        return this.controlEvent(request.params.sessionId, request.params.agentId, "control.pause", "paused", publish);
      case "resumeAgent":
        await this.store.assertSessionExists(request.params.sessionId);
        return this.controlEvent(request.params.sessionId, request.params.agentId, "control.resume", "idle", publish);
      case "cancelAgent":
        await this.store.assertSessionExists(request.params.sessionId);
        return this.controlEvent(request.params.sessionId, request.params.agentId, "control.cancel", "cancelled", publish);
      case "ackClientEvent":
        await this.store.assertSessionExists(request.params.sessionId);
        await this.appendAndPublish({
          eventId: makeEventId(),
          sessionId: request.params.sessionId,
          timestamp: new Date().toISOString(),
          type: "client.ack",
          payload: { ackedEventId: request.params.eventId }
        }, publish);
        return this.store.rebuildSnapshot(request.params.sessionId);
      case "instantiateWorkflow":
        return this.instantiateWorkflow(request.params.sessionId, request.params.workflowId, request.params.anchorNodeId, publish);
    }
  }

  async logErrorForSession(sessionId: string, message: string, payload: Record<string, unknown>, publishLog: (entry: DebugLogEntry) => void = () => {}) {
    await this.appendDebugLog(sessionId, "error", "protocol", message, payload, publishLog);
  }

  async completeOAuthCallback(callbackUrl: string) {
    return this.auth.completeOAuthCallback(callbackUrl);
  }

  emit(event: SessionEvent) {
    this.publish(event);
  }

  private async recordOrchestratorTurn(
    snapshot: SessionSnapshot,
    userText: string,
    debugMode: boolean,
    publish: (event: SessionEvent) => void,
    causationId?: string
  ) {
    await this.recordAgentTurn(snapshot, "orchestrator", userText, debugMode, publish, causationId);
  }

  private async recordAgentTurn(
    snapshot: SessionSnapshot,
    agentId: string,
    userText: string,
    debugMode: boolean,
    publish: (event: SessionEvent) => void,
    causationId?: string
  ) {
    const promptEvent = await this.appendAndPublish({
      eventId: makeEventId(),
      sessionId: snapshot.sessionId,
      agentId,
      timestamp: new Date().toISOString(),
      type: "message.sent",
      payload: {
        from: "user",
        to: agentId,
        text: userText
      },
      causationId
    }, publish);
    const role = this.resolveRole(snapshot, agentId);
    const integrationCatalog = await this.integrations.listCatalog();
    const events = await this.runControlledTurn(snapshot.sessionId, agentId, {
      sessionId: snapshot.sessionId,
      agentId,
      prompt: userText,
      debugMode,
      roleName: role?.name,
      instructions: role?.promptTemplate,
      apiKey: await this.openAIApiKey(debugMode),
      workflowTools: this.workflowTools(snapshot, agentId, publish),
      mcpServers: debugMode || this.options.runtime ? [] : await this.mcpServersForRole(role),
      skills: integrationCatalog.skills,
      causationId: promptEvent.eventId
    });
    for (const event of events) {
      await this.appendAndPublish(event, publish);
    }
    await this.store.rebuildSnapshot(snapshot.sessionId);
  }

  private async controlEvent(
    sessionId: string,
    agentId: string,
    type: SessionEvent["type"],
    status: string,
    publish: (event: SessionEvent) => void
  ) {
    if (type === "control.cancel") {
      this.activeRuns.get(runKey(sessionId, agentId))?.abort();
    }
    const control = await this.appendAndPublish({
      eventId: makeEventId(),
      sessionId,
      agentId,
      timestamp: new Date().toISOString(),
      type,
      payload: {}
    }, publish);
    await this.appendAndPublish({
      eventId: makeEventId(),
      sessionId,
      agentId,
      timestamp: new Date().toISOString(),
      type: "agent.status",
      payload: { status },
      causationId: control.eventId
    }, publish);
    return this.store.rebuildSnapshot(sessionId);
  }

  private async appendAndPublish(event: SessionEvent, publish: (event: SessionEvent) => void = () => {}) {
    const appended = await this.store.append(event);
    await this.logEvent(appended);
    publish(appended);
    this.publish(appended, publish);
    return appended;
  }

  private async appendDebugLog(
    sessionId: string,
    level: DebugLogLevel,
    source: string,
    message: string,
    payload: Record<string, unknown> = {},
    publishLog: (entry: DebugLogEntry) => void = () => {},
    agentId?: string,
    causationId?: string
  ) {
    const entry = await this.store.appendDebugLog({
      logId: makeLogId(),
      sessionId,
      timestamp: new Date().toISOString(),
      level,
      source,
      agentId,
      message,
      payload,
      causationId
    });
    publishLog(entry);
    this.publishLog(entry, publishLog);
    return entry;
  }

  private async logEvent(event: SessionEvent, publishLog: (entry: DebugLogEntry) => void = () => {}) {
    const level: DebugLogLevel = event.type === "error" ? "error" : "info";
    const message = event.type === "error"
      ? String(event.payload.message ?? "Session error")
      : `event ${event.type}`;
    await this.appendDebugLog(
      event.sessionId,
      level,
      "session-event",
      message,
      { eventType: event.type, eventId: event.eventId, payload: event.payload },
      publishLog,
      event.agentId,
      event.eventId
    );
  }

  private async activateWorkflowStart(snapshot: SessionSnapshot, publish: (event: SessionEvent) => void) {
    const spec = this.workflows.get(snapshot.workflowId);
    const orchestratorId = spec.lifecycle.orchestratorNodeId;
    const runCounts = new Map<string, number>([[orchestratorId, 1]]);
    const processedHandoffs = new Set<string>();
    const maxConcurrent = Math.max(1, spec.concurrency.maxActiveAgents);
    const maxIterationsPerAgent = 2;
    const initialGraphSize = snapshot.graph.nodes.length + snapshot.graph.edges.length + 1;
    const maxSteps = Math.max(1, initialGraphSize * maxIterationsPerAgent * 2);
    let instantiatedPlanDuringActivation = false;

    for (let step = 0; step < maxSteps; step += 1) {
      snapshot = await this.store.readSnapshot(snapshot.sessionId);
      const graph = snapshot.graph;
      const readyHandoffs = graph.edges
        .filter((edge) => edge.kind === "handoff")
        .filter((edge) => (runCounts.get(edge.from) ?? 0) > 0 && !processedHandoffs.has(edge.id))
        .filter((edge) => this.canSchedule(snapshot, edge.from) && this.canSchedule(snapshot, edge.to));
      if (readyHandoffs.length > 0) {
        const batch = readyHandoffs.slice(0, maxConcurrent);
        await Promise.all(batch.map(async (edge) => {
          processedHandoffs.add(edge.id);
          const transition = await this.promptForWorkflowEdge(snapshot, edge.from, edge.to, edge.id, this.edgeDescription(snapshot.workflowId, edge.id), step === 0 ? "workflow start" : "workflow graph continuation");
          const handoff = await this.appendAndPublish({
            eventId: makeEventId(),
            sessionId: snapshot.sessionId,
            agentId: edge.from,
            timestamp: new Date().toISOString(),
            type: "handoff.created",
            payload: {
              ...transition
            }
          }, publish);
          await this.appendAndPublish({
            eventId: makeEventId(),
            sessionId: snapshot.sessionId,
            agentId: edge.to,
            timestamp: new Date().toISOString(),
            type: "agent.status",
            payload: { status: snapshot.debugMode ? "waiting" : "working" },
            causationId: handoff.eventId
          }, publish);
          if (edge.to !== orchestratorId) {
            await this.runWorkflowAgent(snapshot, edge.to, transition.prompt, handoff.eventId, publish);
            runCounts.set(edge.to, (runCounts.get(edge.to) ?? 0) + 1);
          }
        }));
        continue;
      }

      const readyMessages = graph.edges
        .filter((edge) => edge.kind === "message")
        .filter((edge) => (runCounts.get(edge.from) ?? 0) > 0 && (runCounts.get(edge.to) ?? 0) < maxIterationsPerAgent)
        .filter((edge) => this.canSchedule(snapshot, edge.from) && this.canSchedule(snapshot, edge.to));
      if (readyMessages.length === 0) break;
      const batch = readyMessages.slice(0, maxConcurrent);
      await Promise.all(batch.map(async (edge) => {
        const message = await this.appendAndPublish({
          eventId: makeEventId(),
          sessionId: snapshot.sessionId,
          agentId: edge.from,
          timestamp: new Date().toISOString(),
          type: "message.sent",
          payload: {
            ...(await this.promptForWorkflowEdge(snapshot, edge.from, edge.to, edge.id, this.edgeDescription(snapshot.workflowId, edge.id), "workflow message"))
          }
        }, publish);
        if (edge.to !== orchestratorId) {
          await this.appendAndPublish({
            eventId: makeEventId(),
            sessionId: snapshot.sessionId,
            agentId: edge.to,
            timestamp: new Date().toISOString(),
            type: "agent.status",
            payload: { status: snapshot.debugMode ? "waiting" : "working" },
            causationId: message.eventId
          }, publish);
          await this.runWorkflowAgent(snapshot, edge.to, String(message.payload.prompt ?? message.payload.text), message.eventId, publish);
          runCounts.set(edge.to, (runCounts.get(edge.to) ?? 0) + 1);
        } else {
          const plan = await this.latestUninstantiatedPlan(snapshot.sessionId);
          if (plan) {
            await this.instantiatePlan(snapshot.sessionId, plan.id, orchestratorId, publish);
            runCounts.set(orchestratorId, (runCounts.get(orchestratorId) ?? 0) + 1);
            instantiatedPlanDuringActivation = true;
          }
        }
      }));
      if (instantiatedPlanDuringActivation) break;
    }

    const stopSummary = spec.stopCriteria.length > 0 ? spec.stopCriteria.join("; ") : "workflow graph reached quiescence";
    snapshot = await this.store.readSnapshot(snapshot.sessionId);
    if (!this.canSchedule(snapshot, orchestratorId)) {
      await this.store.rebuildSnapshot(snapshot.sessionId);
      return;
    }
    await this.appendAndPublish({
      eventId: makeEventId(),
      sessionId: snapshot.sessionId,
      agentId: orchestratorId,
      timestamp: new Date().toISOString(),
      type: "agent.message",
      payload: {
        text: `Orchestrator evaluated stop criteria: ${stopSummary}. Current alpha run is quiescent.`,
        runtime: "workflow-engine"
      }
    }, publish);
    await this.appendAndPublish({
      eventId: makeEventId(),
      sessionId: snapshot.sessionId,
      agentId: orchestratorId,
      timestamp: new Date().toISOString(),
      type: "agent.status",
      payload: { status: "idle" }
    }, publish);
    await this.store.rebuildSnapshot(snapshot.sessionId);
  }

  private async runWorkflowAgent(
    snapshot: SessionSnapshot,
    agentId: string,
    prompt: string,
    causationId: string,
    publish: (event: SessionEvent) => void
  ) {
    const role = this.resolveRole(snapshot, agentId);
    const integrationCatalog = await this.integrations.listCatalog();
    const events = await this.runControlledTurn(snapshot.sessionId, agentId, {
      sessionId: snapshot.sessionId,
      agentId,
      prompt,
      debugMode: snapshot.debugMode,
      roleName: role?.name,
      instructions: role?.promptTemplate,
      apiKey: await this.openAIApiKey(snapshot.debugMode),
      workflowTools: this.workflowTools(snapshot, agentId, publish),
      mcpServers: snapshot.debugMode || this.options.runtime ? [] : await this.mcpServersForRole(role),
      skills: integrationCatalog.skills,
      causationId
    });
    for (const event of events) {
      await this.appendAndPublish(event, publish);
    }
    if (role?.toolPolicy.canCreatePlans) {
      await this.createPlanForSession(snapshot, agentId, causationId, publish);
    } else if (snapshot.debugMode) {
      await this.applyDeterministicRoleWork(snapshot, agentId, causationId, publish);
    }
    await this.store.rebuildSnapshot(snapshot.sessionId);
  }

  private assertAgentCanReceive(snapshot: SessionSnapshot, agentId: string) {
    const node = snapshot.graph.nodes.find((candidate) => candidate.id === agentId);
    if (!node) {
      throw new Error(`Unknown agent ${agentId} in session ${snapshot.sessionId}`);
    }
    if (["paused", "cancelled", "failed", "completed"].includes(node.status)) {
      throw new Error(`Agent ${agentId} cannot receive messages while ${node.status}.`);
    }
  }

  private async createPlanForSession(snapshot: SessionSnapshot, agentId: string, causationId: string, publish: (event: SessionEvent) => void) {
    if ((await this.plansForSession(snapshot.sessionId)).length > 0) return;
    const goal = await this.sessionGoal(snapshot.sessionId, snapshot.title);
    const plan = PlanSpecSchema.parse({
      version: 1,
      id: `plan_${crypto.randomUUID()}`,
      name: "Build, review, and QA the requested CLI",
      description: "Planner-selected plan that delegates implementation, review, and acceptance checks to workflow agents.",
      goal,
      workflows: [
        {
          workflowId: "implementation-review-qa",
          agentPrompts: {
            implementor: `Implement the requested coding task in the session workspace. Goal: ${goal}`,
            reviewer: "Review the implementation for correctness, CLI behavior, and test coverage. Send actionable findings to the implementor.",
            qa: "Run acceptance checks for the generated CLI and report pass/fail with the commands used."
          },
          doneCriteria: {
            implementor: ["Creates runnable source files inside the workspace", "Records touched files"],
            reviewer: ["Reviews transcript and touched files", "Reports no blocking findings or clear fixes"],
            qa: ["Runs deterministic acceptance checks", "Reports passing output"]
          }
        }
      ],
      globalDoneCriteria: ["All planned workflows are instantiated", "Implementation exists in the workspace", "QA reports acceptance"]
    });
    await this.appendAndPublish({
      eventId: makeEventId(),
      sessionId: snapshot.sessionId,
      agentId,
      timestamp: new Date().toISOString(),
      type: "plan.created",
      payload: { plan, workflowSpecs: this.workflowSpecsForPlan(plan) },
      causationId
    }, publish);
  }

  private async applyDeterministicRoleWork(snapshot: SessionSnapshot, agentId: string, causationId: string, publish: (event: SessionEvent) => void) {
    const role = this.resolveRole(snapshot, agentId);
    const roleId = role?.id ?? snapshot.graph.nodes.find((node) => node.id === agentId)?.roleId ?? agentId;
    if (roleId === "implementor") {
      await this.writeTemperatureConverter(snapshot, agentId, causationId, publish);
    } else if (roleId === "reviewer") {
      await this.appendAndPublish({
        eventId: makeEventId(),
        sessionId: snapshot.sessionId,
        agentId,
        timestamp: new Date().toISOString(),
        type: "message.sent",
        payload: {
          from: agentId,
          to: this.firstNodeForRole(snapshot, "implementor") ?? "implementor",
          text: "Review complete: converter formulas, CLI parsing, and unit tests are covered. No blocking findings."
        },
        causationId
      }, publish);
    } else if (roleId === "qa") {
      await this.runTemperatureConverterQA(snapshot, agentId, causationId, publish);
    }
  }

  private async writeTemperatureConverter(snapshot: SessionSnapshot, agentId: string, causationId: string, publish: (event: SessionEvent) => void) {
    const role = this.resolveRole(snapshot, agentId);
    if (!role?.toolPolicy.canWrite) {
      throw new Error(`Agent ${agentId} is not allowed to write files.`);
    }
    const files = new Map([
      ["temperature_converter.py", temperatureConverterProgram()],
      ["test_temperature_converter.py", temperatureConverterTests()]
    ]);
    for (const [relativePath, content] of files) {
      await this.writeWorkspaceFile(snapshot, agentId, relativePath, content, causationId, publish);
    }
    await this.appendAndPublish({
      eventId: makeEventId(),
      sessionId: snapshot.sessionId,
      agentId,
      timestamp: new Date().toISOString(),
      type: "agent.message",
      payload: {
        text: "Implemented temperature_converter.py with celsius/fahrenheit conversion helpers, a CLI, and unittest coverage.",
        runtime: "workflow-engine"
      },
      causationId
    }, publish);
  }

  private async writeWorkspaceFile(
    snapshot: SessionSnapshot,
    agentId: string,
    relativePath: string,
    content: string,
    causationId: string | undefined,
    publish: (event: SessionEvent) => void
  ) {
    const role = this.resolveRole(snapshot, agentId);
    if (!role?.toolPolicy.canWrite) {
      throw new Error(`Agent ${agentId} is not allowed to write files.`);
    }
    const policy = { sessionId: snapshot.sessionId, workspaceRoot: snapshot.workspaceRoot, allowedRoots: role.workspace.allowedRoots };
    const absolutePath = this.workspace.assertAllowed(policy, relativePath);
    const callId = `call_${crypto.randomUUID()}`;
    const before = existsSync(absolutePath) ? await readFile(absolutePath, "utf8") : "";
    await this.appendAndPublish({
      eventId: makeEventId(),
      sessionId: snapshot.sessionId,
      agentId,
      timestamp: new Date().toISOString(),
      type: "agent.tool_call",
      payload: { callId, toolName: "workspace.write_file", input: { path: relativePath } },
      causationId
    }, publish);
    await mkdir(path.dirname(absolutePath), { recursive: true });
    await writeFile(absolutePath, content, "utf8");
    const diff = unifiedDiff(relativePath, before, content);
    const stats = diffStats(diff);
    await this.appendAndPublish(this.workspace.claimFile(policy, agentId, relativePath), publish);
    await this.appendAndPublish(this.workspace.recordTouched(policy, agentId, relativePath, "write", diff, stats), publish);
    await this.appendAndPublish({
      eventId: makeEventId(),
      sessionId: snapshot.sessionId,
      agentId,
      timestamp: new Date().toISOString(),
      type: "agent.tool_result",
      payload: { callId, toolName: "workspace.write_file", output: `Wrote ${absolutePath}`, diff, diffStats: stats, path: relativePath },
      causationId
    }, publish);
    return `Edited ${relativePath} +${stats.additions} -${stats.deletions}.`;
  }

  private async runTemperatureConverterQA(snapshot: SessionSnapshot, agentId: string, causationId: string, publish: (event: SessionEvent) => void) {
    const role = this.resolveRole(snapshot, agentId);
    if (!role?.toolPolicy.canRunCommands) {
      throw new Error(`Agent ${agentId} is not allowed to run commands.`);
    }
    const callId = `call_${crypto.randomUUID()}`;
    await this.appendAndPublish({
      eventId: makeEventId(),
      sessionId: snapshot.sessionId,
      agentId,
      timestamp: new Date().toISOString(),
      type: "agent.tool_call",
      payload: { callId, toolName: "workspace.run_command", input: { command: "python3 -m unittest test_temperature_converter.py" } },
      causationId
    }, publish);
    const result = await execFileAsync("python3", ["-m", "unittest", "test_temperature_converter.py"], { cwd: snapshot.workspaceRoot });
    await this.appendAndPublish({
      eventId: makeEventId(),
      sessionId: snapshot.sessionId,
      agentId,
      timestamp: new Date().toISOString(),
      type: "agent.tool_result",
      payload: {
        callId,
        toolName: "workspace.run_command",
        output: `${result.stdout}${result.stderr}`
      },
      causationId
    }, publish);
    await this.appendAndPublish({
      eventId: makeEventId(),
      sessionId: snapshot.sessionId,
      agentId,
      timestamp: new Date().toISOString(),
      type: "agent.message",
      payload: {
        text: "QA acceptance passed: python3 -m unittest test_temperature_converter.py completed successfully.",
        runtime: "workflow-engine"
      },
      causationId
    }, publish);
  }

  private async instantiateWorkflow(
    sessionId: string,
    workflowId: string,
    anchorNodeId = "orchestrator",
    publish: (event: SessionEvent) => void
  ) {
    return (await this.instantiateWorkflowGraph(sessionId, workflowId, anchorNodeId, publish)).snapshot;
  }

  private async instantiateWorkflowGraph(
    sessionId: string,
    workflowId: string,
    anchorNodeId: string,
    publish: (event: SessionEvent) => void,
    causationId?: string
  ) {
    await this.store.assertSessionExists(sessionId);
    const snapshot = await this.store.readSnapshot(sessionId);
    const spec = this.workflows.get(workflowId);
    const subgraph = this.workflows.graphForSession(sessionId, spec);
    const existingNodeIds = new Set(snapshot.graph.nodes.map((node) => node.id));
    const existingEdgeIds = new Set(snapshot.graph.edges.map((edge) => edge.id));
    const nodeMap = new Map<string, string>();
    const newNodes: GraphState["nodes"] = [];
    for (const node of subgraph.nodes) {
      if (node.roleId === "orchestrator" || node.id === spec.lifecycle.orchestratorNodeId) {
        nodeMap.set(node.id, anchorNodeId);
        continue;
      }
      const mappedId = uniqueId(`${workflowId}_${node.id}`, existingNodeIds);
      existingNodeIds.add(mappedId);
      nodeMap.set(node.id, mappedId);
      newNodes.push({ ...node, id: mappedId, status: "idle", unreadCount: 0, errorCount: 0 });
    }
    const newEdges: GraphState["edges"] = [];
    for (const edge of subgraph.edges) {
      const from = nodeMap.get(edge.from) ?? edge.from;
      const to = nodeMap.get(edge.to) ?? edge.to;
      const mappedId = uniqueId(`${workflowId}_${edge.id}`, existingEdgeIds);
      existingEdgeIds.add(mappedId);
      if (snapshot.graph.edges.some((candidate) => candidate.from === from && candidate.to === to && candidate.kind === edge.kind)) {
        continue;
      }
      newEdges.push({ ...edge, id: mappedId, from, to, active: false });
    }
    const graph: GraphState = {
      ...snapshot.graph,
      nodes: [...snapshot.graph.nodes, ...newNodes],
      edges: [...snapshot.graph.edges, ...newEdges]
    };
    const instantiated = await this.appendAndPublish({
      eventId: makeEventId(),
      sessionId,
      agentId: anchorNodeId,
      timestamp: new Date().toISOString(),
      type: "workflow.instantiated",
      payload: { workflowId, anchorNodeId, nodeMap: Object.fromEntries(nodeMap) },
      causationId
    }, publish);
    for (const node of newNodes) {
      await this.appendAndPublish({
        eventId: makeEventId(),
        sessionId,
        agentId: node.id,
        timestamp: new Date().toISOString(),
        type: "agent.created",
        payload: {
          roleId: node.roleId,
          label: node.label,
          color: node.color
        },
        causationId: instantiated.eventId
      }, publish);
    }
    await this.appendAndPublish({
      eventId: makeEventId(),
      sessionId,
      agentId: anchorNodeId,
      timestamp: new Date().toISOString(),
      type: "graph.updated",
      payload: { graph },
      causationId: instantiated.eventId
    }, publish);
    return {
      snapshot: await this.store.rebuildSnapshot(sessionId),
      spec,
      nodeMap,
      eventId: instantiated.eventId
    };
  }

  private async instantiatePlan(sessionId: string, planId: string, anchorNodeId: string, publish: (event: SessionEvent) => void) {
    const plan = (await this.plansForSession(sessionId)).find((candidate) => candidate.id === planId);
    if (!plan) throw new Error(`Unknown plan: ${planId}`);
    const alreadyInstantiated = (await this.store.readEvents(sessionId))
      .some((event) => event.type === "plan.instantiated" && event.payload.planId === planId);
    if (alreadyInstantiated) return this.store.readSnapshot(sessionId);
    const instantiated = await this.appendAndPublish({
      eventId: makeEventId(),
      sessionId,
      agentId: anchorNodeId,
      timestamp: new Date().toISOString(),
      type: "plan.instantiated",
      payload: { planId, workflowIds: plan.workflows.map((workflow) => workflow.workflowId), plan, workflowSpecs: this.workflowSpecsForPlan(plan) }
    }, publish);
    for (const workflow of plan.workflows) {
      const graphResult = await this.instantiateWorkflowGraph(
        sessionId,
        workflow.workflowId,
        workflow.anchorNodeId ?? anchorNodeId,
        publish,
        instantiated.eventId
      );
      await this.executeMappedWorkflow(graphResult.snapshot, graphResult.spec, graphResult.nodeMap, workflow, graphResult.eventId, publish);
    }
    return this.store.rebuildSnapshot(sessionId);
  }

  private async executeMappedWorkflow(
    snapshot: SessionSnapshot,
    spec: ReturnType<WorkflowEngine["get"]>,
    nodeMap: Map<string, string>,
    planWorkflow: PlanSpec["workflows"][number],
    causationId: string,
    publish: (event: SessionEvent) => void
  ) {
    const orchestratorId = nodeMap.get(spec.lifecycle.orchestratorNodeId) ?? spec.lifecycle.orchestratorNodeId;
    const runCounts = new Map<string, number>([[orchestratorId, 1]]);
    const processedHandoffs = new Set<string>();
    const maxIterationsPerAgent = 1;
    const maxSteps = Math.max(1, spec.edges.length * maxIterationsPerAgent + 2);
    for (let step = 0; step < maxSteps; step += 1) {
      snapshot = await this.store.readSnapshot(snapshot.sessionId);
      const readyHandoff = spec.edges
        .filter((edge) => edge.kind === "handoff")
        .find((edge) => {
          const from = nodeMap.get(edge.from) ?? edge.from;
          const to = nodeMap.get(edge.to) ?? edge.to;
          return (runCounts.get(from) ?? 0) > 0
            && !processedHandoffs.has(edge.id)
            && this.canSchedule(snapshot, from)
            && this.canSchedule(snapshot, to);
        });
      if (readyHandoff) {
        processedHandoffs.add(readyHandoff.id);
        const from = nodeMap.get(readyHandoff.from) ?? readyHandoff.from;
        const to = nodeMap.get(readyHandoff.to) ?? readyHandoff.to;
        const prompt = this.promptForPlanAgent(planWorkflow, readyHandoff.to);
        const originalGoal = await this.sessionGoal(snapshot.sessionId, snapshot.title);
        const handoff = await this.appendAndPublish({
          eventId: makeEventId(),
          sessionId: snapshot.sessionId,
          agentId: from,
          timestamp: new Date().toISOString(),
          type: "handoff.created",
          payload: { from, to, reason: `plan workflow ${planWorkflow.workflowId}: ${readyHandoff.description}`, edgeId: readyHandoff.id, originalGoal, prompt },
          causationId
        }, publish);
        if (to !== orchestratorId) {
          await this.appendAndPublish({
            eventId: makeEventId(),
            sessionId: snapshot.sessionId,
            agentId: to,
            timestamp: new Date().toISOString(),
            type: "agent.status",
            payload: { status: snapshot.debugMode ? "waiting" : "working" },
            causationId: handoff.eventId
          }, publish);
          await this.runWorkflowAgent(snapshot, to, prompt, handoff.eventId, publish);
          runCounts.set(to, (runCounts.get(to) ?? 0) + 1);
        }
        continue;
      }

      const readyMessage = spec.edges
        .filter((edge) => edge.kind === "message")
        .find((edge) => {
          const from = nodeMap.get(edge.from) ?? edge.from;
          const to = nodeMap.get(edge.to) ?? edge.to;
          return (runCounts.get(from) ?? 0) > 0
            && (runCounts.get(to) ?? 0) < maxIterationsPerAgent
            && this.canSchedule(snapshot, from)
            && this.canSchedule(snapshot, to);
        });
      if (!readyMessage) break;
      const from = nodeMap.get(readyMessage.from) ?? readyMessage.from;
      const to = nodeMap.get(readyMessage.to) ?? readyMessage.to;
      const prompt = this.promptForPlanAgent(planWorkflow, readyMessage.to);
      const originalGoal = await this.sessionGoal(snapshot.sessionId, snapshot.title);
      const message = await this.appendAndPublish({
        eventId: makeEventId(),
        sessionId: snapshot.sessionId,
        agentId: from,
        timestamp: new Date().toISOString(),
        type: "message.sent",
        payload: { from, to, text: `Plan workflow message: ${readyMessage.description}`, edgeId: readyMessage.id, originalGoal, prompt },
        causationId
      }, publish);
      if (to !== orchestratorId) {
        await this.appendAndPublish({
          eventId: makeEventId(),
          sessionId: snapshot.sessionId,
          agentId: to,
          timestamp: new Date().toISOString(),
          type: "agent.status",
          payload: { status: snapshot.debugMode ? "waiting" : "working" },
          causationId: message.eventId
        }, publish);
        await this.runWorkflowAgent(snapshot, to, prompt, message.eventId, publish);
        runCounts.set(to, (runCounts.get(to) ?? 0) + 1);
      }
    }
  }

  private workflowTools(snapshot: SessionSnapshot, agentId: string, publish: (event: SessionEvent) => void) {
    const role = this.resolveRole(snapshot, agentId);
    const roleId = role?.id ?? snapshot.graph.nodes.find((node) => node.id === agentId)?.roleId;
    const tools: NonNullable<Parameters<AgentRuntime["runTurn"]>[0]["workflowTools"]> = {};
    if (role?.toolPolicy.canRead) {
      tools.listWorkflows = () => this.workflows.list().map((workflow) => ({
        id: workflow.id,
        name: workflow.name,
        description: workflow.description,
        nodes: workflow.nodes.map((node) => ({ id: node.id, roleId: node.roleId, label: node.label })),
        edges: workflow.edges.map((edge) => ({ id: edge.id, from: edge.from, to: edge.to, kind: edge.kind, description: edge.description }))
      }));
    }
    if (role?.toolPolicy.canCreatePlans) {
      tools.createPlan = async (rawPlan: unknown) => {
        const plan = PlanSpecSchema.parse(rawPlan);
        await this.appendAndPublish({
          eventId: makeEventId(),
          sessionId: snapshot.sessionId,
          agentId,
          timestamp: new Date().toISOString(),
          type: "plan.created",
          payload: { plan, workflowSpecs: this.workflowSpecsForPlan(plan) }
        }, publish);
        return `Created plan ${plan.id}.`;
      };
    }
    if (role?.toolPolicy.canWrite) {
      tools.writeWorkspaceFile = async (relativePath: string, content: string) => {
        return this.writeWorkspaceFile(snapshot, agentId, relativePath, content, undefined, publish);
      };
    }
    if (roleId === "orchestrator") {
      tools.instantiatePlan = async (planId: string) => {
        await this.instantiatePlan(snapshot.sessionId, planId, agentId, publish);
        return `Instantiated plan ${planId}.`;
      };
      tools.inspectAgents = () => snapshot.graph;
      tools.readWorkspaceFile = async (relativePath: string) => readFile(containedPath(snapshot.workspaceRoot, relativePath), "utf8");
      tools.sendAgentMessage = async (targetAgentId: string, text: string) => {
        this.assertAgentCanReceive(await this.store.readSnapshot(snapshot.sessionId), targetAgentId);
        await this.appendAndPublish({
          eventId: makeEventId(),
          sessionId: snapshot.sessionId,
          agentId,
          timestamp: new Date().toISOString(),
          type: "message.sent",
          payload: { from: agentId, to: targetAgentId, text }
        }, publish);
        return `Sent message to ${targetAgentId}.`;
      };
    }
    return tools;
  }

  private async assertLiveCredentialAvailable() {
    if (this.options.runtime) return;
    if (process.env.OPENAI_API_KEY) return;
    const tokens = await this.auth.loadTokens();
    if (tokens?.accessToken && !(await this.auth.needsRefresh())) return;
    throw new Error("OpenAI authentication is required for non-debug sessions. Connect OpenAI OAuth in Settings or set OPENAI_API_KEY.");
  }

  private async plansForSession(sessionId: string) {
    const plans: PlanSpec[] = [];
    for (const event of await this.store.readEvents(sessionId)) {
      if (event.type !== "plan.created") continue;
      const parsed = PlanSpecSchema.safeParse(event.payload.plan);
      if (parsed.success) plans.push(parsed.data);
    }
    return plans;
  }

  private workflowSpecsForPlan(plan: PlanSpec) {
    return plan.workflows.map((workflow) => this.workflows.get(workflow.workflowId));
  }

  private async latestUninstantiatedPlan(sessionId: string) {
    const plans = await this.plansForSession(sessionId);
    const instantiatedPlanIds = new Set(
      (await this.store.readEvents(sessionId))
        .filter((event) => event.type === "plan.instantiated")
        .map((event) => String(event.payload.planId ?? ""))
    );
    return [...plans].reverse().find((plan) => !instantiatedPlanIds.has(plan.id));
  }

  private async sessionGoal(sessionId: string, fallback: string) {
    const created = (await this.store.readEvents(sessionId)).find((event) => event.type === "session.created");
    return String(created?.payload.goal ?? created?.payload.title ?? fallback);
  }

  private async promptForWorkflowEdge(snapshot: SessionSnapshot, from: string, to: string, edgeId: string, description: string, reason: string) {
    const originalGoal = await this.sessionGoal(snapshot.sessionId, snapshot.title);
    const prompt = [
      `Original user goal: ${originalGoal}`,
      `Workflow transition: ${reason}`,
      `Edge: ${edgeId}`,
      `From: ${from}`,
      `To: ${to}`,
      description ? `Instructions: ${description}` : undefined,
      "Use the original goal as the source of truth and report concrete progress against it."
    ].filter(Boolean).join("\n");
    return { from, to, text: prompt, prompt, reason, edgeId, originalGoal, description };
  }

  private edgeDescription(workflowId: string, edgeId: string) {
    return this.workflows.get(workflowId).edges.find((edge) => edge.id === edgeId)?.description ?? "";
  }

  private async mcpServersForRole(role: ReturnType<SessionManager["resolveRole"]>) {
    if (!role) return [];
    if (role.id === "orchestrator") return [];
    if (!role.toolPolicy.canRunCommands || !role.toolPolicy.canWrite) return [];
    return this.integrations.getConnectedMCPServers();
  }

  private firstNodeForRole(snapshot: SessionSnapshot, roleId: string) {
    return snapshot.graph.nodes.find((node) => node.roleId === roleId)?.id;
  }

  private promptForPlanAgent(planWorkflow: PlanSpec["workflows"][number], nodeId: string) {
    return planWorkflow.agentPrompts[nodeId]
      ?? planWorkflow.agentPrompts[nodeId.split("_").at(-1) ?? nodeId]
      ?? `Execute plan workflow ${planWorkflow.workflowId} as ${nodeId}.`;
  }

  private async openAIApiKey(debugMode: boolean) {
    if (debugMode) return undefined;
    if (process.env.OPENAI_API_KEY) return process.env.OPENAI_API_KEY;
    if (await this.auth.needsRefresh()) {
      throw new Error("OpenAI OAuth token needs refresh. Reconnect OpenAI in Settings before starting a live run.");
    }
    return (await this.auth.loadTokens())?.accessToken;
  }

  private resolveRole(snapshot: SessionSnapshot, agentId: string) {
    const node = snapshot.graph.nodes.find((candidate) => candidate.id === agentId);
    if (node) return this.workflows.roleById(node.roleId);
    const spec = this.workflows.get(snapshot.workflowId);
    return this.workflows.roleForNode(spec, agentId);
  }

  private canSchedule(snapshot: SessionSnapshot, agentId: string) {
    const status = snapshot.graph.nodes.find((node) => node.id === agentId)?.status ?? "idle";
    return !["paused", "cancelled", "failed", "completed"].includes(status);
  }

  private async initializeWorkspace(workspaceRoot: string, title: string) {
    await mkdir(workspaceRoot, { recursive: true });
    const readme = path.join(workspaceRoot, "README.md");
    if (!existsSync(readme)) {
      await writeFile(readme, `# ${title}\n\nThis workspace was initialized for a local multiagent coding session.\n`, "utf8");
    }
  }

  private async loadRoleOverrides() {
    if (this.roleOverridesLoaded) return;
    this.roleOverridesLoaded = true;
    const file = this.roleOverridesPath();
    if (!existsSync(file)) return;
    const roles = JSON.parse(await readFile(file, "utf8")) as unknown[];
    this.workflows.setRoleOverrides(roles as never);
  }

  private async saveRoleOverrides() {
    await mkdir(path.dirname(this.roleOverridesPath()), { recursive: true });
    await writeFile(this.roleOverridesPath(), JSON.stringify(this.workflows.listRoles(), null, 2) + "\n", "utf8");
  }

  private roleOverridesPath() {
    return path.join(this.options.sessionsRoot, "config", "roles.json");
  }

  private addSubscriber(sessionId: string, publish: (event: SessionEvent) => void) {
    const subscribers = this.subscribers.get(sessionId) ?? new Set<(event: SessionEvent) => void>();
    subscribers.add(publish);
    this.subscribers.set(sessionId, subscribers);
  }

  private addLogSubscriber(sessionId: string, publish: (entry: DebugLogEntry) => void) {
    const subscribers = this.logSubscribers.get(sessionId) ?? new Set<(entry: DebugLogEntry) => void>();
    subscribers.add(publish);
    this.logSubscribers.set(sessionId, subscribers);
  }

  private async runControlledTurn(sessionId: string, agentId: string, input: Parameters<AgentRuntime["runTurn"]>[0]): Promise<SessionEvent[]> {
    const key = runKey(sessionId, agentId);
    const controller = new AbortController();
    this.activeRuns.set(key, controller);
    try {
      return await this.runtime.runTurn({ ...input, signal: controller.signal });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      return [
        {
          eventId: makeEventId(),
          sessionId,
          agentId,
          timestamp: new Date().toISOString(),
          type: "error",
          payload: { message },
          causationId: input.causationId
        },
        {
          eventId: makeEventId(),
          sessionId,
          agentId,
          timestamp: new Date().toISOString(),
          type: "agent.status",
          payload: { status: "failed" },
          causationId: input.causationId
        }
      ];
    } finally {
      if (this.activeRuns.get(key) === controller) {
        this.activeRuns.delete(key);
      }
    }
  }

  private publish(event: SessionEvent, exclude?: (event: SessionEvent) => void) {
    for (const publish of this.subscribers.get(event.sessionId) ?? []) {
      if (publish !== exclude) publish(event);
    }
    for (const publish of this.subscribers.get("*") ?? []) {
      if (publish !== exclude) publish(event);
    }
  }

  private publishLog(entry: DebugLogEntry, exclude?: (entry: DebugLogEntry) => void) {
    for (const publish of this.logSubscribers.get(entry.sessionId) ?? []) {
      if (publish !== exclude) publish(entry);
    }
    for (const publish of this.logSubscribers.get("*") ?? []) {
      if (publish !== exclude) publish(entry);
    }
  }
}

function firstLine(text: string) {
  return text.trim().split("\n").find(Boolean)?.slice(0, 80) ?? "";
}

function runKey(sessionId: string, agentId: string) {
  return `${sessionId}:${agentId}`;
}

function unifiedDiff(relativePath: string, before: string, after: string) {
  const beforeLines = before.split(/\r?\n/).filter((line, index, lines) => index < lines.length - 1 || line.length > 0);
  const afterLines = after.split(/\r?\n/).filter((line, index, lines) => index < lines.length - 1 || line.length > 0);
  let prefix = 0;
  while (prefix < beforeLines.length && prefix < afterLines.length && beforeLines[prefix] === afterLines[prefix]) {
    prefix += 1;
  }
  let suffix = 0;
  while (
    suffix < beforeLines.length - prefix
    && suffix < afterLines.length - prefix
    && beforeLines[beforeLines.length - 1 - suffix] === afterLines[afterLines.length - 1 - suffix]
  ) {
    suffix += 1;
  }
  const removed = beforeLines.slice(prefix, beforeLines.length - suffix);
  const added = afterLines.slice(prefix, afterLines.length - suffix);
  const contextBefore = beforeLines.slice(Math.max(0, prefix - 3), prefix);
  const contextAfter = afterLines.slice(afterLines.length - suffix, Math.min(afterLines.length, afterLines.length - suffix + 3));
  const oldStart = Math.max(1, prefix - contextBefore.length + 1);
  const newStart = oldStart;
  const oldCount = contextBefore.length + removed.length + contextAfter.length;
  const newCount = contextBefore.length + added.length + contextAfter.length;
  return [
    `--- a/${relativePath}`,
    `+++ b/${relativePath}`,
    `@@ -${oldStart},${oldCount} +${newStart},${newCount} @@`,
    ...contextBefore.map((line) => ` ${line}`),
    ...removed.map((line) => `-${line}`),
    ...added.map((line) => `+${line}`),
    ...contextAfter.map((line) => ` ${line}`)
  ].join("\n");
}

function diffStats(diff: string) {
  let additions = 0;
  let deletions = 0;
  for (const line of diff.split("\n")) {
    if (line.startsWith("+++") || line.startsWith("---")) continue;
    if (line.startsWith("+")) additions += 1;
    if (line.startsWith("-")) deletions += 1;
  }
  return { additions, deletions };
}

function uniqueId(base: string, existing: Set<string>) {
  let candidate = base.replace(/[^A-Za-z0-9_-]/g, "_");
  let suffix = 2;
  while (existing.has(candidate)) {
    candidate = `${base}_${suffix}`.replace(/[^A-Za-z0-9_-]/g, "_");
    suffix += 1;
  }
  return candidate;
}

function containedPath(root: string, relativePath: string) {
  const resolvedRoot = path.resolve(root);
  const resolved = path.resolve(resolvedRoot, relativePath);
  if (resolved !== resolvedRoot && !resolved.startsWith(`${resolvedRoot}${path.sep}`)) {
    throw new Error(`Path escapes workspace: ${relativePath}`);
  }
  return resolved;
}

function temperatureConverterProgram() {
  return `#!/usr/bin/env python3
import argparse


def celsius_to_fahrenheit(celsius: float) -> float:
    return (celsius * 9 / 5) + 32


def fahrenheit_to_celsius(fahrenheit: float) -> float:
    return (fahrenheit - 32) * 5 / 9


def main() -> None:
    parser = argparse.ArgumentParser(description="Convert temperatures between Celsius and Fahrenheit.")
    parser.add_argument("value", type=float)
    parser.add_argument("--from-unit", choices=["c", "f"], required=True)
    args = parser.parse_args()
    if args.from_unit == "c":
        print(f"{celsius_to_fahrenheit(args.value):.2f} F")
    else:
        print(f"{fahrenheit_to_celsius(args.value):.2f} C")


if __name__ == "__main__":
    main()
`;
}

function temperatureConverterTests() {
  return `import subprocess
import sys
import unittest

from temperature_converter import celsius_to_fahrenheit, fahrenheit_to_celsius


class TemperatureConverterTests(unittest.TestCase):
    def test_celsius_to_fahrenheit(self):
        self.assertEqual(celsius_to_fahrenheit(0), 32)
        self.assertEqual(celsius_to_fahrenheit(100), 212)

    def test_fahrenheit_to_celsius(self):
        self.assertEqual(fahrenheit_to_celsius(32), 0)
        self.assertEqual(fahrenheit_to_celsius(212), 100)

    def test_cli(self):
        result = subprocess.run(
            [sys.executable, "temperature_converter.py", "100", "--from-unit", "c"],
            check=True,
            text=True,
            capture_output=True,
        )
        self.assertEqual(result.stdout.strip(), "212.00 F")


if __name__ == "__main__":
    unittest.main()
`;
}
