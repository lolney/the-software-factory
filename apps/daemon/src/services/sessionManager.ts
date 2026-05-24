import type { DaemonRequest, SessionEvent } from "@multiagent/shared";
import { type GraphState, type SessionSnapshot } from "@multiagent/shared";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import path from "node:path";
import { EventStore, makeEventId } from "./eventStore.js";
import { OpenAIAgentRuntime, type AgentRuntime } from "./agentRuntime.js";
import { WorkflowEngine } from "./workflowEngine.js";
import { WorkspaceCoordinator } from "./workspaceCoordinator.js";
import { AuthManager, CODEX_PUBLIC_CLIENT_ID } from "./authManager.js";

export class SessionManager {
  private readonly subscribers = new Map<string, Set<(event: SessionEvent) => void>>();
  private readonly store: EventStore;
  private readonly runtime: AgentRuntime;
  private readonly workflows = new WorkflowEngine();
  private readonly workspace = new WorkspaceCoordinator();
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

  async handle(request: DaemonRequest, publish: (event: SessionEvent) => void = () => {}): Promise<unknown> {
    await this.workflows.loadPredefined();
    await this.loadRoleOverrides();
    switch (request.method) {
      case "listSessions":
        return {
          sessionsRoot: this.options.sessionsRoot,
          workflows: this.workflows.list(),
          roles: this.workflows.listRoles(),
          codexOAuth: await this.auth.status(),
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
      case "listWorkflows":
        return { workflows: this.workflows.list() };
      case "createSession": {
        const sessionId = `sess_${crypto.randomUUID()}`;
        const title = firstLine(request.params.prompt) || "Untitled Session";
        const spec = this.workflows.get(request.params.workflowId ?? (request.params.debugMode ? "implementor-reviewer" : "planner-orchestrator"));
        const graph: GraphState = this.workflows.graphForSession(sessionId, spec);
        const workspaceRoot = await this.store.workspaceDir(sessionId);
        if (!request.params.debugMode) {
          await this.assertLiveCredentialAvailable();
        }
        const snapshot = await this.store.createSession({
          sessionId,
          title,
          workspaceRoot,
          workflowId: spec.id,
          debugMode: request.params.debugMode,
          graph
        });
        await this.initializeWorkspace(workspaceRoot, title);
        await this.recordOrchestratorTurn(snapshot, request.params.prompt, request.params.debugMode, publish);
        await this.activateWorkflowStart(snapshot, publish);
        if (request.params.debugMode) {
          await this.seedDebugWorkspaceEvents(sessionId, workspaceRoot, publish);
        }
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
    const spec = this.workflows.get(snapshot.workflowId);
    const role = this.workflows.roleForNode(spec, agentId);
    const events = await this.runControlledTurn(snapshot.sessionId, agentId, {
      sessionId: snapshot.sessionId,
      agentId,
      prompt: userText,
      debugMode,
      roleName: role?.name,
      instructions: role?.promptTemplate,
      apiKey: await this.openAIApiKey(debugMode),
      workflowTools: this.workflowTools(snapshot.sessionId, publish),
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
    publish(appended);
    this.publish(appended, publish);
    return appended;
  }

  private async activateWorkflowStart(snapshot: SessionSnapshot, publish: (event: SessionEvent) => void) {
    const graph = snapshot.graph;
    const spec = this.workflows.get(snapshot.workflowId);
    const orchestratorId = spec.lifecycle.orchestratorNodeId;
    const runCounts = new Map<string, number>([[orchestratorId, 1]]);
    const processedHandoffs = new Set<string>();
    const maxConcurrent = Math.max(1, spec.concurrency.maxActiveAgents);
    const maxIterationsPerAgent = 2;
    const maxSteps = Math.max(1, (graph.nodes.length + graph.edges.length + 1) * maxIterationsPerAgent);

    for (let step = 0; step < maxSteps; step += 1) {
      const readyHandoffs = graph.edges
        .filter((edge) => edge.kind === "handoff")
        .filter((edge) => (runCounts.get(edge.from) ?? 0) > 0 && !processedHandoffs.has(edge.id));
      if (readyHandoffs.length > 0) {
        const batch = readyHandoffs.slice(0, maxConcurrent);
        await Promise.all(batch.map(async (edge) => {
          processedHandoffs.add(edge.id);
          const handoff = await this.appendAndPublish({
            eventId: makeEventId(),
            sessionId: snapshot.sessionId,
            agentId: edge.from,
            timestamp: new Date().toISOString(),
            type: "handoff.created",
            payload: {
              from: edge.from,
              to: edge.to,
              reason: step === 0 ? "workflow start" : "workflow graph continuation"
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
            await this.runWorkflowAgent(snapshot, edge.to, `Workflow handoff from ${edge.from}: ${edge.id}`, handoff.eventId, publish);
            runCounts.set(edge.to, (runCounts.get(edge.to) ?? 0) + 1);
          }
        }));
        continue;
      }

      const readyMessages = graph.edges
        .filter((edge) => edge.kind === "message")
        .filter((edge) => (runCounts.get(edge.from) ?? 0) > 0 && (runCounts.get(edge.to) ?? 0) < maxIterationsPerAgent);
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
            from: edge.from,
            to: edge.to,
            text: `Workflow message from ${edge.from} to ${edge.to}: ${edge.id}`
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
          await this.runWorkflowAgent(snapshot, edge.to, `Workflow message from ${edge.from}: ${edge.id}`, message.eventId, publish);
          runCounts.set(edge.to, (runCounts.get(edge.to) ?? 0) + 1);
        }
      }));
    }

    const stopSummary = spec.stopCriteria.length > 0 ? spec.stopCriteria.join("; ") : "workflow graph reached quiescence";
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
    const spec = this.workflows.get(snapshot.workflowId);
    const role = this.workflows.roleForNode(spec, agentId);
    const events = await this.runControlledTurn(snapshot.sessionId, agentId, {
      sessionId: snapshot.sessionId,
      agentId,
      prompt,
      debugMode: snapshot.debugMode,
      roleName: role?.name,
      instructions: role?.promptTemplate,
      apiKey: await this.openAIApiKey(snapshot.debugMode),
      workflowTools: this.workflowTools(snapshot.sessionId, publish),
      causationId
    });
    for (const event of events) {
      await this.appendAndPublish(event, publish);
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

  private async seedDebugWorkspaceEvents(sessionId: string, workspaceRoot: string, publish: (event: SessionEvent) => void) {
    const policy = { sessionId, workspaceRoot, allowedRoots: ["."] };
    await this.appendAndPublish(this.workspace.claimFile(policy, "implementor", "src/debug-feature.ts"), publish);
    await this.appendAndPublish(this.workspace.recordTouched(policy, "implementor", "src/debug-feature.ts"), publish);
    await this.appendAndPublish({
      eventId: makeEventId(),
      sessionId,
      agentId: "reviewer",
      timestamp: new Date().toISOString(),
      type: "message.sent",
      payload: {
        from: "reviewer",
        to: "implementor",
        text: "Debug reviewer: add a deterministic QA assertion before marking complete."
      }
    }, publish);
    await this.appendAndPublish({
      eventId: makeEventId(),
      sessionId,
      agentId: "implementor",
      timestamp: new Date().toISOString(),
      type: "agent.status",
      payload: { status: "waiting" }
    }, publish);
    await this.store.rebuildSnapshot(sessionId);
  }

  private async instantiateWorkflow(
    sessionId: string,
    workflowId: string,
    anchorNodeId = "orchestrator",
    publish: (event: SessionEvent) => void
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
      payload: { workflowId, anchorNodeId, nodeMap: Object.fromEntries(nodeMap) }
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
    return this.store.rebuildSnapshot(sessionId);
  }

  private workflowTools(sessionId: string, publish: (event: SessionEvent) => void) {
    return {
      listWorkflows: () => this.workflows.list().map((workflow) => ({
        id: workflow.id,
        name: workflow.name,
        description: workflow.description,
        nodes: workflow.nodes.map((node) => ({ id: node.id, roleId: node.roleId, label: node.label })),
        edges: workflow.edges.map((edge) => ({ id: edge.id, from: edge.from, to: edge.to, kind: edge.kind, description: edge.description }))
      })),
      instantiateWorkflow: async (workflowId: string) => {
        await this.instantiateWorkflow(sessionId, workflowId, "orchestrator", publish);
        return `Instantiated workflow ${workflowId} into session ${sessionId}.`;
      }
    };
  }

  private async assertLiveCredentialAvailable() {
    if (this.options.runtime) return;
    if (process.env.OPENAI_API_KEY) return;
    const tokens = await this.auth.loadTokens();
    if (tokens?.accessToken) return;
    throw new Error("OpenAI authentication is required for non-debug sessions. Connect OpenAI OAuth in Settings or set OPENAI_API_KEY.");
  }

  private async openAIApiKey(debugMode: boolean) {
    if (debugMode) return undefined;
    if (process.env.OPENAI_API_KEY) return process.env.OPENAI_API_KEY;
    return (await this.auth.loadTokens())?.accessToken;
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

  private async runControlledTurn(sessionId: string, agentId: string, input: Parameters<AgentRuntime["runTurn"]>[0]) {
    const key = runKey(sessionId, agentId);
    const controller = new AbortController();
    this.activeRuns.set(key, controller);
    try {
      return await this.runtime.runTurn({ ...input, signal: controller.signal });
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
}

function firstLine(text: string) {
  return text.trim().split("\n").find(Boolean)?.slice(0, 80) ?? "";
}

function runKey(sessionId: string, agentId: string) {
  return `${sessionId}:${agentId}`;
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
