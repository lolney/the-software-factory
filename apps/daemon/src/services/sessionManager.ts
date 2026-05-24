import type { DaemonRequest, SessionEvent } from "@multiagent/shared";
import { type GraphState, type SessionSnapshot } from "@multiagent/shared";
import { EventStore, makeEventId } from "./eventStore.js";
import { OpenAIAgentRuntime, type AgentRuntime } from "./agentRuntime.js";

export class SessionManager {
  private publish: (event: SessionEvent) => void = () => {};
  private readonly store: EventStore;
  private readonly runtime: AgentRuntime;

  constructor(private readonly options: { sessionsRoot: string; runtime?: AgentRuntime }) {
    this.store = new EventStore(options.sessionsRoot);
    this.runtime = options.runtime ?? new OpenAIAgentRuntime();
  }

  setPublisher(publish: (event: SessionEvent) => void) {
    this.publish = publish;
  }

  async handle(request: DaemonRequest): Promise<unknown> {
    switch (request.method) {
      case "listSessions":
        return { sessionsRoot: this.options.sessionsRoot, sessions: await this.store.listSessions() };
      case "createSession": {
        const sessionId = `sess_${crypto.randomUUID()}`;
        const title = firstLine(request.params.prompt) || "Untitled Session";
        const graph: GraphState = {
          sessionId,
          workflowId: "orchestrator-basic",
          nodes: [
            {
              id: "orchestrator",
              roleId: "orchestrator",
              label: "Orchestrator",
              status: "idle",
              color: "#4f7cff",
              unreadCount: 0,
              errorCount: 0
            }
          ],
          edges: [],
          activeToolCalls: []
        };
        const snapshot = await this.store.createSession({
          sessionId,
          title,
          workspaceRoot: request.params.workspaceRoot ?? process.cwd(),
          workflowId: "orchestrator-basic",
          graph
        });
        await this.recordOrchestratorTurn(snapshot, request.params.prompt, request.params.debugMode);
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
        });
        await this.recordOrchestratorTurn(snapshot, request.params.text, true, nudge.eventId);
        return this.store.readSnapshot(request.params.sessionId);
      }
      case "subscribeEvents":
        return { events: await this.store.readEvents(request.params.sessionId) };
      case "pauseAgent":
        return this.controlEvent(request.params.sessionId, request.params.agentId, "control.pause", "paused");
      case "resumeAgent":
        return this.controlEvent(request.params.sessionId, request.params.agentId, "control.resume", "idle");
      case "cancelAgent":
        return this.controlEvent(request.params.sessionId, request.params.agentId, "control.cancel", "cancelled");
      case "ackClientEvent":
        return { accepted: true };
    }
  }

  emit(event: SessionEvent) {
    this.publish(event);
  }

  private async recordOrchestratorTurn(snapshot: SessionSnapshot, userText: string, debugMode: boolean, causationId?: string) {
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
    });
    const events = await this.runtime.runTurn({
      sessionId: snapshot.sessionId,
      agentId: "orchestrator",
      prompt: userText,
      debugMode,
      causationId: promptEvent.eventId
    });
    for (const event of events) {
      await this.appendAndPublish(event);
    }
    await this.store.rebuildSnapshot(snapshot.sessionId);
  }

  private async controlEvent(sessionId: string, agentId: string, type: SessionEvent["type"], status: string) {
    const control = await this.appendAndPublish({
      eventId: makeEventId(),
      sessionId,
      agentId,
      timestamp: new Date().toISOString(),
      type,
      payload: {}
    });
    await this.appendAndPublish({
      eventId: makeEventId(),
      sessionId,
      agentId,
      timestamp: new Date().toISOString(),
      type: "agent.status",
      payload: { status },
      causationId: control.eventId
    });
    return this.store.rebuildSnapshot(sessionId);
  }

  private async appendAndPublish(event: SessionEvent) {
    const appended = await this.store.append(event);
    this.publish(appended);
    return appended;
  }
}

function firstLine(text: string) {
  return text.trim().split("\n").find(Boolean)?.slice(0, 80) ?? "";
}
