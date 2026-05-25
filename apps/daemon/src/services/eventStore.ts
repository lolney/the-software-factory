import { mkdir, readFile, readdir, writeFile, appendFile, rename } from "node:fs/promises";
import { existsSync } from "node:fs";
import path from "node:path";
import {
  GraphStateSchema,
  DebugLogEntrySchema,
  SessionEventSchema,
  SessionSnapshotSchema,
  type DebugLogEntry,
  type GraphState,
  type SessionEvent,
  type SessionSnapshot
} from "@multiagent/shared";

export interface CreateSessionInput {
  sessionId: string;
  title: string;
  goal?: string;
  workspaceRoot: string;
  workflowId: string;
  debugMode: boolean;
  archived?: boolean;
  model?: string;
  reasoningEffort?: "none" | "minimal" | "low" | "medium" | "high" | "xhigh";
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

  async listSessionIds() {
    await this.ensureRoot();
    const entries = await readdir(this.sessionsRoot, { withFileTypes: true });
    return entries
      .filter((entry) => entry.isDirectory())
      .map((entry) => entry.name)
      .filter((name) => /^[A-Za-z0-9_-]+$/.test(name))
      .filter((name) => existsSync(path.join(this.sessionDir(name), "events.jsonl")));
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
        goal: input.goal ?? input.title,
        workspaceRoot: input.workspaceRoot,
        workflowId: input.workflowId,
        debugMode: input.debugMode,
        archived: input.archived ?? false,
        model: input.model,
        reasoningEffort: input.reasoningEffort,
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
      archived: input.archived ?? false,
      model: input.model,
      reasoningEffort: input.reasoningEffort,
      graph: input.graph,
      transcript
    };
    await this.writeSnapshot(snapshot);
    return snapshot;
  }

  async workspaceDir(sessionId: string, baseRoot?: string) {
    const workspaceDir = baseRoot
      ? path.join(path.resolve(baseRoot), sessionId, "workspace")
      : path.join(this.sessionDir(sessionId), "workspace");
    await mkdir(workspaceDir, { recursive: true });
    return workspaceDir;
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

  async appendDebugLog(entry: DebugLogEntry): Promise<DebugLogEntry> {
    const parsed = DebugLogEntrySchema.parse(entry);
    const dir = this.sessionDir(parsed.sessionId);
    await mkdir(dir, { recursive: true });
    await appendFile(path.join(dir, "debug.jsonl"), `${JSON.stringify(parsed)}\n`, "utf8");
    return parsed;
  }

  async listSessions(options: { includeArchived?: boolean } = {}) {
    await this.ensureRoot();
    const entries = await readdir(this.sessionsRoot, { withFileTypes: true });
    const sessions = [];
    for (const entry of entries) {
      if (!entry.isDirectory()) continue;
      const snapshotPath = path.join(this.sessionsRoot, entry.name, "snapshot.json");
      if (!existsSync(snapshotPath)) continue;
      const snapshot = await this.rebuildSnapshot(entry.name);
      const events = await this.readEvents(snapshot.sessionId);
      const updatedAt = events.at(-1)?.timestamp ?? snapshot.updatedAt;
      const activeAgents = snapshot.graph.nodes.filter((node) => ["working", "waiting", "paused"].includes(node.status)).length;
      const failureCount = snapshot.graph.nodes.reduce((total, node) => total + node.errorCount + (node.status === "failed" ? 1 : 0), 0);
      sessions.push({
        id: snapshot.sessionId,
        title: snapshot.title,
        createdAt: snapshot.createdAt,
        updatedAt,
        workflowId: snapshot.workflowId,
        workspaceRoot: snapshot.workspaceRoot,
        archived: snapshot.archived === true,
        debugMode: snapshot.debugMode === true,
        model: snapshot.model,
        reasoningEffort: snapshot.reasoningEffort,
        activeAgents,
        failureCount
      });
    }
    return sessions
      .filter((session) => options.includeArchived || !session.archived)
      .sort((a, b) => b.createdAt.localeCompare(a.createdAt));
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

  async readDebugLogs(sessionId: string): Promise<DebugLogEntry[]> {
    const file = path.join(this.sessionDir(sessionId), "debug.jsonl");
    if (!existsSync(file)) return [];
    const raw = await readFile(file, "utf8");
    const entries: DebugLogEntry[] = [];
    const invalidLines: string[] = [];
    for (const line of raw.split("\n").filter(Boolean)) {
      try {
        entries.push(DebugLogEntrySchema.parse(JSON.parse(line)));
      } catch {
        invalidLines.push(line);
      }
    }
    if (invalidLines.length > 0) {
      await appendFile(path.join(this.sessionDir(sessionId), "debug.invalid.jsonl"), invalidLines.join("\n") + "\n", "utf8");
    }
    return entries;
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
    const model = typeof created.payload.model === "string" ? created.payload.model : undefined;
    const reasoningEffort = parseReasoningEffort(created.payload.reasoningEffort);
    let archived = created.payload.archived === true;
    const updatedAt = events.at(-1)?.timestamp ?? created.timestamp;
    const parsedGraph = GraphStateSchema.safeParse(created.payload.graph);
    let graph: GraphState = parsedGraph.success ? parsedGraph.data : {
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
    for (const event of events) {
      if (event.type !== "graph.updated") continue;
      const parsed = GraphStateSchema.safeParse(event.payload.graph);
      if (parsed.success) {
        graph = parsed.data;
      }
    }
    for (const event of events) {
      if (event.type === "session.archived") {
        archived = true;
      } else if (event.type === "session.restored") {
        archived = false;
      }
    }
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
      if (event.type === "agent.status" && ["cancelled", "failed", "completed"].includes(String(event.payload.status ?? ""))) {
        for (const [key, call] of activeToolCalls) {
          if (call.agentId === event.agentId) {
            activeToolCalls.delete(key);
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
      archived,
      model,
      reasoningEffort,
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

export function makeLogId() {
  return `log_${crypto.randomUUID()}`;
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
  if (hasExplicitDebugMode && typeof snapshot.archived === "boolean") return snapshot;
  return {
    ...snapshot,
    debugMode: hasExplicitDebugMode ? snapshot.debugMode : snapshot.transcript.some((event) => event.payload.runtime === "deterministic"),
    archived: snapshot.archived ?? false
  };
}

function parseReasoningEffort(value: unknown): "none" | "minimal" | "low" | "medium" | "high" | "xhigh" | undefined {
  return ["none", "minimal", "low", "medium", "high", "xhigh"].includes(String(value ?? ""))
    ? String(value) as "none" | "minimal" | "low" | "medium" | "high" | "xhigh"
    : undefined;
}
