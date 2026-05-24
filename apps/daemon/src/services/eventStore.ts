import { mkdir, readFile, readdir, writeFile, appendFile, rename } from "node:fs/promises";
import { existsSync } from "node:fs";
import path from "node:path";
import {
  GraphStateSchema,
  SessionEventSchema,
  SessionSnapshotSchema,
  type GraphState,
  type SessionEvent,
  type SessionSnapshot
} from "@multiagent/shared";

export interface CreateSessionInput {
  sessionId: string;
  title: string;
  workspaceRoot: string;
  workflowId: string;
  debugMode: boolean;
  graph: GraphState;
}

export class EventStore {
  constructor(private readonly sessionsRoot: string) {}

  async ensureRoot() {
    await mkdir(this.sessionsRoot, { recursive: true });
  }

  sessionDir(sessionId: string) {
    return containedPath(this.sessionsRoot, sessionId);
  }

  async assertSessionExists(sessionId: string) {
    const dir = this.sessionDir(sessionId);
    if (!existsSync(path.join(dir, "events.jsonl"))) {
      throw new Error(`Unknown session: ${sessionId}`);
    }
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
        debugMode: input.debugMode,
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
      debugMode: input.debugMode,
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
      const agentDir = containedPath(dir, parsed.agentId);
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
    const events: SessionEvent[] = [];
    const invalidLines: string[] = [];
    for (const line of raw.split("\n").filter(Boolean)) {
      try {
        events.push(SessionEventSchema.parse(JSON.parse(line)));
      } catch {
        invalidLines.push(line);
      }
    }
    if (invalidLines.length > 0) {
      await appendFile(path.join(this.sessionDir(sessionId), "events.invalid.jsonl"), invalidLines.join("\n") + "\n", "utf8");
    }
    return events;
  }

  async readSnapshot(sessionId: string): Promise<SessionSnapshot> {
    const snapshotPath = path.join(this.sessionDir(sessionId), "snapshot.json");
    if (existsSync(snapshotPath)) {
      const raw = JSON.parse(await readFile(snapshotPath, "utf8"));
      const parsed = SessionSnapshotSchema.safeParse(raw);
      if (parsed.success) {
        const normalized = normalizeSnapshot(parsed.data, Object.prototype.hasOwnProperty.call(raw, "debugMode"));
        if (JSON.stringify(normalized) !== JSON.stringify(raw)) {
          await this.writeSnapshot(normalized);
        }
        return normalized;
      }
    }
    return this.rebuildSnapshot(sessionId);
  }

  async writeSnapshot(snapshot: SessionSnapshot) {
    GraphStateSchema.parse(snapshot.graph);
    const snapshotPath = path.join(this.sessionDir(snapshot.sessionId), "snapshot.json");
    const tmpPath = `${snapshotPath}.${process.pid}.${crypto.randomUUID()}.tmp`;
    await writeFile(tmpPath, `${JSON.stringify(snapshot, null, 2)}\n`, "utf8");
    await rename(tmpPath, snapshotPath);
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
    const debugMode = created.payload.debugMode === true;
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
    const ackedEventIds = new Set(
      events
        .filter((event) => event.type === "client.ack")
        .map((event) => String(event.payload.ackedEventId ?? ""))
        .filter(Boolean)
    );
    graph.nodes = graph.nodes.map((node) => {
      const ackedMessages = events.filter((event) => ackedEventIds.has(event.eventId) && event.agentId === node.id);
      const latestAck = ackedMessages.at(-1)?.timestamp ?? "";
      return {
        ...node,
        status: deriveStatus(events, node.id),
        unreadCount: events.filter((event) => event.agentId === node.id && event.type === "agent.message" && event.timestamp > latestAck).length,
        errorCount: events.filter((event) => event.agentId === node.id && event.type === "error").length
      };
    });
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
    const activeToolCalls = new Map<string, { agentId: string; toolName: string; callId: string }>();
    for (const event of events) {
      if (!event.agentId) continue;
      if (event.type === "agent.tool_call") {
        const callId = String(event.payload.callId ?? event.eventId);
        activeToolCalls.set(callId, {
          agentId: event.agentId,
          toolName: String(event.payload.toolName ?? "unknown"),
          callId
        });
      }
      if (event.type === "agent.tool_result") {
        const callId = String(event.payload.callId ?? "");
        if (callId) {
          activeToolCalls.delete(callId);
        } else {
          for (const [key, call] of activeToolCalls) {
            if (call.agentId === event.agentId && call.toolName === event.payload.toolName) {
              activeToolCalls.delete(key);
            }
          }
        }
      }
    }
    graph.activeToolCalls = [...activeToolCalls.values()];

    const snapshot: SessionSnapshot = {
      sessionId,
      title,
      createdAt: created.timestamp,
      updatedAt,
      workspaceRoot,
      workflowId,
      debugMode,
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

function containedPath(root: string, child: string) {
  if (!/^[A-Za-z0-9_-]+$/.test(child)) {
    throw new Error(`Unsafe path id: ${child}`);
  }
  const resolvedRoot = path.resolve(root);
  const resolved = path.resolve(resolvedRoot, child);
  if (resolved !== resolvedRoot && !resolved.startsWith(`${resolvedRoot}${path.sep}`)) {
    throw new Error(`Path escapes root: ${child}`);
  }
  return resolved;
}

function normalizeSnapshot(snapshot: SessionSnapshot, hasExplicitDebugMode: boolean): SessionSnapshot {
  if (hasExplicitDebugMode) return snapshot;
  return {
    ...snapshot,
    debugMode: snapshot.transcript.some((event) => event.payload.runtime === "deterministic")
  };
}
