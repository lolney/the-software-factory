import { mkdir, readFile, readdir, writeFile, appendFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import path from "node:path";
import {
  GraphStateSchema,
  SessionEventSchema,
  type GraphState,
  type SessionEvent,
  type SessionSnapshot
} from "@multiagent/shared";

export interface CreateSessionInput {
  sessionId: string;
  title: string;
  workspaceRoot: string;
  workflowId: string;
  graph: GraphState;
}

export class EventStore {
  constructor(private readonly sessionsRoot: string) {}

  async ensureRoot() {
    await mkdir(this.sessionsRoot, { recursive: true });
  }

  sessionDir(sessionId: string) {
    return path.join(this.sessionsRoot, sessionId);
  }

  async createSession(input: CreateSessionInput): Promise<SessionSnapshot> {
    await this.ensureRoot();
    const now = new Date().toISOString();
    const sessionDir = this.sessionDir(input.sessionId);
    await mkdir(sessionDir, { recursive: true });
    await mkdir(path.join(sessionDir, "orchestrator"), { recursive: true });

    const created: SessionEvent = {
      eventId: makeEventId(),
      sessionId: input.sessionId,
      timestamp: now,
      type: "session.created",
      payload: {
        title: input.title,
        workspaceRoot: input.workspaceRoot,
        workflowId: input.workflowId,
        graph: input.graph
      }
    };

    await this.append(created);
    const transcript = [created];
    for (const node of input.graph.nodes) {
      await mkdir(path.join(sessionDir, node.id), { recursive: true });
      const agentCreated: SessionEvent = {
        eventId: makeEventId(),
        sessionId: input.sessionId,
        agentId: node.id,
        timestamp: now,
        type: "agent.created",
        payload: {
          roleId: node.roleId,
          label: node.label,
          color: node.color
        },
        causationId: created.eventId
      };
      await this.append(agentCreated);
      transcript.push(agentCreated);
    }

    const snapshot: SessionSnapshot = {
      sessionId: input.sessionId,
      title: input.title,
      createdAt: now,
      updatedAt: now,
      workspaceRoot: input.workspaceRoot,
      workflowId: input.workflowId,
      graph: input.graph,
      transcript
    };
    await this.writeSnapshot(snapshot);
    return snapshot;
  }

  async append(event: SessionEvent): Promise<SessionEvent> {
    const parsed = SessionEventSchema.parse(event);
    const dir = this.sessionDir(parsed.sessionId);
    await mkdir(dir, { recursive: true });
    await appendFile(path.join(dir, "events.jsonl"), `${JSON.stringify(parsed)}\n`, "utf8");

    if (parsed.agentId) {
      const agentDir = path.join(dir, parsed.agentId);
      await mkdir(agentDir, { recursive: true });
      await appendFile(path.join(agentDir, "transcript.jsonl"), `${JSON.stringify(parsed)}\n`, "utf8");
    }

    return parsed;
  }

  async listSessions() {
    await this.ensureRoot();
    const entries = await readdir(this.sessionsRoot, { withFileTypes: true });
    const sessions = [];
    for (const entry of entries) {
      if (!entry.isDirectory()) continue;
      const snapshotPath = path.join(this.sessionsRoot, entry.name, "snapshot.json");
      if (!existsSync(snapshotPath)) continue;
      const snapshot = JSON.parse(await readFile(snapshotPath, "utf8")) as SessionSnapshot;
      sessions.push({
        id: snapshot.sessionId,
        title: snapshot.title,
        updatedAt: snapshot.updatedAt,
        workflowId: snapshot.workflowId
      });
    }
    return sessions.sort((a, b) => b.updatedAt.localeCompare(a.updatedAt));
  }

  async readEvents(sessionId: string): Promise<SessionEvent[]> {
    const file = path.join(this.sessionDir(sessionId), "events.jsonl");
    if (!existsSync(file)) return [];
    const raw = await readFile(file, "utf8");
    return raw
      .split("\n")
      .filter(Boolean)
      .map((line) => SessionEventSchema.parse(JSON.parse(line)));
  }

  async readSnapshot(sessionId: string): Promise<SessionSnapshot> {
    const snapshotPath = path.join(this.sessionDir(sessionId), "snapshot.json");
    if (existsSync(snapshotPath)) {
      return JSON.parse(await readFile(snapshotPath, "utf8")) as SessionSnapshot;
    }
    return this.rebuildSnapshot(sessionId);
  }

  async writeSnapshot(snapshot: SessionSnapshot) {
    GraphStateSchema.parse(snapshot.graph);
    await writeFile(
      path.join(this.sessionDir(snapshot.sessionId), "snapshot.json"),
      `${JSON.stringify(snapshot, null, 2)}\n`,
      "utf8"
    );
  }

  async rebuildSnapshot(sessionId: string): Promise<SessionSnapshot> {
    const events = await this.readEvents(sessionId);
    const created = events.find((event) => event.type === "session.created");
    if (!created) {
      throw new Error(`Session ${sessionId} has no session.created event.`);
    }

    const title = String(created.payload.title ?? sessionId);
    const workspaceRoot = String(created.payload.workspaceRoot ?? process.cwd());
    const workflowId = String(created.payload.workflowId ?? "orchestrator-basic");
    const updatedAt = events.at(-1)?.timestamp ?? created.timestamp;
    const parsedGraph = GraphStateSchema.safeParse(created.payload.graph);
    const graph: GraphState = parsedGraph.success ? parsedGraph.data : {
      sessionId,
      workflowId,
      nodes: [
        {
          id: "orchestrator",
          roleId: "orchestrator",
          label: "Orchestrator",
          status: deriveStatus(events, "orchestrator"),
          color: "#4f7cff",
          unreadCount: events.filter((event) => event.agentId === "orchestrator" && event.type === "agent.message").length,
          errorCount: events.filter((event) => event.agentId === "orchestrator" && event.type === "error").length
        }
      ],
      edges: [],
      activeToolCalls: []
    };
    graph.nodes = graph.nodes.map((node) => ({
      ...node,
      status: deriveStatus(events, node.id),
      unreadCount: events.filter((event) => event.agentId === node.id && event.type === "agent.message").length,
      errorCount: events.filter((event) => event.agentId === node.id && event.type === "error").length
    }));
    graph.edges = graph.edges.map((edge) => ({
      ...edge,
      active: events.some((event) => {
        if (edge.kind === "handoff" && event.type === "handoff.created") {
          return event.payload.from === edge.from && event.payload.to === edge.to;
        }
        if (edge.kind === "message" && event.type === "message.sent") {
          return event.payload.from === edge.from && event.payload.to === edge.to;
        }
        return false;
      })
    }));
    graph.activeToolCalls = events
      .filter((event) => event.agentId && event.type === "agent.tool_call")
      .map((event) => ({
        agentId: event.agentId!,
        toolName: String(event.payload.toolName ?? "unknown"),
        callId: String(event.payload.callId ?? event.eventId)
      }));

    const snapshot: SessionSnapshot = {
      sessionId,
      title,
      createdAt: created.timestamp,
      updatedAt,
      workspaceRoot,
      workflowId,
      graph,
      transcript: events
    };
    await this.writeSnapshot(snapshot);
    return snapshot;
  }
}

export function makeEventId() {
  return `evt_${crypto.randomUUID()}`;
}

function deriveStatus(events: SessionEvent[], agentId: string) {
  const latest = [...events].reverse().find((event: SessionEvent) => event.agentId === agentId && event.type === "agent.status");
  const status = latest?.payload.status;
  return typeof status === "string" ? status as GraphState["nodes"][number]["status"] : "idle";
}
