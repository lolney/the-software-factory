import { mkdir, readFile, readdir, writeFile, appendFile, rename, open, unlink } from "node:fs/promises";
import { existsSync } from "node:fs";
import { createHash } from "node:crypto";
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

interface CompactionMetadata {
  sessionId: string;
  compactedAt: string;
  compactedThroughSequenceId: number;
  eventCount: number;
  snapshotChecksum: string;
}

export class EventStore {
  private readonly appendLocks = new Map<string, Promise<void>>();

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

    const appendedCreated = await this.append(created);
    const transcript = [appendedCreated];
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
      transcript.push(await this.append(agentCreated));
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
    return this.withSessionAppendLock(event.sessionId, async () => {
      const dir = this.sessionDir(event.sessionId);
      await mkdir(dir, { recursive: true });
      const sequenceId = await this.nextSequenceId(event.sessionId);
      const parsed = SessionEventSchema.parse({
        ...event,
        payload: {
          ...event.payload,
          sequenceId
        }
      });
      await appendFile(path.join(dir, "events.jsonl"), `${JSON.stringify(frameForEvent(parsed))}\n`, "utf8");

      if (parsed.agentId) {
        const agentDir = containedPath(dir, parsed.agentId);
        await mkdir(agentDir, { recursive: true });
        await appendFile(path.join(agentDir, "transcript.jsonl"), `${JSON.stringify(frameForEvent(parsed))}\n`, "utf8");
      }

      await this.updateIndexes(parsed);
      return parsed;
    });
  }

  private async withSessionAppendLock<T>(sessionId: string, work: () => Promise<T>) {
    await mkdir(this.sessionDir(sessionId), { recursive: true });
    const previous = this.appendLocks.get(sessionId) ?? Promise.resolve();
    let release!: () => void;
    const current = new Promise<void>((resolve) => {
      release = resolve;
    });
    const chained = previous.then(() => current, () => current);
    this.appendLocks.set(sessionId, chained);
    await previous.catch(() => undefined);
    const fileLock = await acquireFileLock(path.join(this.sessionDir(sessionId), ".append.lock"));
    try {
      return await work();
    } finally {
      await fileLock.release();
      release();
      if (this.appendLocks.get(sessionId) === chained) {
        this.appendLocks.delete(sessionId);
      }
    }
  }

  private async nextSequenceId(sessionId: string) {
    const events = await this.readEvents(sessionId);
    return events.reduce((max, event, index) => Math.max(max, sequenceOf(event, index)), 0) + 1;
  }

  private async updateIndexes(event: SessionEvent) {
    const dir = path.join(this.sessionDir(event.sessionId), "indexes");
    await mkdir(dir, { recursive: true });
    const events = await this.readEvents(event.sessionId);
    const agentIndex: Record<string, string[]> = {};
    const toolIndex: Record<string, Record<string, unknown>> = {};
    for (const replayed of events) {
      if (replayed.agentId) {
        agentIndex[replayed.agentId] = [...(agentIndex[replayed.agentId] ?? []), replayed.eventId];
      }
      const callId = typeof replayed.payload.callId === "string" ? replayed.payload.callId : undefined;
      if (callId && (replayed.type === "agent.tool_call" || replayed.type === "agent.tool_result")) {
        const existing = toolIndex[callId] ?? {};
        toolIndex[callId] = {
          ...existing,
          callId,
          agentId: replayed.agentId,
          toolName: typeof replayed.payload.toolName === "string" ? replayed.payload.toolName : existing.toolName,
          callEventId: replayed.type === "agent.tool_call" ? replayed.eventId : existing.callEventId,
          resultEventId: replayed.type === "agent.tool_result" ? replayed.eventId : existing.resultEventId,
          status: replayed.type === "agent.tool_result" ? "completed" : existing.status ?? "running",
          updatedAt: replayed.timestamp
        };
      }
    }
    await writeJsonFile(path.join(dir, "events.json"), {
      sessionId: event.sessionId,
      eventCount: events.length,
      lastSequenceId: events.reduce((max, replayed, index) => Math.max(max, sequenceOf(replayed, index)), 0),
      updatedAt: event.timestamp
    });
    await writeJsonFile(path.join(dir, "agents.json"), agentIndex);
    await writeJsonFile(path.join(dir, "tool-calls.json"), toolIndex);
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
      const sessionStatus = deriveSessionStatus(snapshot.graph.nodes, events, snapshot.archived === true);
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
        status: sessionStatus,
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
        events.push(parseEventLine(line));
      } catch (error) {
        invalidLines.push(line);
      }
    }
    if (invalidLines.length > 0) {
      await quarantineInvalidLines(path.join(this.sessionDir(sessionId), "events.invalid.jsonl"), invalidLines);
    }
    return events;
  }

  async compactSnapshot(sessionId: string) {
    return this.withSessionAppendLock(sessionId, async () => {
      const events = await this.readEvents(sessionId);
      const snapshot = await this.rebuildSnapshotUnlocked(sessionId, events);
      const compactedThroughSequenceId = events.reduce((max, event, index) => Math.max(max, sequenceOf(event, index)), 0);
      await this.writeSnapshot(snapshot);
      await writeJsonFile(path.join(this.sessionDir(sessionId), "snapshot.compaction.json"), {
        sessionId,
        compactedAt: new Date().toISOString(),
        compactedThroughSequenceId,
        eventCount: events.length,
        snapshotChecksum: checksum(JSON.stringify(snapshot))
      } satisfies CompactionMetadata);
      return snapshot;
    });
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
      await quarantineInvalidLines(path.join(this.sessionDir(sessionId), "debug.invalid.jsonl"), invalidLines);
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
    return this.withSessionAppendLock(sessionId, async () => {
      const compacted = await this.compactedSnapshotBase(sessionId);
      const events = await this.readEvents(sessionId);
      if (compacted) {
        const seen = new Set(compacted.snapshot.transcript.map((event) => event.eventId));
        const tail = events.filter((event, index) => sequenceOf(event, index) > compacted.metadata.compactedThroughSequenceId && !seen.has(event.eventId));
        const snapshot = await this.rebuildSnapshotUnlocked(sessionId, [...compacted.snapshot.transcript, ...tail]);
        await writeJsonFile(path.join(this.sessionDir(sessionId), "snapshot.compaction.json"), {
          ...compacted.metadata,
          eventCount: events.length,
          snapshotChecksum: checksum(JSON.stringify(snapshot))
        } satisfies CompactionMetadata);
        return snapshot;
      }
      return this.rebuildSnapshotUnlocked(sessionId, events);
    });
  }

  private async compactedSnapshotBase(sessionId: string) {
    const metadata = await readJsonFile<CompactionMetadata>(path.join(this.sessionDir(sessionId), "snapshot.compaction.json"));
    if (!metadata || metadata.sessionId !== sessionId || typeof metadata.compactedThroughSequenceId !== "number") return undefined;
    const snapshotPath = path.join(this.sessionDir(sessionId), "snapshot.json");
    if (!existsSync(snapshotPath)) return undefined;
    const parsed = SessionSnapshotSchema.safeParse(JSON.parse(await readFile(snapshotPath, "utf8")));
    if (!parsed.success) return undefined;
    const snapshot = normalizeSnapshot(parsed.data, true);
    if (metadata.snapshotChecksum !== checksum(JSON.stringify(snapshot))) return undefined;
    return { metadata, snapshot };
  }

  private async rebuildSnapshotUnlocked(sessionId: string, events: SessionEvent[]): Promise<SessionSnapshot> {
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
    await this.rebuildDerivedTranscripts(sessionId, events);
    return snapshot;
  }

  private async rebuildDerivedTranscripts(sessionId: string, events: SessionEvent[]) {
    const dir = this.sessionDir(sessionId);
    const byAgent = new Map<string, SessionEvent[]>();
    for (const event of events) {
      if (!event.agentId) continue;
      byAgent.set(event.agentId, [...(byAgent.get(event.agentId) ?? []), event]);
    }
    for (const [agentId, agentEvents] of byAgent) {
      const agentDir = containedPath(dir, agentId);
      await mkdir(agentDir, { recursive: true });
      await writeFile(path.join(agentDir, "transcript.jsonl"), agentEvents.map((event) => JSON.stringify(frameForEvent(event))).join("\n") + "\n", "utf8");
    }
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

function deriveSessionStatus(nodes: GraphState["nodes"], events: SessionEvent[], archived: boolean) {
  if (archived) return "archived";
  if (nodes.some((node) => node.status === "failed")) return "failed";
  if (events.some((event) => event.type === "error")) return "failed";
  if (nodes.some((node) => ["working", "waiting"].includes(node.status))) return "active";
  if (nodes.some((node) => node.status === "paused")) return "paused";
  const latestWorkflowTerminal = [...events].reverse().find((event) => event.type === "workflow.completed" || event.type === "workflow.stopped");
  if (latestWorkflowTerminal?.type === "workflow.stopped") return "cancelled";
  if (nodes.some((node) => node.status === "cancelled")) return "cancelled";
  if (latestWorkflowTerminal?.type === "workflow.completed") return "completed";
  const latestOrchestratorStatus = [...events].reverse().find((event) => event.agentId === "orchestrator" && event.type === "agent.status")?.payload.status;
  if (latestOrchestratorStatus === "completed") return "completed";
  return "idle";
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

function frameForEvent(event: SessionEvent) {
  const eventJson = JSON.stringify(event);
  return {
    frameVersion: 1,
    checksum: checksum(eventJson),
    event
  };
}

function parseEventLine(line: string) {
  const raw = JSON.parse(line);
  if (raw && typeof raw === "object" && "frameVersion" in raw && "checksum" in raw && "event" in raw) {
    const frame = raw as { checksum?: unknown; event?: unknown };
    const eventJson = JSON.stringify(frame.event);
    if (frame.checksum !== checksum(eventJson)) {
      throw new Error("Event frame checksum mismatch.");
    }
    return SessionEventSchema.parse(frame.event);
  }
  return SessionEventSchema.parse(raw);
}

function checksum(value: string) {
  return createHash("sha256").update(value).digest("hex");
}

function sequenceOf(event: SessionEvent, index = 0) {
  return typeof event.payload.sequenceId === "number" ? event.payload.sequenceId : index + 1;
}

async function quarantineInvalidLines(file: string, invalidLines: string[]) {
  if (invalidLines.length === 0) return;
  const existing = existsSync(file)
    ? new Set((await readFile(file, "utf8")).split("\n").filter(Boolean))
    : new Set<string>();
  const newLines = invalidLines.filter((line) => !existing.has(line));
  if (newLines.length > 0) {
    await appendFile(file, `${newLines.join("\n")}\n`, "utf8");
  }
}

async function acquireFileLock(file: string) {
  await mkdir(path.dirname(file), { recursive: true });
  for (let attempt = 0; attempt < 200; attempt += 1) {
    try {
      const handle = await open(file, "wx");
      await handle.writeFile(JSON.stringify({ pid: process.pid, createdAt: new Date().toISOString() }), "utf8");
      return {
        release: async () => {
          await handle.close();
          await unlink(file).catch(() => undefined);
        }
      };
    } catch (error) {
      const code = (error as { code?: string }).code;
      if (code !== "EEXIST") throw error;
      if (await isStaleLock(file)) {
        await unlink(file).catch(() => undefined);
        continue;
      }
      await delay(Math.min(5 + attempt, 50));
    }
  }
  throw new Error(`Timed out waiting for event store lock: ${file}`);
}

async function isStaleLock(file: string) {
  try {
    const metadata = JSON.parse(await readFile(file, "utf8")) as { pid?: unknown; createdAt?: unknown };
    const pid = typeof metadata.pid === "number" ? metadata.pid : undefined;
    const createdAt = typeof metadata.createdAt === "string" ? Date.parse(metadata.createdAt) : Number.NaN;
    if (!pid) return true;
    if (!isProcessAlive(pid)) return true;
    return Number.isFinite(createdAt) && Date.now() - createdAt > 5 * 60_000;
  } catch {
    return true;
  }
}

function isProcessAlive(pid: number) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function delay(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function writeJsonFile(file: string, value: unknown) {
  await mkdir(path.dirname(file), { recursive: true });
  const tmpPath = `${file}.${process.pid}.${crypto.randomUUID()}.tmp`;
  await writeFile(tmpPath, `${JSON.stringify(value, null, 2)}\n`, "utf8");
  await rename(tmpPath, file);
}

async function readJsonFile<T>(file: string): Promise<T | undefined> {
  if (!existsSync(file)) return undefined;
  try {
    return JSON.parse(await readFile(file, "utf8")) as T;
  } catch {
    return undefined;
  }
}
