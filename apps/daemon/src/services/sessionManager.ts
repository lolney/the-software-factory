import { PlanSpecSchema, type DaemonRequest, type DebugLogEntry, type DebugLogLevel, type GraphState, type PlanSpec, type SessionEvent, type SessionSnapshot, type WorkflowSpec } from "@multiagent/shared";
import { mkdir, readFile, readdir, stat, writeFile } from "node:fs/promises";
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

interface WorkflowRunContext {
  workflowInstanceId?: string;
  workflowId?: string;
  callerAgentId?: string;
}

interface WorkflowInstance {
  workflowInstanceId: string;
  workflowId: string;
  callerAgentId: string;
  nodeMap: Map<string, string>;
  agentIds: string[];
  completionCriteria: unknown;
}

interface StopAgentResult {
  stopped: boolean;
  reason: string;
}

interface ScheduledJob {
  jobId: string;
  kind: string;
  createdEventId: string;
  heartbeat: ReturnType<typeof setInterval>;
}

export class SessionManager {
  private readonly subscribers = new Map<string, Set<(event: SessionEvent) => void>>();
  private readonly logSubscribers = new Map<string, Set<(entry: DebugLogEntry) => void>>();
  private readonly store: EventStore;
  private readonly runtime: AgentRuntime;
  private readonly workflows: WorkflowEngine;
  private readonly workspace = new WorkspaceCoordinator();
  private readonly integrations = new CodexIntegrationManager();
  private readonly activeRuns = new Map<string, AbortController>();
  private readonly auth = new AuthManager();
  private roleOverridesLoaded = false;
  private recoveryComplete = false;

  constructor(private readonly options: { sessionsRoot: string; runtime?: AgentRuntime }) {
    this.store = new EventStore(options.sessionsRoot);
    this.runtime = options.runtime ?? new OpenAIAgentRuntime();
    this.workflows = new WorkflowEngine(process.env.MULTIAGENT_BUILTIN_WORKFLOWS_DIR, path.join(options.sessionsRoot, "config"));
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
    await this.workflows.reloadPersonalCatalog();
    await this.loadRoleOverrides();
    await this.recoverInterruptedRuns(publish, publishLog);
    switch (request.method) {
      case "listSessions":
        return {
          sessionsRoot: this.options.sessionsRoot,
          ...this.workflows.catalogPaths(),
          workflows: this.workflows.list(),
          roles: this.workflows.listRoles(),
          codexOAuth: await this.auth.status(),
          integrations: await this.integrations.listCatalog(),
          sessions: await this.store.listSessions({ includeArchived: request.params.includeArchived ?? false })
        };
      case "archiveSessions": {
        for (const sessionId of request.params.sessionIds) {
          await this.store.assertSessionExists(sessionId);
          if (request.params.archived) {
            const snapshot = await this.store.readSnapshot(sessionId);
            const activeAgents = snapshot.graph.nodes.filter((node) => ["working", "waiting", "paused"].includes(node.status));
            if (activeAgents.length > 0) {
              throw new Error(`Cannot archive session ${sessionId} while agents are active: ${activeAgents.map((node) => node.id).join(", ")}`);
            }
          }
          const event = await this.appendAndPublish({
            eventId: makeEventId(),
            sessionId,
            timestamp: new Date().toISOString(),
            type: request.params.archived ? "session.archived" : "session.restored",
            payload: { archived: request.params.archived }
          }, publish);
          await this.appendDebugLog(
            sessionId,
            "info",
            "session",
            request.params.archived ? "Session archived." : "Session restored.",
            { eventId: event.eventId },
            publishLog,
            undefined,
            event.eventId
          );
          await this.store.rebuildSnapshot(sessionId);
        }
        return {
          sessions: await this.store.listSessions({ includeArchived: true })
        };
      }
      case "getAuthStatus":
        return this.auth.status();
      case "beginOpenAIOAuth":
        return this.auth.beginOAuth(request.params.port);
      case "disconnectOpenAIOAuth":
        await this.auth.deleteTokens();
        return this.auth.status();
      case "setChatGPTAccountId":
        await this.auth.saveChatGPTAccountId(request.params.accountId);
        return this.auth.status();
      case "disconnectChatGPTAccountId":
        await this.auth.deleteChatGPTAccountId();
        return this.auth.status();
      case "setOpenAIAPIKey":
        await this.auth.saveApiKey(request.params.apiKey);
        return this.auth.status();
      case "disconnectOpenAIAPIKey":
        await this.auth.deleteApiKey();
        return this.auth.status();
      case "listRoles":
        return { roles: this.workflows.listRoles(), ...this.workflows.catalogPaths() };
      case "upsertRole":
        await this.workflows.writePersonalRole(request.params.role);
        return { roles: this.workflows.listRoles(), ...this.workflows.catalogPaths() };
      case "deleteRole":
        await this.workflows.deletePersonalRole(request.params.roleId);
        return { roles: this.workflows.listRoles(), ...this.workflows.catalogPaths() };
      case "listWorkflows":
        return { workflows: this.workflows.list(), ...this.workflows.catalogPaths() };
      case "createRoleFile": {
        const created = await this.workflows.createBlankRoleFile();
        return { ...created, roles: this.workflows.listRoles(), ...this.workflows.catalogPaths() };
      }
      case "createWorkflowFile": {
        const created = await this.workflows.createBlankWorkflowFile();
        return { ...created, workflows: this.workflows.list(), ...this.workflows.catalogPaths() };
      }
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
          model: request.params.model,
          reasoningEffort: request.params.reasoningEffort,
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
        this.assertSessionMutable(snapshot);
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
        this.assertSessionMutable(await this.store.readSnapshot(request.params.sessionId));
        return this.controlEvent(request.params.sessionId, request.params.agentId, "control.pause", "paused", publish);
      case "resumeAgent":
        await this.store.assertSessionExists(request.params.sessionId);
        this.assertSessionMutable(await this.store.readSnapshot(request.params.sessionId));
        return this.controlEvent(request.params.sessionId, request.params.agentId, "control.resume", "idle", publish);
      case "cancelAgent":
        await this.store.assertSessionExists(request.params.sessionId);
        this.assertSessionMutable(await this.store.readSnapshot(request.params.sessionId));
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
        this.assertSessionMutable(await this.store.readSnapshot(request.params.sessionId));
        return this.instantiateWorkflow(request.params.sessionId, request.params.workflowId, request.params.anchorNodeId, publish);
    }
  }

