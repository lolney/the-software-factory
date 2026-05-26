import { appendFile, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { EventStore, makeEventId, makeLogId } from "./eventStore.js";

describe("EventStore", () => {
  it("persists events and rebuilds a snapshot from JSONL", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-events-"));
    try {
      const store = new EventStore(root);
      const snapshot = await store.createSession({
        sessionId: "sess_test",
        title: "Test session",
        workspaceRoot: root,
        workflowId: "orchestrator-basic",
        debugMode: true,
        graph: {
          sessionId: "sess_test",
          workflowId: "orchestrator-basic",
          nodes: [
            { id: "orchestrator", roleId: "orchestrator", label: "Orchestrator", status: "idle", color: "#4f7cff", unreadCount: 0, errorCount: 0 }
          ],
          edges: [],
          activeToolCalls: []
        }
      });

      await store.append({
        eventId: makeEventId(),
        sessionId: snapshot.sessionId,
        agentId: "orchestrator",
        timestamp: new Date().toISOString(),
        type: "agent.message",
        payload: { text: "hello" }
      });

      const rebuilt = await store.rebuildSnapshot(snapshot.sessionId);
      expect(rebuilt.title).toBe("Test session");
      expect(rebuilt.transcript).toHaveLength(3);
      expect(rebuilt.graph.nodes[0]?.unreadCount).toBe(1);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("skips malformed JSONL lines and keeps valid events replayable", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-events-"));
    try {
      const store = new EventStore(root);
      await store.createSession({
        sessionId: "sess_repair",
        title: "Repair session",
        workspaceRoot: root,
        workflowId: "orchestrator-basic",
        debugMode: false,
        graph: {
          sessionId: "sess_repair",
          workflowId: "orchestrator-basic",
          nodes: [
            { id: "orchestrator", roleId: "orchestrator", label: "Orchestrator", status: "idle", color: "#4f7cff", unreadCount: 0, errorCount: 0 }
          ],
          edges: [],
          activeToolCalls: []
        }
      });
      await appendFile(path.join(root, "sess_repair", "events.jsonl"), "{not-json}\n", "utf8");

      const rebuilt = await store.rebuildSnapshot("sess_repair");
      expect(rebuilt.transcript.length).toBeGreaterThan(0);
      await store.readEvents("sess_repair");
      const invalidLines = (await readFile(path.join(root, "sess_repair", "events.invalid.jsonl"), "utf8")).trim().split("\n");
      expect(invalidLines).toHaveLength(1);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("continues sequence ids after legacy raw JSONL events", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-events-"));
    try {
      const store = new EventStore(root);
      const sessionDir = path.join(root, "sess_legacy");
      await store.ensureRoot();
      await mkdir(sessionDir, { recursive: true });
      await writeFile(path.join(sessionDir, "events.jsonl"), [
        JSON.stringify({
          eventId: makeEventId(),
          sessionId: "sess_legacy",
          timestamp: new Date().toISOString(),
          type: "session.created",
          payload: {
            title: "Legacy session",
            workspaceRoot: root,
            workflowId: "orchestrator-basic",
            debugMode: true,
            graph: {
              sessionId: "sess_legacy",
              workflowId: "orchestrator-basic",
              nodes: [
                { id: "orchestrator", roleId: "orchestrator", label: "Orchestrator", status: "idle", color: "#4f7cff", unreadCount: 0, errorCount: 0 }
              ],
              edges: [],
              activeToolCalls: []
            }
          }
        }),
        JSON.stringify({
          eventId: makeEventId(),
          sessionId: "sess_legacy",
          agentId: "orchestrator",
          timestamp: new Date().toISOString(),
          type: "agent.created",
          payload: { roleId: "orchestrator", label: "Orchestrator", color: "#4f7cff" }
        })
      ].join("\n") + "\n", "utf8");

      const appended = await store.append({
        eventId: makeEventId(),
        sessionId: "sess_legacy",
        agentId: "orchestrator",
        timestamp: new Date().toISOString(),
        type: "agent.message",
        payload: { text: "after migration" }
      });

      expect(appended.payload.sequenceId).toBe(3);
      const eventIndex = JSON.parse(await readFile(path.join(root, "sess_legacy", "indexes", "events.json"), "utf8"));
      expect(eventIndex.eventCount).toBe(3);
      expect(eventIndex.lastSequenceId).toBe(3);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("writes checksummed event frames with monotonic sequence ids and indexes", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-events-"));
    try {
      const store = new EventStore(root);
      await store.createSession({
        sessionId: "sess_indexed",
        title: "Indexed session",
        workspaceRoot: root,
        workflowId: "orchestrator-basic",
        debugMode: true,
        graph: {
          sessionId: "sess_indexed",
          workflowId: "orchestrator-basic",
          nodes: [
            { id: "orchestrator", roleId: "orchestrator", label: "Orchestrator", status: "idle", color: "#4f7cff", unreadCount: 0, errorCount: 0 }
          ],
          edges: [],
          activeToolCalls: []
        }
      });
      await store.append({
        eventId: makeEventId(),
        sessionId: "sess_indexed",
        agentId: "orchestrator",
        timestamp: new Date().toISOString(),
        type: "agent.tool_call",
        payload: { callId: "call_indexed", toolName: "debug.tool" }
      });
      await store.append({
        eventId: makeEventId(),
        sessionId: "sess_indexed",
        agentId: "orchestrator",
        timestamp: new Date().toISOString(),
        type: "agent.tool_result",
        payload: { callId: "call_indexed", toolName: "debug.tool" }
      });

      const lines = (await readFile(path.join(root, "sess_indexed", "events.jsonl"), "utf8")).trim().split("\n");
      expect(JSON.parse(lines[0] ?? "{}").frameVersion).toBe(1);
      const events = await store.readEvents("sess_indexed");
      expect(events.map((event) => event.payload.sequenceId)).toEqual([1, 2, 3, 4]);
      const eventIndex = JSON.parse(await readFile(path.join(root, "sess_indexed", "indexes", "events.json"), "utf8"));
      const agentIndex = JSON.parse(await readFile(path.join(root, "sess_indexed", "indexes", "agents.json"), "utf8"));
      const toolIndex = JSON.parse(await readFile(path.join(root, "sess_indexed", "indexes", "tool-calls.json"), "utf8"));
      expect(eventIndex.lastSequenceId).toBe(4);
      expect(agentIndex.orchestrator).toHaveLength(3);
      expect(toolIndex.call_indexed.status).toBe("completed");
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("rebuilds indexes from the event log when index files are missing", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-events-"));
    try {
      const store = new EventStore(root);
      await store.createSession({
        sessionId: "sess_index_rebuild",
        title: "Index rebuild session",
        workspaceRoot: root,
        workflowId: "orchestrator-basic",
        debugMode: true,
        graph: {
          sessionId: "sess_index_rebuild",
          workflowId: "orchestrator-basic",
          nodes: [
            { id: "orchestrator", roleId: "orchestrator", label: "Orchestrator", status: "idle", color: "#4f7cff", unreadCount: 0, errorCount: 0 }
          ],
          edges: [],
          activeToolCalls: []
        }
      });
      await store.append({
        eventId: makeEventId(),
        sessionId: "sess_index_rebuild",
        agentId: "orchestrator",
        timestamp: new Date().toISOString(),
        type: "agent.message",
        payload: { text: "before index loss" }
      });
      await rm(path.join(root, "sess_index_rebuild", "indexes"), { recursive: true, force: true });
      await store.append({
        eventId: makeEventId(),
        sessionId: "sess_index_rebuild",
        agentId: "orchestrator",
        timestamp: new Date().toISOString(),
        type: "agent.message",
        payload: { text: "after index loss" }
      });

      const eventIndex = JSON.parse(await readFile(path.join(root, "sess_index_rebuild", "indexes", "events.json"), "utf8"));
      const agentIndex = JSON.parse(await readFile(path.join(root, "sess_index_rebuild", "indexes", "agents.json"), "utf8"));
      expect(eventIndex.eventCount).toBe(4);
      expect(eventIndex.lastSequenceId).toBe(4);
      expect(agentIndex.orchestrator).toHaveLength(3);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("skips corrupted checksum frames and preserves valid event replay", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-events-"));
    try {
      const store = new EventStore(root);
      await store.createSession({
        sessionId: "sess_checksum",
        title: "Checksum session",
        workspaceRoot: root,
        workflowId: "orchestrator-basic",
        debugMode: true,
        graph: {
          sessionId: "sess_checksum",
          workflowId: "orchestrator-basic",
          nodes: [
            { id: "orchestrator", roleId: "orchestrator", label: "Orchestrator", status: "idle", color: "#4f7cff", unreadCount: 0, errorCount: 0 }
          ],
          edges: [],
          activeToolCalls: []
        }
      });
      const eventFile = path.join(root, "sess_checksum", "events.jsonl");
      const lines = (await readFile(eventFile, "utf8")).trim().split("\n");
      const corruptFrame = JSON.parse(lines[0] ?? "{}");
      corruptFrame.event.payload.title = "tampered";
      await writeFile(eventFile, `${JSON.stringify(corruptFrame)}\n${lines.slice(1).join("\n")}\n`, "utf8");

      const events = await store.readEvents("sess_checksum");
      expect(events.some((event) => event.type === "agent.created")).toBe(true);
      expect(events.some((event) => event.type === "session.created")).toBe(false);
      const invalid = await readFile(path.join(root, "sess_checksum", "events.invalid.jsonl"), "utf8");
      expect(invalid).toContain("tampered");
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("serializes concurrent appends per session", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-events-"));
    try {
      const store = new EventStore(root);
      await store.createSession({
        sessionId: "sess_concurrent",
        title: "Concurrent session",
        workspaceRoot: root,
        workflowId: "orchestrator-basic",
        debugMode: true,
        graph: {
          sessionId: "sess_concurrent",
          workflowId: "orchestrator-basic",
          nodes: [
            { id: "orchestrator", roleId: "orchestrator", label: "Orchestrator", status: "idle", color: "#4f7cff", unreadCount: 0, errorCount: 0 }
          ],
          edges: [],
          activeToolCalls: []
        }
      });
      await Promise.all(Array.from({ length: 10 }, (_, index) => store.append({
        eventId: makeEventId(),
        sessionId: "sess_concurrent",
        agentId: "orchestrator",
        timestamp: new Date().toISOString(),
        type: "agent.message",
        payload: { text: `message ${index}` }
      })));

      const events = await store.readEvents("sess_concurrent");
      expect(events.map((event) => event.payload.sequenceId)).toEqual(Array.from({ length: 12 }, (_, index) => index + 1));
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("writes snapshot compaction metadata", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-events-"));
    try {
      const store = new EventStore(root);
      await store.createSession({
        sessionId: "sess_compact",
        title: "Compact session",
        workspaceRoot: root,
        workflowId: "orchestrator-basic",
        debugMode: true,
        graph: {
          sessionId: "sess_compact",
          workflowId: "orchestrator-basic",
          nodes: [
            { id: "orchestrator", roleId: "orchestrator", label: "Orchestrator", status: "idle", color: "#4f7cff", unreadCount: 0, errorCount: 0 }
          ],
          edges: [],
          activeToolCalls: []
        }
      });

      const snapshot = await store.compactSnapshot("sess_compact");
      const metadata = JSON.parse(await readFile(path.join(root, "sess_compact", "snapshot.compaction.json"), "utf8"));
      expect(snapshot.sessionId).toBe("sess_compact");
      expect(metadata.compactedThroughSequenceId).toBe(2);
      expect(metadata.eventCount).toBe(2);
      expect(typeof metadata.snapshotChecksum).toBe("string");
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("uses compacted snapshots to recover when older event frames are corrupted", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-events-"));
    try {
      const store = new EventStore(root);
      await store.createSession({
        sessionId: "sess_compact_replay",
        title: "Compact replay session",
        workspaceRoot: root,
        workflowId: "orchestrator-basic",
        debugMode: true,
        graph: {
          sessionId: "sess_compact_replay",
          workflowId: "orchestrator-basic",
          nodes: [
            { id: "orchestrator", roleId: "orchestrator", label: "Orchestrator", status: "idle", color: "#4f7cff", unreadCount: 0, errorCount: 0 }
          ],
          edges: [],
          activeToolCalls: []
        }
      });
      await store.compactSnapshot("sess_compact_replay");
      const eventFile = path.join(root, "sess_compact_replay", "events.jsonl");
      const lines = (await readFile(eventFile, "utf8")).trim().split("\n");
      const corruptFrame = JSON.parse(lines[0] ?? "{}");
      corruptFrame.event.payload.title = "corrupted compacted prefix";
      const tailEvent = {
        eventId: makeEventId(),
        sessionId: "sess_compact_replay",
        agentId: "orchestrator",
        timestamp: new Date().toISOString(),
        type: "agent.message",
        payload: { text: "tail event", sequenceId: 3 }
      };
      await writeFile(eventFile, `${JSON.stringify(corruptFrame)}\n${lines.slice(1).join("\n")}\n${JSON.stringify(tailEvent)}\n`, "utf8");

      const rebuilt = await store.rebuildSnapshot("sess_compact_replay");
      expect(rebuilt.title).toBe("Compact replay session");
      expect(rebuilt.transcript.some((event) => event.payload.text === "tail event")).toBe(true);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("repairs per-agent transcripts from the canonical event log", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-events-"));
    try {
      const store = new EventStore(root);
      await store.createSession({
        sessionId: "sess_transcript_repair",
        title: "Transcript repair session",
        workspaceRoot: root,
        workflowId: "orchestrator-basic",
        debugMode: true,
        graph: {
          sessionId: "sess_transcript_repair",
          workflowId: "orchestrator-basic",
          nodes: [
            { id: "orchestrator", roleId: "orchestrator", label: "Orchestrator", status: "idle", color: "#4f7cff", unreadCount: 0, errorCount: 0 }
          ],
          edges: [],
          activeToolCalls: []
        }
      });
      await store.append({
        eventId: makeEventId(),
        sessionId: "sess_transcript_repair",
        agentId: "orchestrator",
        timestamp: new Date().toISOString(),
        type: "agent.message",
        payload: { text: "repair me" }
      });
      await writeFile(path.join(root, "sess_transcript_repair", "orchestrator", "transcript.jsonl"), "", "utf8");

      await store.rebuildSnapshot("sess_transcript_repair");
      const transcript = await readFile(path.join(root, "sess_transcript_repair", "orchestrator", "transcript.jsonl"), "utf8");
      expect(transcript).toContain("repair me");
      expect(transcript).toContain("frameVersion");
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("recovers stale append lock files left by dead processes", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-events-"));
    try {
      const store = new EventStore(root);
      await store.createSession({
        sessionId: "sess_stale_lock",
        title: "Stale lock session",
        workspaceRoot: root,
        workflowId: "orchestrator-basic",
        debugMode: true,
        graph: {
          sessionId: "sess_stale_lock",
          workflowId: "orchestrator-basic",
          nodes: [
            { id: "orchestrator", roleId: "orchestrator", label: "Orchestrator", status: "idle", color: "#4f7cff", unreadCount: 0, errorCount: 0 }
          ],
          edges: [],
          activeToolCalls: []
        }
      });
      await writeFile(path.join(root, "sess_stale_lock", ".append.lock"), JSON.stringify({ pid: 999_999_999, createdAt: new Date().toISOString() }), "utf8");

      const appended = await store.append({
        eventId: makeEventId(),
        sessionId: "sess_stale_lock",
        agentId: "orchestrator",
        timestamp: new Date().toISOString(),
        type: "agent.message",
        payload: { text: "after stale lock" }
      });
      expect(appended.payload.sequenceId).toBe(3);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("persists and repairs session debug logs", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-events-"));
    try {
      const store = new EventStore(root);
      await store.createSession({
        sessionId: "sess_logs",
        title: "Logs session",
        workspaceRoot: root,
        workflowId: "orchestrator-basic",
        debugMode: false,
        graph: {
          sessionId: "sess_logs",
          workflowId: "orchestrator-basic",
          nodes: [
            { id: "orchestrator", roleId: "orchestrator", label: "Orchestrator", status: "idle", color: "#4f7cff", unreadCount: 0, errorCount: 0 }
          ],
          edges: [],
          activeToolCalls: []
        }
      });
      await store.appendDebugLog({
        logId: makeLogId(),
        sessionId: "sess_logs",
        timestamp: new Date().toISOString(),
        level: "error",
        source: "runtime",
        agentId: "orchestrator",
        message: "model unavailable",
        payload: { code: "unavailable" }
      });
      await appendFile(path.join(root, "sess_logs", "debug.jsonl"), "{not-json}\n", "utf8");

      const logs = await store.readDebugLogs("sess_logs");
      expect(logs).toHaveLength(1);
      expect(logs[0]?.level).toBe("error");
      expect(logs[0]?.message).toBe("model unavailable");
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("clears active tool calls when a result with the same call id is replayed", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-events-"));
    try {
      const store = new EventStore(root);
      await store.createSession({
        sessionId: "sess_tools",
        title: "Tools session",
        workspaceRoot: root,
        workflowId: "orchestrator-basic",
        debugMode: true,
        graph: {
          sessionId: "sess_tools",
          workflowId: "orchestrator-basic",
          nodes: [
            { id: "orchestrator", roleId: "orchestrator", label: "Orchestrator", status: "idle", color: "#4f7cff", unreadCount: 0, errorCount: 0 }
          ],
          edges: [],
          activeToolCalls: []
        }
      });
      await store.append({
        eventId: makeEventId(),
        sessionId: "sess_tools",
        agentId: "orchestrator",
        timestamp: new Date().toISOString(),
        type: "agent.tool_call",
        payload: { callId: "call_1", toolName: "debug.tool" }
      });
      await store.append({
        eventId: makeEventId(),
        sessionId: "sess_tools",
        agentId: "orchestrator",
        timestamp: new Date().toISOString(),
        type: "agent.tool_result",
        payload: { callId: "call_1", toolName: "debug.tool" }
      });

      const rebuilt = await store.rebuildSnapshot("sess_tools");
      expect(rebuilt.graph.activeToolCalls).toEqual([]);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("rebuilds unread counts from client acknowledgements", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-events-"));
    try {
      const store = new EventStore(root);
      await store.createSession({
        sessionId: "sess_ack",
        title: "Ack session",
        workspaceRoot: root,
        workflowId: "orchestrator-basic",
        debugMode: true,
        graph: {
          sessionId: "sess_ack",
          workflowId: "orchestrator-basic",
          nodes: [
            { id: "orchestrator", roleId: "orchestrator", label: "Orchestrator", status: "idle", color: "#4f7cff", unreadCount: 0, errorCount: 0 }
          ],
          edges: [],
          activeToolCalls: []
        }
      });
      const firstMessageId = makeEventId();
      await store.append({
        eventId: firstMessageId,
        sessionId: "sess_ack",
        agentId: "orchestrator",
        timestamp: "2026-01-01T00:00:01.000Z",
        type: "agent.message",
        payload: { text: "first" }
      });
      await store.append({
        eventId: makeEventId(),
        sessionId: "sess_ack",
        timestamp: "2026-01-01T00:00:02.000Z",
        type: "client.ack",
        payload: { ackedEventId: firstMessageId }
      });
      await store.append({
        eventId: makeEventId(),
        sessionId: "sess_ack",
        agentId: "orchestrator",
        timestamp: "2026-01-01T00:00:03.000Z",
        type: "agent.message",
        payload: { text: "second" }
      });

      const rebuilt = await store.rebuildSnapshot("sess_ack");
      expect(rebuilt.graph.nodes[0]?.unreadCount).toBe(1);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("derives completed and active session list statuses from replayed agent state", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-events-"));
    try {
      const store = new EventStore(root);
      await store.createSession({
        sessionId: "sess_completed_status",
        title: "Completed status",
        workspaceRoot: root,
        workflowId: "orchestrator-basic",
        debugMode: true,
        graph: {
          sessionId: "sess_completed_status",
          workflowId: "orchestrator-basic",
          nodes: [
            { id: "orchestrator", roleId: "orchestrator", label: "Orchestrator", status: "idle", color: "#4f7cff", unreadCount: 0, errorCount: 0 }
          ],
          edges: [],
          activeToolCalls: []
        }
      });
      await store.append({
        eventId: makeEventId(),
        sessionId: "sess_completed_status",
        agentId: "orchestrator",
        timestamp: "2026-01-01T00:00:01.000Z",
        type: "agent.status",
        payload: { status: "completed" }
      });
      await store.createSession({
        sessionId: "sess_active_status",
        title: "Active status",
        workspaceRoot: root,
        workflowId: "orchestrator-basic",
        debugMode: true,
        graph: {
          sessionId: "sess_active_status",
          workflowId: "orchestrator-basic",
          nodes: [
            { id: "orchestrator", roleId: "orchestrator", label: "Orchestrator", status: "idle", color: "#4f7cff", unreadCount: 0, errorCount: 0 }
          ],
          edges: [],
          activeToolCalls: []
        }
      });
      await store.append({
        eventId: makeEventId(),
        sessionId: "sess_active_status",
        agentId: "orchestrator",
        timestamp: "2026-01-01T00:00:02.000Z",
        type: "agent.status",
        payload: { status: "waiting" }
      });

      const sessions = await store.listSessions();
      expect(sessions.find((session) => session.id === "sess_completed_status")).toMatchObject({
        status: "completed",
        activeAgents: 0
      });
      expect(sessions.find((session) => session.id === "sess_active_status")).toMatchObject({
        status: "active",
        activeAgents: 1
      });
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("does not mark sessions terminal just because a child workflow stopped", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-events-"));
    try {
      const store = new EventStore(root);
      await store.createSession({
        sessionId: "sess_stopped_status",
        title: "Stopped status",
        workspaceRoot: root,
        workflowId: "orchestrator-basic",
        debugMode: true,
        graph: {
          sessionId: "sess_stopped_status",
          workflowId: "orchestrator-basic",
          nodes: [
            { id: "orchestrator", roleId: "orchestrator", label: "Orchestrator", status: "idle", color: "#4f7cff", unreadCount: 0, errorCount: 0 },
            { id: "implementor", roleId: "implementor", label: "Implementor", status: "idle", color: "#34c759", unreadCount: 0, errorCount: 0 }
          ],
          edges: [],
          activeToolCalls: []
        }
      });
      await store.append({
        eventId: makeEventId(),
        sessionId: "sess_stopped_status",
        agentId: "implementor",
        timestamp: "2026-01-01T00:00:01.000Z",
        type: "agent.status",
        payload: { status: "completed" }
      });
      await store.append({
        eventId: makeEventId(),
        sessionId: "sess_stopped_status",
        agentId: "orchestrator",
        timestamp: "2026-01-01T00:00:02.000Z",
        type: "workflow.stopped",
        payload: { workflowInstanceId: "wf_stopped", workflowId: "implementor-reviewer" }
      });

      expect((await store.listSessions()).find((session) => session.id === "sess_stopped_status")).toMatchObject({
        status: "idle"
      });
      await store.append({
        eventId: makeEventId(),
        sessionId: "sess_stopped_status",
        agentId: "orchestrator",
        timestamp: "2026-01-01T00:00:03.000Z",
        type: "agent.status",
        payload: { status: "completed" }
      });

      expect((await store.listSessions()).find((session) => session.id === "sess_stopped_status")).toMatchObject({
        status: "completed"
      });
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("does not mark sessions completed just because a child workflow completed", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-events-"));
    try {
      const store = new EventStore(root);
      await store.createSession({
        sessionId: "sess_child_completed",
        title: "Child completed",
        workspaceRoot: root,
        workflowId: "orchestrator-basic",
        debugMode: true,
        graph: {
          sessionId: "sess_child_completed",
          workflowId: "orchestrator-basic",
          nodes: [
            { id: "orchestrator", roleId: "orchestrator", label: "Orchestrator", status: "idle", color: "#4f7cff", unreadCount: 0, errorCount: 0 },
            { id: "qaer", roleId: "qaer", label: "QAer", status: "idle", color: "#ff9500", unreadCount: 0, errorCount: 0 }
          ],
          edges: [],
          activeToolCalls: []
        }
      });
      await store.append({
        eventId: makeEventId(),
        sessionId: "sess_child_completed",
        agentId: "qaer",
        timestamp: "2026-01-01T00:00:01.000Z",
        type: "agent.status",
        payload: { status: "completed" }
      });
      await store.append({
        eventId: makeEventId(),
        sessionId: "sess_child_completed",
        agentId: "orchestrator",
        timestamp: "2026-01-01T00:00:02.000Z",
        type: "workflow.completed",
        payload: { workflowInstanceId: "wf_child", workflowId: "implementor-qa-loop" }
      });

      expect((await store.listSessions()).find((session) => session.id === "sess_child_completed")).toMatchObject({
        status: "idle"
      });
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });
});
