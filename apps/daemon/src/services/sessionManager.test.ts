import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { SessionManager } from "./sessionManager.js";

describe("SessionManager deterministic debug sessions", () => {
  it("creates a replayable multiagent debug session", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-session-"));
    try {
      const events: string[] = [];
      const manager = new SessionManager({ sessionsRoot: root });
      manager.setPublisher((event) => events.push(event.type));

      const snapshot = await manager.handle({
        id: "req_create",
        method: "createSession",
        params: {
          prompt: "Review and QA this implementation",
          workspaceRoot: root,
          workflowId: "implementor-reviewer",
          debugMode: true
        }
      });

      expect(JSON.stringify(snapshot)).toContain("implementor-reviewer");
      expect(events).toContain("agent.tool_call");
      expect(events).toContain("workspace.file_touched");
      expect(events).toContain("message.sent");

      const replay = await manager.handle({
        id: "req_sub",
        method: "subscribeEvents",
        params: { sessionId: (snapshot as { sessionId: string }).sessionId }
      }) as { events: Array<{ type: string; payload: Record<string, unknown>; agentId?: string }> };
      const handoffs = replay.events.filter((event) => event.type === "handoff.created" && event.payload.from === "orchestrator" && event.payload.to === "implementor");
      expect(handoffs).toHaveLength(1);
      expect(replay.events.some((event) => event.type === "message.sent" && event.payload.from === "implementor" && event.payload.to === "reviewer")).toBe(true);
      expect(replay.events.some((event) => event.type === "agent.status" && event.agentId === "reviewer" && event.payload.status === "waiting")).toBe(true);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("preserves non-debug runtime mode for follow-up messages", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-session-"));
    try {
      const manager = new SessionManager({
        sessionsRoot: root,
        runtime: {
          async runTurn(input) {
            return [{
              eventId: `evt_${crypto.randomUUID()}`,
              sessionId: input.sessionId,
              agentId: input.agentId,
              timestamp: new Date().toISOString(),
              type: "agent.message",
              payload: { debugMode: input.debugMode }
            }];
          }
        }
      });
      const snapshot = await manager.handle({
        id: "req_create",
        method: "createSession",
        params: {
          prompt: "real mode",
          workspaceRoot: root,
          workflowId: "planner-orchestrator",
          debugMode: false
        }
      }) as { sessionId: string };
      await manager.handle({
        id: "req_msg",
        method: "sendMessage",
        params: {
          sessionId: snapshot.sessionId,
          text: "continue"
        }
      });
      const events = JSON.stringify(await manager.handle({
        id: "req_sub",
        method: "subscribeEvents",
        params: { sessionId: snapshot.sessionId }
      }));
      expect(events).toContain("\"debugMode\":false");
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("rejects path-traversal session ids before writing control events", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-session-"));
    try {
      const manager = new SessionManager({ sessionsRoot: root });
      await expect(manager.handle({
        id: "req_pause",
        method: "pauseAgent",
        params: { sessionId: "../escape", agentId: "orchestrator" }
      })).rejects.toThrow();
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("routes targeted messages to the requested agent", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-session-"));
    try {
      const manager = new SessionManager({ sessionsRoot: root });
      const snapshot = await manager.handle({
        id: "req_create",
        method: "createSession",
        params: {
          prompt: "debug review",
          workspaceRoot: root,
          workflowId: "implementor-reviewer",
          debugMode: true
        }
      }) as { sessionId: string };
      await manager.handle({
        id: "req_target",
        method: "sendMessage",
        params: {
          sessionId: snapshot.sessionId,
          targetAgentId: "reviewer",
          text: "review this"
        }
      });
      const replay = await manager.handle({
        id: "req_sub",
        method: "subscribeEvents",
        params: { sessionId: snapshot.sessionId }
      }) as { events: Array<{ type: string; agentId?: string; payload: Record<string, unknown> }> };
      expect(replay.events.some((event) => event.type === "message.sent" && event.agentId === "reviewer" && event.payload.to === "reviewer")).toBe(true);
      expect(replay.events.some((event) => event.type === "agent.message" && event.agentId === "reviewer")).toBe(true);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("continues handoff workflows into downstream QA agents", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-session-"));
    try {
      const manager = new SessionManager({ sessionsRoot: root });
      const snapshot = await manager.handle({
        id: "req_create_qa",
        method: "createSession",
        params: {
          prompt: "Implement and run QA acceptance",
          workspaceRoot: root,
          workflowId: "implementor-qa-loop",
          debugMode: true
        }
      }) as { sessionId: string };
      const replay = await manager.handle({
        id: "req_sub_qa",
        method: "subscribeEvents",
        params: { sessionId: snapshot.sessionId }
      }) as { events: Array<{ type: string; agentId?: string; payload: Record<string, unknown> }> };

      expect(replay.events.some((event) => event.type === "handoff.created" && event.payload.from === "implementor" && event.payload.to === "qa")).toBe(true);
      expect(replay.events.some((event) => event.type === "agent.message" && event.agentId === "qa")).toBe(true);
      expect(replay.events.some((event) => event.type === "message.sent" && event.payload.from === "qa" && event.payload.to === "implementor")).toBe(true);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });
});
