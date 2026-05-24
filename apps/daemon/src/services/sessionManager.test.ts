import { mkdtemp, readFile, rm } from "node:fs/promises";
import { existsSync } from "node:fs";
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
      expect((snapshot as { workspaceRoot: string }).workspaceRoot).toBe(path.join(root, (snapshot as { sessionId: string }).sessionId, "workspace"));
      expect((snapshot as { workspaceRoot: string }).workspaceRoot.endsWith(`${path.sep}workspace`)).toBe(true);
      expect(existsSync((snapshot as { workspaceRoot: string }).workspaceRoot)).toBe(true);
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

  it("lists predefined roles and workflows through the daemon protocol", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-session-"));
    try {
      const manager = new SessionManager({ sessionsRoot: root });
      const result = await manager.handle({
        id: "req_list",
        method: "listSessions",
        params: {}
      }) as { roles: Array<{ name: string; toolPolicy: { canWrite: boolean; canRunCommands: boolean; canCreatePlans: boolean } }>; workflows: Array<{ id: string }> };

      expect(result.roles.map((role) => role.name)).toEqual(expect.arrayContaining([
        "QAer",
        "Adversarial Reviewer",
        "Implementor",
        "Planner",
        "Researcher"
      ]));
      const orchestrator = result.roles.find((role) => role.name === "Orchestrator");
      const planner = result.roles.find((role) => role.name === "Planner");
      expect(orchestrator).toBeDefined();
      expect(planner).toBeDefined();
      expect(orchestrator!.toolPolicy).toMatchObject({ canWrite: false, canRunCommands: false, canCreatePlans: false });
      expect(planner!.toolPolicy).toMatchObject({ canWrite: false, canRunCommands: false, canCreatePlans: true });
      expect(result.workflows.map((workflow) => workflow.id)).toEqual(expect.arrayContaining([
        "implementor-qa-loop",
        "implementor-reviewer",
        "implementation-review-qa"
      ]));
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

  it("records runtime failures durably instead of leaving silent partial sessions", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-session-"));
    try {
      const manager = new SessionManager({
        sessionsRoot: root,
        runtime: {
          async runTurn() {
            throw new Error("model unavailable");
          }
        }
      });
      const snapshot = await manager.handle({
        id: "req_create_failure",
        method: "createSession",
        params: {
          prompt: "live failure",
          workspaceRoot: root,
          workflowId: "planner-orchestrator",
          debugMode: false
        }
      }) as { sessionId: string };
      const replay = await manager.handle({
        id: "req_sub_failure",
        method: "subscribeEvents",
        params: { sessionId: snapshot.sessionId }
      }) as { events: Array<{ type: string; agentId?: string; payload: Record<string, unknown> }> };

      expect(replay.events.some((event) => event.type === "error" && event.payload.message === "model unavailable")).toBe(true);
      expect(replay.events.some((event) => event.type === "agent.status" && event.agentId === "orchestrator" && event.payload.status === "failed")).toBe(true);
      const logs = await manager.handle({
        id: "req_sub_logs_failure",
        method: "subscribeDebugLogs",
        params: { sessionId: snapshot.sessionId }
      }) as { logs: Array<{ level: string; message: string }> };
      expect(logs.logs.some((entry) => entry.level === "error" && entry.message === "model unavailable")).toBe(true);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("creates a planner-owned plan and produces a working temperature converter", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-session-"));
    try {
      const manager = new SessionManager({ sessionsRoot: root });
      const snapshot = await manager.handle({
        id: "req_temperature_converter",
        method: "createSession",
        params: {
          prompt: "Build a Python CLI that converts temperatures between Celsius and Fahrenheit and include tests",
          workspaceRoot: root,
          workflowId: "planner-orchestrator",
          debugMode: true
        }
      }) as { sessionId: string; workspaceRoot: string };

      const program = await readFile(path.join(snapshot.workspaceRoot, "temperature_converter.py"), "utf8");
      expect(program).toContain("def celsius_to_fahrenheit");
      expect(program).toContain("argparse");

      const replay = await manager.handle({
        id: "req_sub_temperature",
        method: "subscribeEvents",
        params: { sessionId: snapshot.sessionId }
      }) as { events: Array<{ type: string; agentId?: string; payload: Record<string, unknown> }> };
      expect(replay.events.some((event) => event.type === "plan.created" && event.agentId === "planner")).toBe(true);
      expect(replay.events.some((event) => event.type === "plan.instantiated" && event.agentId === "orchestrator")).toBe(true);
      expect(replay.events.some((event) => event.type === "workspace.file_touched" && event.agentId?.includes("implementor") && String(event.payload.path).endsWith("temperature_converter.py"))).toBe(true);
      expect(replay.events.some((event) => event.type === "agent.tool_result" && event.agentId?.includes("qa") && String(event.payload.output).includes("OK"))).toBe(true);
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

  it("instantiates a workflow into an existing session graph", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-session-"));
    try {
      const manager = new SessionManager({ sessionsRoot: root });
      const snapshot = await manager.handle({
        id: "req_create_base",
        method: "createSession",
        params: {
          prompt: "plan only",
          workflowId: "planner-orchestrator",
          debugMode: true
        }
      }) as { sessionId: string; graph: { nodes: unknown[]; edges: unknown[] } };
      const expanded = await manager.handle({
        id: "req_instantiate",
        method: "instantiateWorkflow",
        params: { sessionId: snapshot.sessionId, workflowId: "implementor-reviewer" }
      }) as { graph: { nodes: Array<{ id: string }>; edges: unknown[] } };

      expect(expanded.graph.nodes.length).toBeGreaterThan(snapshot.graph.nodes.length);
      expect(expanded.graph.nodes.some((node) => node.id.includes("implementor"))).toBe(true);
      const replay = await manager.handle({
        id: "req_sub_expanded",
        method: "subscribeEvents",
        params: { sessionId: snapshot.sessionId }
      }) as { events: Array<{ type: string }> };
      expect(replay.events.some((event) => event.type === "workflow.instantiated")).toBe(true);
      expect(replay.events.some((event) => event.type === "graph.updated")).toBe(true);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("does not schedule downstream workflow work from a failed agent", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-session-"));
    try {
      const manager = new SessionManager({
        sessionsRoot: root,
        runtime: {
          async runTurn(input) {
            if (input.agentId === "implementor") {
              throw new Error("implementation failed");
            }
            return [{
              eventId: `evt_${crypto.randomUUID()}`,
              sessionId: input.sessionId,
              agentId: input.agentId,
              timestamp: new Date().toISOString(),
              type: "agent.message",
              payload: { text: "ok" }
            }];
          }
        }
      });
      const snapshot = await manager.handle({
        id: "req_failed_workflow",
        method: "createSession",
        params: {
          prompt: "Implement and run QA acceptance",
          workspaceRoot: root,
          workflowId: "implementor-qa-loop",
          debugMode: true
        }
      }) as { sessionId: string };
      const replay = await manager.handle({
        id: "req_sub_failed_workflow",
        method: "subscribeEvents",
        params: { sessionId: snapshot.sessionId }
      }) as { events: Array<{ type: string; agentId?: string; payload: Record<string, unknown> }> };

      expect(replay.events.some((event) => event.type === "error" && event.agentId === "implementor")).toBe(true);
      expect(replay.events.some((event) => event.type === "handoff.created" && event.payload.from === "implementor" && event.payload.to === "qa")).toBe(false);
      expect(replay.events.some((event) => event.type === "agent.message" && event.agentId === "qa")).toBe(false);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });
});