  private assertSessionMutable(snapshot: SessionSnapshot) {
    if (snapshot.archived) {
      throw new Error(`Session ${snapshot.sessionId} is archived. Restore it before sending messages or changing workflow state.`);
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
    const openAI = await this.openAIConnection(debugMode);
    const job = await this.startScheduledTurn(snapshot.sessionId, agentId, publish, {
      kind: "agent-turn",
      prompt: userText,
      causationId: promptEvent.eventId
    });
    try {
      const events = await this.runControlledTurn(snapshot.sessionId, agentId, {
        sessionId: snapshot.sessionId,
        agentId,
        prompt: userText,
        debugMode,
        roleName: role?.name,
        instructions: role?.promptTemplate,
        model: modelForRun(snapshot, role),
        reasoningEffort: reasoningEffortForRun(snapshot),
        apiKey: openAI?.apiKey,
        openAI,
        workflowTools: this.workflowTools(snapshot, agentId, publish),
        mcpServers: debugMode || this.options.runtime ? [] : await this.mcpServersForRole(role),
        skills: integrationCatalog.skills,
        causationId: promptEvent.eventId
      });
      await this.appendRuntimeEvents(snapshot.sessionId, agentId, events, publish);
      await this.store.rebuildSnapshot(snapshot.sessionId);
      const error = events.find((event) => event.type === "error");
      await this.finishScheduledTurn(snapshot.sessionId, agentId, job, publish, error ? "failed" : "completed", events.length, error?.payload.message);
    } catch (error) {
      await this.failScheduledSideEffect(snapshot.sessionId, agentId, job, publish, error, promptEvent.eventId);
    }
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
    const processedMessages = new Set<string>();
    const maxConcurrent = Math.max(1, spec.concurrency.maxActiveAgents);
    const maxIterationsPerAgent = 3;
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
        .filter((edge) => !processedMessages.has(edge.id))
        .filter((edge) => this.canSchedule(snapshot, edge.from) && this.canSchedule(snapshot, edge.to));
      if (readyMessages.length === 0) break;
      const batch = readyMessages.slice(0, maxConcurrent);
      await Promise.all(batch.map(async (edge) => {
        processedMessages.add(edge.id);
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
    publish: (event: SessionEvent) => void,
    context: WorkflowRunContext = {}
  ) {
    const role = this.resolveRole(snapshot, agentId);
    const integrationCatalog = await this.integrations.listCatalog();
    const openAI = await this.openAIConnection(snapshot.debugMode);
    const job = await this.startScheduledTurn(snapshot.sessionId, agentId, publish, {
      kind: "workflow-agent-turn",
      prompt,
      workflowInstanceId: context.workflowInstanceId,
      workflowId: context.workflowId,
      callerAgentId: context.callerAgentId,
      causationId
    });
    try {
      const events = await this.runControlledTurn(snapshot.sessionId, agentId, {
        sessionId: snapshot.sessionId,
        agentId,
        prompt,
        debugMode: snapshot.debugMode,
        roleName: role?.name,
        instructions: role?.promptTemplate,
        model: modelForRun(snapshot, role),
        reasoningEffort: reasoningEffortForRun(snapshot),
        apiKey: openAI?.apiKey,
        openAI,
        workflowTools: this.workflowTools(snapshot, agentId, publish, context),
        mcpServers: snapshot.debugMode || this.options.runtime ? [] : await this.mcpServersForRole(role),
        skills: integrationCatalog.skills,
        causationId
      });
      await this.appendRuntimeEvents(snapshot.sessionId, agentId, events, publish);
      if (role?.toolPolicy.canCreatePlans) {
        await this.createPlanForSession(snapshot, agentId, causationId, publish);
      } else if (snapshot.debugMode) {
        await this.applyDeterministicRoleWork(snapshot, agentId, causationId, publish, context);
      }
      await this.maybeAutoStopSatisfiedAgent(
        snapshot.sessionId,
        agentId,
        role?.id ?? snapshot.graph.nodes.find((node) => node.id === agentId)?.roleId ?? agentId,
        context.workflowInstanceId,
        publish,
        causationId
      );
      await this.store.rebuildSnapshot(snapshot.sessionId);
      const error = events.find((event) => event.type === "error");
      await this.finishScheduledTurn(snapshot.sessionId, agentId, job, publish, error ? "failed" : "completed", events.length, error?.payload.message);
    } catch (error) {
      await this.failScheduledSideEffect(snapshot.sessionId, agentId, job, publish, error, causationId);
    }
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

  private resolveAgentTarget(snapshot: SessionSnapshot, requestedAgentId: string) {
    if (snapshot.graph.nodes.some((node) => node.id === requestedAgentId)) {
      return requestedAgentId;
    }
    const matches = snapshot.graph.nodes.filter((node) =>
      node.roleId === requestedAgentId
      || node.id.endsWith(`_${requestedAgentId}`)
    );
    if (matches.length === 1) {
      return matches[0]?.id;
    }
    const activeMatches = matches.filter((node) => !["cancelled", "failed", "completed"].includes(node.status));
    return activeMatches.length === 1 ? activeMatches[0]?.id : undefined;
  }

  private async appendRuntimeEvents(
    sessionId: string,
    agentId: string,
    events: SessionEvent[],
    publish: (event: SessionEvent) => void
  ) {
    const existingEvents = await this.store.readEvents(sessionId);
    const stoppedDuringRun = existingEvents.some((event) => event.type === "agent.stopped" && event.agentId === agentId);
    for (const event of events) {
      if (stoppedDuringRun && event.agentId === agentId && event.type === "agent.status") {
        continue;
      }
      await this.appendAndPublish(event, publish);
    }
  }

  private async maybeAutoStopSatisfiedAgent(
    sessionId: string,
    agentId: string,
    roleId: string,
    workflowInstanceId: string | undefined,
    publish: (event: SessionEvent) => void,
    causationId?: string
  ) {
    if (!workflowInstanceId || roleId === "orchestrator" || roleId === "planner") return;
    const events = await this.store.readEvents(sessionId);
    if (events.some((event) => event.type === "agent.stopped" && event.agentId === agentId && event.payload.workflowInstanceId === workflowInstanceId)) {
      return;
    }
    const instance = (await this.workflowInstancesForSession(sessionId)).find((candidate) => candidate.workflowInstanceId === workflowInstanceId);
    if (!instance || !(await this.canAgentStop(sessionId, instance, agentId))) return;
    const latestMessage = [...events]
      .reverse()
      .find((event) => event.agentId === agentId && event.type === "agent.message");
    const text = String(latestMessage?.payload.text ?? "");
    const satisfied =
      (roleId === "reviewer" && /\b(approved|approval|no blocking|no blockers)\b/i.test(text))
      || (roleId === "qa" && /\b(pass|passed|acceptance checks completed|acceptance status:\s*pass)\b/i.test(text))
      || (roleId === "implementor" && /\b(implemented|complete|approved|ready for qa|tests pass|tests passed)\b/i.test(text));
    if (!satisfied) return;
    await this.stopCurrentAgent(sessionId, agentId, {
      reason: `Engine inferred ${roleId} completion from final message.`,
      artifact: text,
      completedCriteria: [`${roleId} reported completion`],
      workflowInstanceId
    }, publish, causationId);
  }

  private async readWorkspacePath(workspaceRoot: string, relativePath: string) {
    const target = containedPath(workspaceRoot, relativePath || ".");
    const info = await stat(target);
    if (!info.isDirectory()) {
      return readFile(target, "utf8");
    }
    const entries = await listDirectoryTree(target, workspaceRoot);
    return entries.length ? entries.join("\n") : ".";
  }

  private async hasCompletedImplementationWorkflow(sessionId: string) {
    return (await this.store.readEvents(sessionId)).some((event) =>
      event.type === "workflow.completed"
      && event.payload.workflowId === "implementation-review-qa"
    );
  }

  private async completedWorkflowSummary(sessionId: string) {
    const events = await this.store.readEvents(sessionId);
    const completed = [...events].reverse().find((event) =>
      event.type === "workflow.completed"
      && event.payload.workflowId === "implementation-review-qa"
    );
    if (!completed) return "";
    return [
      `Completed workflow: ${String(completed.payload.workflowId)} (${String(completed.payload.workflowInstanceId)}).`,
      this.workflowCompletionSummaryFromEvents(events, String(completed.payload.workflowInstanceId))
    ].filter(Boolean).join("\n");
  }

  private async workflowCompletionSummary(sessionId: string, workflowInstanceId: string, nodeMap: Map<string, string>) {
    const events = await this.store.readEvents(sessionId);
    const mappedAgents = [...nodeMap.values()].filter((agentId) => agentId !== "orchestrator").join(", ");
    return [
      mappedAgents ? `Mapped workflow agents: ${mappedAgents}.` : undefined,
      this.workflowCompletionSummaryFromEvents(events, workflowInstanceId)
    ].filter(Boolean).join("\n");
  }

  private workflowCompletionSummaryFromEvents(events: SessionEvent[], workflowInstanceId: string) {
    const lines: string[] = [];
    const agentIds = [...new Set(events
      .filter((event) => event.payload.workflowInstanceId === workflowInstanceId && event.agentId)
      .map((event) => String(event.agentId)))];
    for (const agentId of agentIds) {
      const stopped = [...events].reverse().find((event) =>
        event.type === "agent.stopped"
        && event.agentId === agentId
        && event.payload.workflowInstanceId === workflowInstanceId
      );
      const message = [...events].reverse().find((event) => event.type === "agent.message" && event.agentId === agentId);
      const text = String(message?.payload.text ?? stopped?.payload.artifact ?? stopped?.payload.reason ?? "");
      if (text) {
        lines.push(`${agentId}: ${truncateForToolResult(text, 900)}`);
      }
    }
    return lines.join("\n");
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

  private async applyDeterministicRoleWork(
    snapshot: SessionSnapshot,
    agentId: string,
    causationId: string,
    publish: (event: SessionEvent) => void,
    context: WorkflowRunContext = {}
  ) {
    const role = this.resolveRole(snapshot, agentId);
    const roleId = role?.id ?? snapshot.graph.nodes.find((node) => node.id === agentId)?.roleId ?? agentId;
    if (roleId === "implementor") {
      await this.writeTemperatureConverter(snapshot, agentId, causationId, publish);
      if (context.workflowInstanceId) {
        await this.stopCurrentAgent(snapshot.sessionId, agentId, {
          reason: "Implementation artifact created.",
          artifact: { files: ["temperature_converter.py", "test_temperature_converter.py"] },
          completedCriteria: ["implementation_ready_for_qa", "implementation_artifact"],
          workflowInstanceId: context.workflowInstanceId
        }, publish, causationId);
      }
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
      if (context.workflowInstanceId) {
        await this.stopCurrentAgent(snapshot.sessionId, agentId, {
          reason: "Review complete with no blocking findings.",
          artifact: { summary: "No blocking findings." },
          completedCriteria: ["review_no_blockers", "review_complete"],
          workflowInstanceId: context.workflowInstanceId
        }, publish, causationId);
      }
    } else if (roleId === "qa") {
      await this.runTemperatureConverterQA(snapshot, agentId, causationId, publish);
      if (context.workflowInstanceId) {
        await this.stopCurrentAgent(snapshot.sessionId, agentId, {
          reason: "QA acceptance passed.",
          artifact: { command: "python3 -m unittest test_temperature_converter.py", result: "passed" },
          completedCriteria: ["qa_acceptance"],
          workflowInstanceId: context.workflowInstanceId
        }, publish, causationId);
      }
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

  private async runWorkspaceCommand(snapshot: SessionSnapshot, command: string, args: string[] = [], cwd?: string) {
    const workingDirectory = cwd ? containedPath(snapshot.workspaceRoot, cwd) : snapshot.workspaceRoot;
    try {
      const result = await execFileAsync(command, args, {
        cwd: workingDirectory,
        timeout: 60_000,
        maxBuffer: 1024 * 1024
      });
      return [
        `exitCode: 0`,
        result.stdout ? `stdout:\n${result.stdout}` : undefined,
        result.stderr ? `stderr:\n${result.stderr}` : undefined
      ].filter(Boolean).join("\n");
    } catch (error) {
      const processError = error as { code?: unknown; stdout?: string; stderr?: string; message?: string };
      return [
        `exitCode: ${typeof processError.code === "number" ? processError.code : 1}`,
        processError.stdout ? `stdout:\n${processError.stdout}` : undefined,
        processError.stderr ? `stderr:\n${processError.stderr}` : undefined,
        processError.message ? `error:\n${processError.message}` : undefined
      ].filter(Boolean).join("\n");
    }
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
    const workflowInstanceId = `wf_${crypto.randomUUID()}`;
    const instantiated = await this.appendAndPublish({
      eventId: makeEventId(),
      sessionId,
      agentId: anchorNodeId,
      timestamp: new Date().toISOString(),
      type: "workflow.instantiated",
      payload: {
        workflowInstanceId,
        workflowId,
        callerAgentId: anchorNodeId,
        anchorNodeId,
        nodeMap: Object.fromEntries(nodeMap),
        completionCriteria: spec.completionCriteria,
        stopCriteria: spec.stopCriteria
      },
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
      eventId: instantiated.eventId,
      workflowInstanceId
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
      await this.executeMappedWorkflow(graphResult.snapshot, graphResult.spec, graphResult.nodeMap, workflow, graphResult.eventId, publish, graphResult.workflowInstanceId);
    }
    return this.store.rebuildSnapshot(sessionId);
  }

  private async executeMappedWorkflow(
    snapshot: SessionSnapshot,
    spec: ReturnType<WorkflowEngine["get"]>,
    nodeMap: Map<string, string>,
    planWorkflow: PlanSpec["workflows"][number],
    causationId: string,
    publish: (event: SessionEvent) => void,
    workflowInstanceId: string
  ) {
    const orchestratorId = nodeMap.get(spec.lifecycle.orchestratorNodeId) ?? spec.lifecycle.orchestratorNodeId;
    const runCounts = new Map<string, number>([[orchestratorId, 1]]);
    const processedHandoffs = new Set<string>();
    const processedMessages = new Set<string>();
    const maxIterationsPerAgent = 2;
    const maxSteps = Math.max(1, spec.edges.length * maxIterationsPerAgent + 4);
    for (let step = 0; step < maxSteps; step += 1) {
      snapshot = await this.store.readSnapshot(snapshot.sessionId);
      const readyHandoff = spec.edges
        .filter((edge) => edge.kind === "handoff")
        .find((edge) => {
          const from = nodeMap.get(edge.from) ?? edge.from;
          const to = nodeMap.get(edge.to) ?? edge.to;
          return (runCounts.get(from) ?? 0) > 0
            && !processedHandoffs.has(edge.id)
            && this.canEmitFrom(snapshot, from)
            && this.canSchedule(snapshot, to)
            && this.canHandoffFrom(snapshot, spec, nodeMap, edge.from, edge.to, workflowInstanceId);
        });
      if (readyHandoff) {
        processedHandoffs.add(readyHandoff.id);
        const from = nodeMap.get(readyHandoff.from) ?? readyHandoff.from;
        const to = nodeMap.get(readyHandoff.to) ?? readyHandoff.to;
        const originalGoal = await this.sessionGoal(snapshot.sessionId, snapshot.title);
        const prompt = this.promptForPlanAgent(planWorkflow, readyHandoff.to, originalGoal, readyHandoff.description, this.latestAgentMessage(snapshot, from));
        const handoff = await this.appendAndPublish({
          eventId: makeEventId(),
          sessionId: snapshot.sessionId,
          agentId: from,
          timestamp: new Date().toISOString(),
          type: "handoff.created",
          payload: { from, to, reason: `plan workflow ${planWorkflow.workflowId}: ${readyHandoff.description}`, edgeId: readyHandoff.id, originalGoal, prompt, workflowInstanceId },
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
          await this.runWorkflowAgent(snapshot, to, prompt, handoff.eventId, publish, {
            workflowInstanceId,
            workflowId: spec.id,
            callerAgentId: orchestratorId
          });
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
            && !processedMessages.has(edge.id)
            && this.canEmitFrom(snapshot, from)
            && this.canSchedule(snapshot, to)
            && this.canHandoffFrom(snapshot, spec, nodeMap, edge.from, edge.to, workflowInstanceId);
        });
      if (!readyMessage) break;
      processedMessages.add(readyMessage.id);
      const from = nodeMap.get(readyMessage.from) ?? readyMessage.from;
      const to = nodeMap.get(readyMessage.to) ?? readyMessage.to;
      const originalGoal = await this.sessionGoal(snapshot.sessionId, snapshot.title);
      const prompt = this.promptForPlanAgent(planWorkflow, readyMessage.to, originalGoal, readyMessage.description, this.latestAgentMessage(snapshot, from));
      const message = await this.appendAndPublish({
        eventId: makeEventId(),
        sessionId: snapshot.sessionId,
        agentId: from,
        timestamp: new Date().toISOString(),
        type: "message.sent",
        payload: { from, to, text: prompt, edgeId: readyMessage.id, originalGoal, prompt, workflowInstanceId, description: readyMessage.description },
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
        await this.runWorkflowAgent(snapshot, to, prompt, message.eventId, publish, {
          workflowInstanceId,
          workflowId: spec.id,
          callerAgentId: orchestratorId
        });
        runCounts.set(to, (runCounts.get(to) ?? 0) + 1);
      }
    }
    await this.maybeCompleteWorkflow(snapshot.sessionId, workflowInstanceId, publish, causationId);
  }

  private workflowTools(snapshot: SessionSnapshot, agentId: string, publish: (event: SessionEvent) => void, context: WorkflowRunContext = {}) {
    const role = this.resolveRole(snapshot, agentId);
    const roleId = role?.id ?? snapshot.graph.nodes.find((node) => node.id === agentId)?.roleId;
    const tools: NonNullable<Parameters<AgentRuntime["runTurn"]>[0]["workflowTools"]> = {};
    if (role?.toolPolicy.canRead) {
      tools.listWorkflows = () => this.workflows.list().map((workflow) => ({
        id: workflow.id,
        name: workflow.name,
        description: workflow.description,
        nodes: workflow.nodes.map((node) => ({ id: node.id, roleId: node.roleId, label: node.label, dependencies: node.dependencies })),
        edges: workflow.edges.map((edge) => ({ id: edge.id, from: edge.from, to: edge.to, kind: edge.kind, description: edge.description })),
        completionCriteria: workflow.completionCriteria,
        stopCriteria: workflow.stopCriteria
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
    if (role?.toolPolicy.canRunCommands) {
      tools.runWorkspaceCommand = async (command: string, args: string[] = [], cwd?: string) => {
        return this.runWorkspaceCommand(snapshot, command, args, cwd);
      };
    }
    if (roleId === "orchestrator") {
      tools.instantiatePlan = async (planId: string) => {
        await this.instantiatePlan(snapshot.sessionId, planId, agentId, publish);
        return `Instantiated plan ${planId}.`;
      };
      tools.startWorkflow = async (workflowId: string, anchorNodeId?: string) => {
        const result = await this.instantiateWorkflowGraph(snapshot.sessionId, workflowId, anchorNodeId ?? agentId, publish);
        await this.executeMappedWorkflow(result.snapshot, result.spec, result.nodeMap, {
          workflowId,
          agentPrompts: {},
          doneCriteria: {},
          completionCriteria: {}
        }, result.eventId, publish, result.workflowInstanceId);
        const latest = await this.store.readSnapshot(snapshot.sessionId);
        const agentIds = [...result.nodeMap.entries()]
          .filter(([nodeId]) => nodeId !== result.spec.lifecycle.orchestratorNodeId)
          .map(([nodeId, mappedId]) => {
            const node = result.spec.nodes.find((candidate) => candidate.id === nodeId);
            return `${mappedId} (${node?.roleId ?? nodeId})`;
          });
        const completed = latest.transcript.find((event) =>
          event.type === "workflow.completed"
          && event.payload.workflowInstanceId === result.workflowInstanceId
        );
        return [
          `Started workflow ${workflowId} as ${result.workflowInstanceId}.`,
          agentIds.length ? `Agents: ${agentIds.join(", ")}.` : undefined,
          completed ? `Workflow completed: ${String(completed.payload.message ?? "all agents stopped")}.` : "Workflow has not completed yet.",
          await this.workflowCompletionSummary(snapshot.sessionId, result.workflowInstanceId, result.nodeMap),
          "Use the mapped agent ids above when sending messages; role names alone are not agent ids."
        ].filter(Boolean).join("\n");
      };
      tools.stopWorkflow = async (workflowInstanceId: string, reason: string) => {
        await this.stopWorkflowInstance(snapshot.sessionId, workflowInstanceId, agentId, reason, publish);
        return `Stopped workflow ${workflowInstanceId}.`;
      };
      tools.stopAgent = async (targetAgentId: string, reason: string, artifact?: unknown) => {
        const latest = await this.store.readSnapshot(snapshot.sessionId);
        const resolvedAgentId = this.resolveAgentTarget(latest, targetAgentId);
        if (!resolvedAgentId) {
          throw new Error(`Unknown agent ${targetAgentId} in session ${snapshot.sessionId}. Use agent_state_inspect to get current agent ids.`);
        }
        const result = await this.stopCurrentAgent(snapshot.sessionId, resolvedAgentId, {
          reason,
          artifact,
          stoppedBy: agentId
        }, publish);
        return result.stopped ? `Stopped agent ${resolvedAgentId}.` : `Agent ${resolvedAgentId} stop blocked: ${result.reason}.`;
      };
      tools.inspectAgents = async () => (await this.store.readSnapshot(snapshot.sessionId)).graph;
      tools.readWorkspaceFile = async (relativePath: string) => this.readWorkspacePath(snapshot.workspaceRoot, relativePath);
      tools.sendAgentMessage = async (targetAgentId: string, text: string) => {
        const latest = await this.store.readSnapshot(snapshot.sessionId);
        const resolvedAgentId = this.resolveAgentTarget(latest, targetAgentId);
        if (!resolvedAgentId) {
          throw new Error(`Unknown agent ${targetAgentId} in session ${snapshot.sessionId}. Use agent_state_inspect to get current agent ids.`);
        }
        this.assertAgentCanReceive(latest, resolvedAgentId);
        await this.appendAndPublish({
          eventId: makeEventId(),
          sessionId: snapshot.sessionId,
          agentId,
          timestamp: new Date().toISOString(),
          type: "message.sent",
          payload: { from: agentId, to: resolvedAgentId, requestedTo: targetAgentId, text }
        }, publish);
        return `Sent message to ${resolvedAgentId}.`;
      };
    }
    tools.stopSelf = async (reason: string, artifact?: unknown, completedCriteria: string[] = []) => {
      if (roleId === "orchestrator" && isNegativeCompletion(reason) && await this.hasCompletedImplementationWorkflow(snapshot.sessionId)) {
        return [
          "Stop rejected: implementation-review-qa has completed successfully in the session.",
          "Inspect agent state or read the workspace if needed, then call workflow_stop_self with a successful completion summary.",
          await this.completedWorkflowSummary(snapshot.sessionId)
        ].filter(Boolean).join("\n");
      }
      const result = await this.stopCurrentAgent(snapshot.sessionId, agentId, {
        reason,
        artifact,
        completedCriteria,
        workflowInstanceId: context.workflowInstanceId
      }, publish);
      return result.stopped ? `Stopped ${agentId}.` : `Stop blocked for ${agentId}: ${result.reason}.`;
    };
    return tools;
  }

  private async stopCurrentAgent(
    sessionId: string,
    agentId: string,
    input: {
      reason: string;
      artifact?: unknown;
      completedCriteria?: string[];
      workflowInstanceId?: string;
      stoppedBy?: string;
    },
    publish: (event: SessionEvent) => void,
    causationId?: string
  ): Promise<StopAgentResult> {
    const workflowInstance = input.workflowInstanceId
      ? (await this.workflowInstancesForSession(sessionId)).find((instance) => instance.workflowInstanceId === input.workflowInstanceId)
      : await this.inferActiveWorkflowForAgent(sessionId, agentId);
    const workflowInstanceId = workflowInstance?.workflowInstanceId ?? input.workflowInstanceId;
    if (workflowInstance && !(await this.canAgentStop(sessionId, workflowInstance, agentId))) {
      const unresolved = await this.unresolvedStopDependencies(sessionId, workflowInstance, agentId);
      await this.appendAndPublish({
        eventId: makeEventId(),
        sessionId,
        agentId,
        timestamp: new Date().toISOString(),
        type: "agent.stop_blocked",
        payload: {
          reason: input.reason,
          workflowInstanceId,
          unresolvedDependencies: unresolved.dependencies,
          activeChildWorkflows: unresolved.activeChildWorkflows
        },
        causationId
      }, publish);
      const blockers = [
        unresolved.dependencies.length > 0 ? `dependencies ${unresolved.dependencies.join(", ")}` : undefined,
        unresolved.activeChildWorkflows.length > 0 ? `child workflows ${unresolved.activeChildWorkflows.join(", ")}` : undefined
      ].filter(Boolean).join("; ");
      return { stopped: false, reason: blockers || "completion gates are still open" };
    }
    const stopped = await this.appendAndPublish({
      eventId: makeEventId(),
      sessionId,
      agentId,
      timestamp: new Date().toISOString(),
      type: "agent.stopped",
      payload: {
        reason: input.reason,
        artifact: input.artifact,
        completedCriteria: input.completedCriteria ?? [],
        workflowInstanceId,
        stoppedBy: input.stoppedBy
      },
      causationId
    }, publish);
    await this.appendAndPublish({
      eventId: makeEventId(),
      sessionId,
      agentId,
      timestamp: new Date().toISOString(),
      type: "agent.status",
      payload: { status: "completed" },
      causationId: stopped.eventId
    }, publish);
    if (workflowInstanceId) {
      await this.maybeCompleteWorkflow(sessionId, workflowInstanceId, publish, stopped.eventId);
    }
    return { stopped: true, reason: input.reason };
  }

  private async stopWorkflowInstance(
    sessionId: string,
    workflowInstanceId: string,
    stoppedBy: string,
    reason: string,
    publish: (event: SessionEvent) => void
  ) {
    const instance = (await this.workflowInstancesForSession(sessionId)).find((candidate) => candidate.workflowInstanceId === workflowInstanceId);
    if (!instance) {
      throw new Error(`Unknown workflow instance: ${workflowInstanceId}`);
    }
    const stopped = await this.appendAndPublish({
      eventId: makeEventId(),
      sessionId,
      agentId: stoppedBy,
      timestamp: new Date().toISOString(),
      type: "workflow.stopped",
      payload: {
        workflowInstanceId,
        workflowId: instance?.workflowId,
        callerAgentId: instance?.callerAgentId,
        stoppedBy,
        reason
      }
    }, publish);
    const events = await this.store.readEvents(sessionId);
    const stoppedAgentIds = new Set(events
      .filter((event) => event.type === "agent.stopped" && event.payload.workflowInstanceId === workflowInstanceId && event.agentId)
      .map((event) => event.agentId as string));
    for (const agentId of instance.agentIds) {
      if (stoppedAgentIds.has(agentId)) continue;
      this.activeRuns.get(runKey(sessionId, agentId))?.abort();
      await this.appendAndPublish({
        eventId: makeEventId(),
        sessionId,
        agentId,
        timestamp: new Date().toISOString(),
        type: "agent.status",
        payload: { status: "cancelled", workflowInstanceId, reason },
        causationId: stopped.eventId
      }, publish);
    }
  }

  private async maybeCompleteWorkflow(
    sessionId: string,
    workflowInstanceId: string,
    publish: (event: SessionEvent) => void,
    causationId?: string
  ) {
    const instance = (await this.workflowInstancesForSession(sessionId)).find((candidate) => candidate.workflowInstanceId === workflowInstanceId);
    if (!instance || await this.isWorkflowClosed(sessionId, workflowInstanceId)) return;
    const events = await this.store.readEvents(sessionId);
    const stoppedAgentIds = new Set(events
      .filter((event) => event.type === "agent.stopped" && event.payload.workflowInstanceId === workflowInstanceId && event.agentId)
      .map((event) => event.agentId as string));
    const pendingAgentIds = instance.agentIds.filter((candidate) => !stoppedAgentIds.has(candidate));
    if (pendingAgentIds.length > 0) return;
    const completed = await this.appendAndPublish({
      eventId: makeEventId(),
      sessionId,
      agentId: instance.callerAgentId,
      timestamp: new Date().toISOString(),
      type: "workflow.completed",
      payload: {
        workflowInstanceId,
        workflowId: instance.workflowId,
        callerAgentId: instance.callerAgentId,
        completedAgentIds: instance.agentIds,
        completionCriteria: instance.completionCriteria,
        message: `Workflow ${instance.workflowId} completed: all agents stopped.`
      },
      causationId
    }, publish);
    await this.appendAndPublish({
      eventId: makeEventId(),
      sessionId,
      agentId: instance.callerAgentId,
      timestamp: new Date().toISOString(),
      type: "message.sent",
      payload: {
        from: workflowInstanceId,
        to: instance.callerAgentId,
        text: `Workflow ${instance.workflowId} completed: all agents stopped.`,
        workflowInstanceId,
        workflowId: instance.workflowId
      },
      causationId: completed.eventId
    }, publish);
  }

  private canHandoffFrom(
    snapshot: SessionSnapshot,
    spec: WorkflowSpec,
    nodeMap: Map<string, string>,
    fromNodeId: string,
    toNodeId: string,
    workflowInstanceId: string
  ) {
    const node = spec.nodes.find((candidate) => candidate.id === fromNodeId);
    if (!node || node.dependencies.length === 0) return true;
    if (node.dependencies.includes(toNodeId)) return true;
    return node.dependencies.every((dependency) => {
      const mappedDependency = nodeMap.get(dependency) ?? dependency;
      return snapshot.transcript.some((event) => event.type === "agent.stopped" && event.agentId === mappedDependency && event.payload.workflowInstanceId === workflowInstanceId)
        || snapshot.transcript.some((event) => event.type === "handoff.created" && event.payload.from === mappedDependency && (!event.payload.workflowInstanceId || event.payload.workflowInstanceId === workflowInstanceId));
    });
  }

  private async canAgentStop(sessionId: string, instance: WorkflowInstance, agentId: string) {
    const unresolved = await this.unresolvedStopDependencies(sessionId, instance, agentId);
    return unresolved.dependencies.length === 0 && unresolved.activeChildWorkflows.length === 0;
  }

  private async unresolvedStopDependencies(sessionId: string, instance: WorkflowInstance, agentId: string) {
    const events = await this.store.readEvents(sessionId);
    const originalNodeId = [...instance.nodeMap.entries()].find(([, mapped]) => mapped === agentId)?.[0];
    const spec = this.workflows.get(instance.workflowId);
    const dependencies = originalNodeId
      ? (spec.nodes.find((node) => node.id === originalNodeId)?.dependencies ?? [])
        .map((dependency) => instance.nodeMap.get(dependency) ?? dependency)
        .filter((dependencyAgentId) => !events.some((event) => event.type === "agent.stopped" && event.agentId === dependencyAgentId && event.payload.workflowInstanceId === instance.workflowInstanceId)
          && !events.some((event) => event.type === "handoff.created" && event.payload.from === dependencyAgentId && (!event.payload.workflowInstanceId || event.payload.workflowInstanceId === instance.workflowInstanceId)))
      : [];
    const activeChildWorkflows = (await this.workflowInstancesForSession(sessionId))
      .filter((child) => child.callerAgentId === agentId)
      .filter((child) => child.workflowInstanceId !== instance.workflowInstanceId)
      .filter((child) => !events.some((event) => ["workflow.completed", "workflow.stopped"].includes(event.type) && event.payload.workflowInstanceId === child.workflowInstanceId))
      .map((child) => child.workflowInstanceId);
    return { dependencies, activeChildWorkflows };
  }

  private async inferActiveWorkflowForAgent(sessionId: string, agentId: string) {
    const instances = await this.workflowInstancesForSession(sessionId);
    const events = await this.store.readEvents(sessionId);
    return [...instances].reverse().find((instance) =>
      instance.agentIds.includes(agentId)
      && !events.some((event) => ["workflow.completed", "workflow.stopped"].includes(event.type) && event.payload.workflowInstanceId === instance.workflowInstanceId)
    );
  }

  private async isWorkflowClosed(sessionId: string, workflowInstanceId: string) {
    return (await this.store.readEvents(sessionId))
      .some((event) => ["workflow.completed", "workflow.stopped"].includes(event.type) && event.payload.workflowInstanceId === workflowInstanceId);
  }

  private async workflowInstancesForSession(sessionId: string): Promise<WorkflowInstance[]> {
    return (await this.store.readEvents(sessionId))
      .filter((event) => event.type === "workflow.instantiated")
      .map((event) => {
        const nodeMap = new Map(Object.entries(objectPayload(event.payload.nodeMap)).map(([key, value]) => [key, String(value)]));
        const workflowInstanceId = String(event.payload.workflowInstanceId ?? event.eventId);
        const workflowId = String(event.payload.workflowId ?? "");
        const callerAgentId = String(event.payload.callerAgentId ?? event.payload.anchorNodeId ?? event.agentId ?? "orchestrator");
        const agentIds = [...new Set([...nodeMap.values()].filter((value) => value !== callerAgentId))];
        return {
          workflowInstanceId,
          workflowId,
          callerAgentId,
          nodeMap,
          agentIds,
          completionCriteria: event.payload.completionCriteria
        };
      });
  }

  private async assertLiveCredentialAvailable() {
    if (this.options.runtime) return;
    if (await this.auth.loadLiveConnection()) return;
    throw new Error("OpenAI authentication is required for non-debug sessions. Connect OpenAI OAuth in Settings or add an API key.");
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

  private promptForPlanAgent(planWorkflow: PlanSpec["workflows"][number], nodeId: string, originalGoal: string, edgeDescription = "", incomingMessage?: string) {
    const roleKey = nodeId.split("_").at(-1) ?? nodeId;
    const explicitPrompt = planWorkflow.agentPrompts[nodeId] ?? planWorkflow.agentPrompts[roleKey];
    const doneCriteria = planWorkflow.doneCriteria[nodeId] ?? planWorkflow.doneCriteria[roleKey] ?? [];
    const completionCriteria = planWorkflow.completionCriteria[nodeId] ?? planWorkflow.completionCriteria[roleKey] ?? [];
    const defaultTask = defaultTaskForRole(roleKey, planWorkflow.workflowId);
    return [
      explicitPrompt,
      `Original user goal:\n${originalGoal}`,
      `Workflow: ${planWorkflow.workflowId}`,
      `Assigned role: ${roleKey}`,
      edgeDescription ? `Transition instruction: ${edgeDescription}` : undefined,
      incomingMessage ? `Incoming message or artifact from the previous agent:\n${incomingMessage}` : undefined,
      `Task: ${defaultTask}`,
      doneCriteria.length > 0 ? `Done criteria:\n${doneCriteria.map((criterion) => `- ${criterion}`).join("\n")}` : undefined,
      completionCriteria.length > 0 ? `Completion criteria:\n${completionCriteria.map((criterion) => `- ${criterion.description}`).join("\n")}` : undefined,
      "Use the available workflow/workspace tools. Report concrete files, commands, findings, and acceptance status instead of asking for context already present here."
    ].filter(Boolean).join("\n\n");
  }

  private latestAgentMessage(snapshot: SessionSnapshot, agentId: string) {
    const event = [...snapshot.transcript].reverse().find((candidate) => candidate.agentId === agentId && candidate.type === "agent.message");
    return event?.payload.text ? String(event.payload.text) : undefined;
  }

  private async openAIConnection(debugMode: boolean) {
    if (debugMode) return undefined;
    if (this.options.runtime) return undefined;
    return this.auth.loadLiveConnection();
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

  private canEmitFrom(snapshot: SessionSnapshot, agentId: string) {
    const status = snapshot.graph.nodes.find((node) => node.id === agentId)?.status ?? "idle";
    return !["paused", "cancelled", "failed"].includes(status);
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

  private async recoverInterruptedRuns(
    publish: (event: SessionEvent) => void = () => {},
    publishLog: (entry: DebugLogEntry) => void = () => {}
  ) {
    if (this.recoveryComplete) return;
    try {
      for (const sessionId of await this.store.listSessionIds()) {
        const events = await this.store.readEvents(sessionId);
        const closedJobIds = new Set(events
          .filter((event) => ["scheduler.job.completed", "scheduler.job.failed", "scheduler.job.recovered"].includes(event.type))
          .map((event) => String(event.payload.jobId ?? ""))
          .filter(Boolean));
        const openJobs = new Map<string, SessionEvent>();
        for (const event of events) {
          if (!["scheduler.job.created", "scheduler.job.started", "scheduler.job.heartbeat"].includes(event.type)) continue;
          const jobId = String(event.payload.jobId ?? "");
          if (!jobId || closedJobIds.has(jobId)) continue;
          openJobs.set(jobId, event);
        }
        for (const [jobId, event] of openJobs) {
          const agentId = event.agentId ?? String(event.payload.agentId ?? "");
          if (!agentId || this.activeRuns.has(runKey(sessionId, agentId))) continue;
          const recovered = await this.appendAndPublish({
            eventId: makeEventId(),
            sessionId,
            agentId,
            timestamp: new Date().toISOString(),
            type: "scheduler.job.recovered",
            payload: {
              jobId,
              reason: "Daemon restarted before this scheduler job reached a terminal event.",
              recoveredFromEventId: event.eventId
            },
            causationId: event.eventId,
            correlationId: jobId
          }, publish);
          await this.appendAndPublish({
            eventId: makeEventId(),
            sessionId,
            agentId,
            timestamp: new Date().toISOString(),
            type: "error",
            payload: {
              message: "Daemon restarted while this agent turn was in progress; the run was marked interrupted.",
              jobId
            },
            causationId: recovered.eventId,
            correlationId: jobId
          }, publish);
          await this.appendAndPublish({
            eventId: makeEventId(),
            sessionId,
            agentId,
            timestamp: new Date().toISOString(),
            type: "agent.status",
            payload: { status: "failed", reason: "interrupted by daemon restart", jobId },
            causationId: recovered.eventId,
            correlationId: jobId
          }, publish);
          await this.appendDebugLog(
            sessionId,
            "warn",
            "scheduler",
            `Recovered interrupted scheduler job ${jobId}.`,
            { jobId, agentId, recoveredFromEventId: event.eventId },
            publishLog,
            agentId,
            recovered.eventId
          );
        }
        if (openJobs.size > 0) {
          await this.store.rebuildSnapshot(sessionId);
        }
      }
      this.recoveryComplete = true;
    } catch (error) {
      this.recoveryComplete = false;
      throw error;
    }
  }

  private async startScheduledTurn(
    sessionId: string,
    agentId: string,
    publish: (event: SessionEvent) => void,
    metadata: {
      kind: string;
      prompt: string;
      workflowInstanceId?: string;
      workflowId?: string;
      callerAgentId?: string;
      causationId?: string;
    }
  ): Promise<ScheduledJob> {
    const jobId = `job_${crypto.randomUUID()}`;
    const created = await this.appendAndPublish({
      eventId: makeEventId(),
      sessionId,
      agentId,
      timestamp: new Date().toISOString(),
      type: "scheduler.job.created",
      payload: {
        jobId,
        kind: metadata.kind,
        agentId,
        prompt: metadata.prompt,
        workflowInstanceId: metadata.workflowInstanceId,
        workflowId: metadata.workflowId,
        callerAgentId: metadata.callerAgentId
      },
      causationId: metadata.causationId,
      correlationId: jobId
    }, publish);
    await this.appendAndPublish({
      eventId: makeEventId(),
      sessionId,
      agentId,
      timestamp: new Date().toISOString(),
      type: "scheduler.job.started",
      payload: { jobId, kind: metadata.kind, agentId },
      causationId: created.eventId,
      correlationId: jobId
    }, publish);
    const heartbeat = setInterval(() => {
      void this.appendAndPublish({
        eventId: makeEventId(),
        sessionId,
        agentId,
        timestamp: new Date().toISOString(),
        type: "scheduler.job.heartbeat",
        payload: { jobId, kind: metadata.kind, agentId },
        causationId: created.eventId,
        correlationId: jobId
      }, publish).catch(() => {});
    }, 30_000);
    return { jobId, kind: metadata.kind, createdEventId: created.eventId, heartbeat };
  }

  private async finishScheduledTurn(
    sessionId: string,
    agentId: string,
    job: ScheduledJob,
    publish: (event: SessionEvent) => void,
    status: "completed" | "failed",
    eventCount: number,
    message?: unknown
  ) {
    clearInterval(job.heartbeat);
    await this.appendAndPublish({
      eventId: makeEventId(),
      sessionId,
      agentId,
      timestamp: new Date().toISOString(),
      type: status === "failed" ? "scheduler.job.failed" : "scheduler.job.completed",
      payload: {
        jobId: job.jobId,
        kind: job.kind,
        agentId,
        eventCount,
        message
      },
      causationId: job.createdEventId,
      correlationId: job.jobId
    }, publish);
  }

  private async failScheduledSideEffect(
    sessionId: string,
    agentId: string,
    job: ScheduledJob,
    publish: (event: SessionEvent) => void,
    error: unknown,
    causationId?: string
  ) {
    const message = error instanceof Error ? error.message : String(error);
    await this.appendAndPublish({
      eventId: makeEventId(),
      sessionId,
      agentId,
      timestamp: new Date().toISOString(),
      type: "error",
      payload: { message, jobId: job.jobId },
      causationId,
      correlationId: job.jobId
    }, publish);
    await this.appendAndPublish({
      eventId: makeEventId(),
      sessionId,
      agentId,
      timestamp: new Date().toISOString(),
      type: "agent.status",
      payload: { status: "failed", jobId: job.jobId },
      causationId,
      correlationId: job.jobId
    }, publish);
    await this.store.rebuildSnapshot(sessionId);
    await this.finishScheduledTurn(sessionId, agentId, job, publish, "failed", 2, message);
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

function defaultTaskForRole(roleId: string, workflowId: string) {
  switch (roleId) {
    case "planner":
      return "Create a decision-complete PlanSpec for the original user goal. Select one or more available workflows, provide agentPrompts and doneCriteria for every participating role, call plan_create, then stop with the plan artifact.";
    case "orchestrator":
      return "Coordinate the workflow through planner-created plans and workflow tools. Instantiate concrete plans, inspect agent state, and send messages to agents without writing files directly.";
    case "implementor":
      return "Implement the requested project in the session workspace. Create or edit the needed files through workspace_write_file, include tests/docs when requested, and stop only after downstream review/QA dependencies are satisfied.";
    case "reviewer":
      return "Review the implementation transcript, touched files, and diffs. Send concise blocking findings to the implementor or report approval.";
    case "qa":
      return "Run acceptance checks against the workspace using the available tools. Report exact commands, pass/fail status, and any unmet criteria.";
    case "researcher":
      return "Gather focused research needed for the original goal and return sources or implementation guidance to the requesting agent.";
    default:
      return `Execute the ${roleId} responsibilities in workflow ${workflowId} against the original user goal.`;
  }
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

function objectPayload(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
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

async function listDirectoryTree(directoryPath: string, workspaceRoot: string, depth = 0): Promise<string[]> {
  if (depth > 4) return [];
  const entries = await readdir(directoryPath, { withFileTypes: true });
  const lines: string[] = [];
  for (const entry of entries.sort((a, b) => a.name.localeCompare(b.name)).slice(0, 80)) {
    if (entry.name === "__pycache__" || entry.name === ".git") continue;
    const absolute = path.join(directoryPath, entry.name);
    const relative = path.relative(workspaceRoot, absolute) || ".";
    lines.push(entry.isDirectory() ? `${relative}/` : relative);
    if (entry.isDirectory()) {
      lines.push(...await listDirectoryTree(absolute, workspaceRoot, depth + 1));
    }
  }
  return lines;
}

function truncateForToolResult(text: string, maxLength: number) {
  return text.length > maxLength ? `${text.slice(0, maxLength)}...` : text;
}

function isNegativeCompletion(reason: string) {
  return /\b(unable|cannot|can't|couldn.t|failed|blocked|not functioning|did not|no usable)\b/i.test(reason);
}

function modelForRun(snapshot: SessionSnapshot, role?: { model?: string }) {
  const configured = typeof snapshot.model === "string" && snapshot.model.trim() ? snapshot.model.trim() : undefined;
  return configured ?? role?.model;
}

function reasoningEffortForRun(snapshot: SessionSnapshot) {
  const value = typeof snapshot.reasoningEffort === "string" ? snapshot.reasoningEffort : undefined;
  return ["none", "minimal", "low", "medium", "high", "xhigh"].includes(value ?? "")
    ? value as "none" | "minimal" | "low" | "medium" | "high" | "xhigh"
    : undefined;
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
