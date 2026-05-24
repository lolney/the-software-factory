import { appendFile, mkdtemp, rm } from "node:fs/promises";
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
});
