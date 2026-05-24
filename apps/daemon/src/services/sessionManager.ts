import type { DaemonRequest, SessionEvent } from "@multiagent/shared";
import { type GraphState, type SessionSnapshot } from "@multiagent/shared";
import { EventStore, makeEventId } from "./eventStore.js";
import { OpenAIAgentRuntime, type AgentRuntime } from "./agentRuntime.js";
import { WorkflowEngine } from "./workflowEngine.js";
import { WorkspaceCoordinator } from "./workspaceCoordinator.js";

export class SessionManager {
  private readonly subscribers = new Map<string, Set<(event: SessionEvent) => void>>();
  private readonly store: EventStore;
  private readonly runtime: AgentRuntime;
  private readonly workflows = new WorkflowEngine();
  private readonly workspace = new WorkspaceCoordinator();

  constructor(private readonly options: { sessionsRoot: string; runtime?: AgentRuntime }) {
    this.store = new EventStore(options.sessionsRoot);
    this.runtime = options.runtime ?? new OpenAIAgentRuntime();
  }

  setPublisher(publish: (event: SessionEvent) => void) {
    this.subscribers.set("*", new Set([publish]));
  }

  async handle(request: DaemonRequest, publish: (event: SessionEvent) => void = () => {}): Promise<unknown> {
    await this.workflows.loadPredefined();
    switch (request.method) {
      case "listSessions":
        return { sessionsRoot: this.options.sessionsRoot, workflows: this.workflows.list(), sessions: await this.store.listSessions() };
      case "createSession": {
        const sessionId = `sess_${crypto.randomUUID()}`;
        const title = firstLine(request.params.prompt) || "Untitled Session";
        const spec = this.workflows.get(request.params.workflowId ?? (request.params.debugMode ? "implementor-reviewer" : "planner-orchestrator"));
        const graph: GraphState = this.workflows.graphForSession(sessionId, spec);
        const snapshot = await this.store.createSession({
          sessionId,
          title,
          workspaceRoot: request.params.workspaceRoot ?? process.cwd(),
          workflowId: spec.id,
          debugMode: request.params.debugMode,
          graph
        });
        await this.recordOrchestratorTurn(snapshot, request.params.prompt, request.params.debugMode, publish);
        await this.activateWorkflowStart(snapshot, publish);
        if (request.params.debugMode) {
          await this.seedDebugWorkspaceEvents(sessionId, request.params.workspaceRoot ?? process.cwd(), publish);
        }
        return this.store.readSnapshot(sessionId);
      }
      case "getSnapshot":
        return this.store.readSnapshot(request.params.sessionId);
      case "sendMessage": {
        const snapshot = await this.store.readSnapshot(request.params.sessionId);
        const targetAgentId = request.params.targetAgentId ?? "orchestrator";
        const nudge = await this.appendAndPublish({
          eventId: makeEventId(),
          sessionId: request.params.sessionId,
          agentId: targetAgentId,
          timestamp: new Date().toISOString(),
          type: "control.nudge",
          payload: { text: request.params.text }
        }, publish);
        await this.recordOrchestratorTurn(snapshot, request.params.text, snapshot.debugMode, publish, nudge.eventId);
        return this.store.readSnapshot(request.params.sessionId);
      }
      case "subscribeEvents":
        this.addSubscriber(request.params.sessionId, publish);
        return { events: await this.store.readEvents(request.params.sessionId) };
      case "pauseAgent":
        return this.controlEvent(request.params.sessionId, request.params.agentId, "control.pause", "paused", publish);
      case "resumeAgent":
        return this.controlEvent(request.params.sessionId, request.params.agentId, "control.resume", "idle", publish);
      case "cancelAgent":
        return this.controlEvent(request.params.sessionId, request.params.agentId, "control.cancel", "cancelled", publish);
      case "ackClientEvent":
        return { accepted: true };
    }
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
    const promptEvent = await this.appendAndPublish({
      eventId: makeEventId(),
      sessionId: snapshot.sessionId,
      agentId: "orchestrator",
      timestamp: new Date().toISOString(),
      type: "message.sent",
      payload: {
        from: "user",
        to: "orchestrator",
        text: userText
      },
      causationId
    }, publish);
    const events = await this.runtime.runTurn({
      sessionId: snapshot.sessionId,
      agentId: "orchestrator",
      prompt: userText,
      debugMode,
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
    for (const edge of graph.edges.filter((candidate) => candidate.from === "orchestrator" && candidate.kind === "handoff")) {
      const handoff = await this.appendAndPublish({
        eventId: makeEventId(),
        sessionId: snapshot.sessionId,
        agentId: "orchestrator",
        timestamp: new Date().toISOString(),
        type: "handoff.created",
        payload: {
          from: edge.from,
          to: edge.to,
          reason: "workflow start"
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
    }
    for (const edge of graph.edges.filter((candidate) => candidate.kind === "message")) {
      await this.appendAndPublish({
        eventId: makeEventId(),
        sessionId: snapshot.sessionId,
        agentId: edge.from,
        timestamp: new Date().toISOString(),
        type: "message.sent",
        payload: {
          from: edge.from,
          to: edge.to,
          text: "Workflow message link armed."
        }
      }, publish);
      for (const agentId of [edge.from, edge.to]) {
        const current = graph.nodes.find((node) => node.id === agentId)?.status;
        if (current === "idle") {
          await this.appendAndPublish({
            eventId: makeEventId(),
            sessionId: snapshot.sessionId,
            agentId,
            timestamp: new Date().toISOString(),
            type: "agent.status",
            payload: { status: "waiting" }
          }, publish);
        }
      }
    }
    await this.store.rebuildSnapshot(snapshot.sessionId);
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

  private addSubscriber(sessionId: string, publish: (event: SessionEvent) => void) {
    const subscribers = this.subscribers.get(sessionId) ?? new Set<(event: SessionEvent) => void>();
    subscribers.add(publish);
    this.subscribers.set(sessionId, subscribers);
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
