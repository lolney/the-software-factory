import { mkdtemp, readFile, rm } from "node:fs/promises";
import { existsSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { SessionManager } from "./sessionManager.js";
import { EventStore, makeEventId } from "./eventStore.js";

type ReplayEvent = { type: string; agentId?: string; payload: Record<string, unknown> };

async function waitForEvents(manager: SessionManager, sessionId: string, predicate: (events: ReplayEvent[]) => boolean, timeoutMs = 3_000) {
  const deadline = Date.now() + timeoutMs;
  let events: ReplayEvent[] = [];
  while (Date.now() < deadline) {
    const replay = await manager.handle({
      id: `req_wait_${crypto.randomUUID()}`,
      method: "subscribeEvents",
      params: { sessionId }
    }) as { events: ReplayEvent[] };
    events = replay.events;
    if (predicate(events)) return events;
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  throw new Error(`Timed out waiting for session events. Last events: ${events.slice(-5).map((event) => event.type).join(", ")}`);
}

async function waitForSchedulerIdle(manager: SessionManager, sessionId: string) {
  const deadline = Date.now() + 3_000;
  let stableSamples = 0;
  let events: ReplayEvent[] = [];
  while (Date.now() < deadline) {
    const replay = await manager.handle({
      id: `req_wait_idle_${crypto.randomUUID()}`,
      method: "subscribeEvents",
      params: { sessionId }
    }) as { events: ReplayEvent[] };
    events = replay.events;
    const terminal = new Set(events
      .filter((event) => ["scheduler.job.completed", "scheduler.job.failed", "scheduler.job.recovered"].includes(event.type))
      .map((event) => String(event.payload.jobId ?? ""))
      .filter(Boolean));
    const idle = events
      .filter((event) => event.type === "scheduler.job.created")
      .every((event) => terminal.has(String(event.payload.jobId ?? "")));
    stableSamples = idle ? stableSamples + 1 : 0;
    if (stableSamples >= 6) return events;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(`Timed out waiting for scheduler idle. Last events: ${events.slice(-5).map((event) => event.type).join(", ")}`);
}

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
      await rm(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
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
      await rm(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
    }
  });

  it("archives and restores sessions without deleting their durable logs", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-session-"));
    try {
      const manager = new SessionManager({ sessionsRoot: root });
      const snapshot = await manager.handle({
        id: "req_create_archivable",
        method: "createSession",
        params: {
          prompt: "archive me",
          workspaceRoot: root,
          workflowId: "planner-orchestrator",
          debugMode: true
        }
      }) as { sessionId: string };
      await waitForSchedulerIdle(manager, snapshot.sessionId);

      await manager.handle({
        id: "req_archive",
        method: "archiveSessions",
        params: { sessionIds: [snapshot.sessionId], archived: true }
      });

      const visible = await manager.handle({
        id: "req_list_visible",
        method: "listSessions",
        params: {}
      }) as { sessions: Array<{ id: string; archived?: boolean }> };
      expect(visible.sessions.some((session) => session.id === snapshot.sessionId)).toBe(false);

      const all = await manager.handle({
        id: "req_list_all",
        method: "listSessions",
        params: { includeArchived: true }
      }) as { sessions: Array<{ id: string; archived?: boolean }> };
      expect(all.sessions.find((session) => session.id === snapshot.sessionId)?.archived).toBe(true);
      expect(existsSync(path.join(root, snapshot.sessionId, "events.jsonl"))).toBe(true);

      await manager.handle({
        id: "req_restore",
        method: "archiveSessions",
        params: { sessionIds: [snapshot.sessionId], archived: false }
      });
      const restored = await manager.handle({
        id: "req_list_restored",
        method: "listSessions",
        params: {}
      }) as { sessions: Array<{ id: string; archived?: boolean }> };
      expect(restored.sessions.find((session) => session.id === snapshot.sessionId)?.archived).toBe(false);
    } finally {
      await rm(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
    }
  });

  it("blocks mutable operations on archived sessions", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-session-"));
    try {
      const manager = new SessionManager({ sessionsRoot: root });
      const snapshot = await manager.handle({
        id: "req_create_archived_readonly",
        method: "createSession",
        params: {
          prompt: "archive readonly",
          workspaceRoot: root,
          workflowId: "planner-orchestrator",
          debugMode: true
        }
      }) as { sessionId: string };
      await waitForSchedulerIdle(manager, snapshot.sessionId);
      await manager.handle({
        id: "req_archive_readonly",
        method: "archiveSessions",
        params: { sessionIds: [snapshot.sessionId], archived: true }
      });

      await expect(manager.handle({
        id: "req_archived_message",
        method: "sendMessage",
        params: { sessionId: snapshot.sessionId, text: "should be blocked" }
      })).rejects.toThrow(/archived/i);
      await expect(manager.handle({
        id: "req_archived_workflow",
        method: "instantiateWorkflow",
        params: { sessionId: snapshot.sessionId, workflowId: "implementor-reviewer" }
      })).rejects.toThrow(/archived/i);
    } finally {
      await rm(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
    }
  });

  it("creates personal role and workflow JSON files through the daemon protocol", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-session-"));
    try {
      const manager = new SessionManager({ sessionsRoot: root });
      const roleResult = await manager.handle({
        id: "req_create_role_file",
        method: "createRoleFile",
        params: {}
      }) as { path: string; roles: Array<{ id: string; name: string }>; personalRolesPath: string };
      const workflowResult = await manager.handle({
        id: "req_create_workflow_file",
        method: "createWorkflowFile",
        params: {}
      }) as { path: string; workflows: Array<{ id: string; name: string }>; personalWorkflowsPath: string };

      expect(roleResult.personalRolesPath).toBe(path.join(root, "config", "roles"));
      expect(workflowResult.personalWorkflowsPath).toBe(path.join(root, "config", "workflows"));
      expect(roleResult.path.startsWith(roleResult.personalRolesPath)).toBe(true);
      expect(workflowResult.path.startsWith(workflowResult.personalWorkflowsPath)).toBe(true);
      expect(roleResult.roles.some((role) => role.name === "")).toBe(true);
      expect(workflowResult.workflows.some((workflow) => workflow.name === "")).toBe(true);
    } finally {
      await rm(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
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
      await rm(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
    }
  });

  it("exposes a live write_file tool that records durable diffs", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-session-"));
    try {
      const manager = new SessionManager({
        sessionsRoot: root,
        runtime: {
          async runTurn(input) {
            if (input.agentId === "implementor") {
              await input.workflowTools?.writeWorkspaceFile?.("hello.py", "print('hello from live tool')\n");
            }
            return [{
              eventId: `evt_${crypto.randomUUID()}`,
              sessionId: input.sessionId,
              agentId: input.agentId,
              timestamp: new Date().toISOString(),
              type: "agent.message",
              payload: { text: "done" }
            }];
          }
        }
      });
      const snapshot = await manager.handle({
        id: "req_live_write",
        method: "createSession",
        params: {
          prompt: "write a hello script",
          workspaceRoot: root,
          workflowId: "implementor-reviewer",
          debugMode: false
        }
      }) as { sessionId: string };
      const replay = await manager.handle({
        id: "req_live_write_replay",
        method: "subscribeEvents",
        params: { sessionId: snapshot.sessionId }
      }) as { events: Array<{ type: string; agentId?: string; payload: Record<string, unknown> }> };

      expect(replay.events.some((event) => event.type === "agent.tool_call" && event.agentId === "implementor" && event.payload.toolName === "workspace.write_file")).toBe(true);
      expect(replay.events.some((event) => event.type === "capability.checked" && event.agentId === "implementor" && event.payload.action === "workspace.write" && event.payload.allowed === true)).toBe(true);
      expect(replay.events.some((event) => event.type === "agent.tool_result" && event.agentId === "implementor" && String(event.payload.diff).includes("+++ b/hello.py"))).toBe(true);
      expect(replay.events.some((event) => event.type === "workspace.file_touched" && event.agentId === "implementor" && String(event.payload.diff).includes("print('hello from live tool')"))).toBe(true);
      const claimIndex = replay.events.findIndex((event) => event.type === "workspace.file_claimed" && event.agentId === "implementor");
      const touchedIndex = replay.events.findIndex((event) => event.type === "workspace.file_touched" && event.agentId === "implementor");
      expect(claimIndex).toBeGreaterThan(-1);
      expect(touchedIndex).toBeGreaterThan(claimIndex);
    } finally {
      await rm(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
    }
  });

  it("blocks cross-agent workspace writes before mutating leased files", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-session-"));
    try {
      const manager = new SessionManager({
        sessionsRoot: root,
        runtime: { async runTurn() { return []; } }
      });
      const created = await manager.handle({
        id: "req_workspace_conflict",
        method: "createSession",
        params: {
          prompt: "workspace conflict",
          workspaceRoot: root,
          workflowId: "planner-orchestrator",
          debugMode: false
        }
      }) as { sessionId: string };
      const snapshot = await manager.handle({
        id: "req_workspace_conflict_snapshot",
        method: "getSnapshot",
        params: { sessionId: created.sessionId }
      }) as { sessionId: string; workspaceRoot: string; graph: { nodes: Array<Record<string, unknown>> } };
      snapshot.graph.nodes.push({
        id: "implementor",
        roleId: "implementor",
        label: "Implementor",
        color: "#1f9d55",
        status: "idle",
        unreadCount: 0,
        errorCount: 0
      });
      snapshot.graph.nodes.push({
        id: "second_implementor",
        roleId: "implementor",
        label: "Second Implementor",
        color: "#4f7cff",
        status: "idle",
        unreadCount: 0,
        errorCount: 0
      });

      await (manager as unknown as {
        writeWorkspaceFile: (snapshot: unknown, agentId: string, relativePath: string, content: string, causationId: string | undefined, publish: (event: unknown) => void) => Promise<string>;
      }).writeWorkspaceFile(snapshot, "implementor", "shared.txt", "owned\n", undefined, () => {});
      const blocked = await (manager as unknown as {
        writeWorkspaceFile: (snapshot: unknown, agentId: string, relativePath: string, content: string, causationId: string | undefined, publish: (event: unknown) => void) => Promise<string>;
      }).writeWorkspaceFile(snapshot, "second_implementor", "shared.txt", "overwritten\n", undefined, () => {});

      expect(blocked).toContain("Blocked write");
      expect(await readFile(path.join(snapshot.workspaceRoot, "shared.txt"), "utf8")).toBe("owned\n");
      const replay = await manager.handle({
        id: "req_workspace_conflict_replay",
        method: "subscribeEvents",
        params: { sessionId: snapshot.sessionId }
      }) as { events: Array<{ type: string; agentId?: string; payload: Record<string, unknown> }> };
      expect(replay.events.some((event) => event.type === "workspace.conflict_detected" && event.agentId === "second_implementor")).toBe(true);
      expect(replay.events.some((event) => event.type === "agent.tool_result" && event.agentId === "second_implementor" && event.payload.blocked === true)).toBe(true);
    } finally {
      await rm(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
    }
  });

  it("rolls back command writes that conflict with another agent lease", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-session-"));
    try {
      const manager = new SessionManager({
        sessionsRoot: root,
        runtime: { async runTurn() { return []; } }
      });
      const created = await manager.handle({
        id: "req_command_conflict",
        method: "createSession",
        params: {
          prompt: "command conflict",
          workspaceRoot: root,
          workflowId: "planner-orchestrator",
          debugMode: false
        }
      }) as { sessionId: string };
      const snapshot = await manager.handle({
        id: "req_command_conflict_snapshot",
        method: "getSnapshot",
        params: { sessionId: created.sessionId }
      }) as { sessionId: string; workspaceRoot: string; graph: { nodes: Array<Record<string, unknown>> } };
      snapshot.graph.nodes.push({
        id: "implementor",
        roleId: "implementor",
        label: "Implementor",
        color: "#1f9d55",
        status: "idle",
        unreadCount: 0,
        errorCount: 0
      });
      snapshot.graph.nodes.push({
        id: "second_implementor",
        roleId: "implementor",
        label: "Second Implementor",
        color: "#4f7cff",
        status: "idle",
        unreadCount: 0,
        errorCount: 0
      });

      await (manager as unknown as {
        writeWorkspaceFile: (snapshot: unknown, agentId: string, relativePath: string, content: string, causationId: string | undefined, publish: (event: unknown) => void) => Promise<string>;
      }).writeWorkspaceFile(snapshot, "implementor", "shared.txt", "owned\n", undefined, () => {});
      const output = await (manager as unknown as {
        runWorkspaceCommand: (snapshot: unknown, agentId: string, command: string, args: string[], cwd: string | undefined, publish: (event: unknown) => void) => Promise<string>;
      }).runWorkspaceCommand(snapshot, "second_implementor", process.execPath, ["-e", "require('fs').writeFileSync('shared.txt', 'bad\\n')"], undefined, () => {});

      expect(output).toContain("workspace changes rolled back");
      expect(await readFile(path.join(snapshot.workspaceRoot, "shared.txt"), "utf8")).toBe("owned\n");
    } finally {
      await rm(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
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
      await rm(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
    }
  });

  it("records scheduler jobs and recovers interrupted runs on daemon restart", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-session-"));
    try {
      const manager = new SessionManager({ sessionsRoot: root });
      const snapshot = await manager.handle({
        id: "req_scheduler_session",
        method: "createSession",
        params: {
          prompt: "scheduler recovery",
          workspaceRoot: root,
          workflowId: "planner-orchestrator",
          debugMode: true
        }
      }) as { sessionId: string };
      const firstReplay = await manager.handle({
        id: "req_scheduler_replay",
        method: "subscribeEvents",
        params: { sessionId: snapshot.sessionId }
      }) as { events: Array<{ type: string; payload: Record<string, unknown> }> };
      expect(firstReplay.events.some((event) => event.type === "scheduler.job.created")).toBe(true);
      expect(firstReplay.events.some((event) => event.type === "scheduler.job.completed")).toBe(true);
      const firstRuntimeOutputIndex = firstReplay.events.findIndex((event) => event.type === "agent.message");
      const firstTerminalJobIndex = firstReplay.events.findIndex((event) => event.type === "scheduler.job.completed");
      expect(firstTerminalJobIndex).toBeGreaterThan(firstRuntimeOutputIndex);

      const store = new EventStore(root);
      const openJobId = `job_${crypto.randomUUID()}`;
      await store.append({
        eventId: makeEventId(),
        sessionId: snapshot.sessionId,
        agentId: "orchestrator",
        timestamp: new Date().toISOString(),
        type: "scheduler.job.started",
        payload: { jobId: openJobId, kind: "agent-turn", agentId: "orchestrator" },
        correlationId: openJobId
      });
      await store.append({
        eventId: makeEventId(),
        sessionId: snapshot.sessionId,
        agentId: "orchestrator",
        timestamp: new Date().toISOString(),
        type: "agent.tool_call",
        payload: { callId: "call_interrupted", toolName: "workspace_read_file" },
        correlationId: openJobId
      });

      const restarted = new SessionManager({ sessionsRoot: root });
      await restarted.handle({
        id: "req_recover",
        method: "listSessions",
        params: { includeArchived: true }
      });
      const replay = await restarted.handle({
        id: "req_recovered_replay",
        method: "subscribeEvents",
        params: { sessionId: snapshot.sessionId }
      }) as { events: Array<{ type: string; agentId?: string; payload: Record<string, unknown> }> };
      expect(replay.events.some((event) => event.type === "scheduler.job.recovered" && event.payload.jobId === openJobId)).toBe(true);
      expect(replay.events.some((event) => event.type === "error" && event.payload.jobId === openJobId)).toBe(true);
      expect(replay.events.some((event) => event.type === "agent.status" && event.agentId === "orchestrator" && event.payload.status === "failed" && event.payload.jobId === openJobId)).toBe(true);
      const recoveredSnapshot = await restarted.handle({
        id: "req_recovered_snapshot",
        method: "getSnapshot",
        params: { sessionId: snapshot.sessionId }
      }) as { graph: { activeToolCalls: unknown[] } };
      expect(recoveredSnapshot.graph.activeToolCalls).toEqual([]);
      await waitForSchedulerIdle(restarted, snapshot.sessionId);
    } finally {
      await rm(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
    }
  });

  it("recovers interrupted workflow execution jobs by rescheduling the workflow", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-session-"));
    try {
      const manager = new SessionManager({ sessionsRoot: root });
      const snapshot = await manager.handle({
        id: "req_workflow_recovery_session",
        method: "createSession",
        params: {
          prompt: "workflow recovery",
          workspaceRoot: root,
          workflowId: "implementor-reviewer",
          debugMode: true
        }
      }) as { sessionId: string };
      const expanded = await manager.handle({
        id: "req_workflow_recovery_instantiate",
        method: "instantiateWorkflow",
        params: { sessionId: snapshot.sessionId, workflowId: "implementor-reviewer" }
      }) as { graph: { nodes: Array<{ id: string }> } };
      expect(expanded.graph.nodes.some((node) => node.id.includes("implementor"))).toBe(true);
      const replay = await manager.handle({
        id: "req_workflow_recovery_replay",
        method: "subscribeEvents",
        params: { sessionId: snapshot.sessionId }
      }) as { events: ReplayEvent[] };
      const instantiated = [...replay.events].reverse().find((event) => event.type === "workflow.instantiated" && event.payload.workflowId === "implementor-reviewer");
      const workflowInstanceId = String(instantiated?.payload.workflowInstanceId ?? "");
      expect(workflowInstanceId).toMatch(/^wf_/);

      const store = new EventStore(root);
      const openJobId = `job_${crypto.randomUUID()}`;
      await store.append({
        eventId: makeEventId(),
        sessionId: snapshot.sessionId,
        agentId: workflowInstanceId,
        timestamp: new Date().toISOString(),
        type: "scheduler.job.created",
        payload: {
          jobId: openJobId,
          kind: "workflow-execution",
          agentId: workflowInstanceId,
          workflowInstanceId,
          workflowId: "implementor-reviewer",
          callerAgentId: "orchestrator",
          prompt: "resume workflow",
          details: {
            planWorkflow: { workflowId: "implementor-reviewer", agentPrompts: {}, doneCriteria: {}, completionCriteria: {} }
          }
        },
        correlationId: openJobId
      });

      const restarted = new SessionManager({ sessionsRoot: root });
      await restarted.handle({
        id: "req_recover_workflow",
        method: "listSessions",
        params: { includeArchived: true }
      });
      const recoveredEvents = await waitForSchedulerIdle(restarted, snapshot.sessionId);
      expect(recoveredEvents.some((event) => event.type === "scheduler.job.recovered" && event.payload.jobId === openJobId)).toBe(true);
      expect(recoveredEvents.some((event) => event.type === "scheduler.job.created" && event.payload.kind === "workflow-execution" && event.payload.jobId !== openJobId)).toBe(true);
    } finally {
      await rm(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
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
      await waitForEvents(manager, snapshot.sessionId, (events) =>
        events.some((event) => event.type === "workflow.completed" && event.payload.workflowId === "implementation-review-qa")
      );

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
      expect(replay.events.some((event) => event.type === "agent.tool_call" && event.agentId === "planner" && String(JSON.stringify(event.payload)).includes("Build a Python CLI that converts temperatures"))).toBe(true);
      expect(replay.events.some((event) => event.type === "workspace.file_touched" && event.agentId?.includes("implementor") && String(event.payload.path).endsWith("temperature_converter.py"))).toBe(true);
      expect(replay.events.some((event) => event.type === "workspace.file_touched" && event.agentId?.includes("implementor") && String(event.payload.diff).includes("+++ b/temperature_converter.py"))).toBe(true);
      expect(replay.events.some((event) => event.type === "agent.tool_result" && event.agentId?.includes("implementor") && String(event.payload.diff).includes("def celsius_to_fahrenheit"))).toBe(true);
      expect(replay.events.some((event) => event.type === "agent.tool_result" && event.agentId?.includes("qa") && String(event.payload.output).includes("OK"))).toBe(true);
      expect(replay.events.some((event) => event.type === "agent.stop_blocked" && event.agentId?.includes("implementor"))).toBe(true);
      const blockedImplementorIndex = replay.events.findIndex((event) => event.type === "agent.stop_blocked" && event.agentId?.includes("implementor"));
      const completedImplementorCriterionIndex = replay.events.findIndex((event) => event.type === "completion.criterion.updated" && event.agentId?.includes("implementor") && event.payload.status === "completed");
      expect(completedImplementorCriterionIndex).toBeGreaterThan(blockedImplementorIndex);
      expect(replay.events.some((event) => event.type === "agent.stopped" && event.agentId?.includes("qa") && event.payload.completedCriteria instanceof Array && event.payload.completedCriteria.includes("qa_acceptance"))).toBe(true);
      expect(replay.events.some((event) => event.type === "completion.criterion.updated" && event.payload.criterionId === "qa_acceptance" && event.payload.status === "completed")).toBe(true);
      expect(replay.events.some((event) => event.type === "workflow.completed" && String(event.payload.workflowId) === "implementation-review-qa")).toBe(true);
      expect(replay.events.some((event) => event.type === "workflow.completed" && event.payload.completedCriteria instanceof Array && event.payload.completedCriteria.includes("qa_acceptance"))).toBe(true);
      expect(replay.events.some((event) => event.type === "message.sent" && String(event.payload.text).includes("Workflow implementation-review-qa completed"))).toBe(true);
      await waitForSchedulerIdle(manager, snapshot.sessionId);
    } finally {
      await rm(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
    }
  });

  it("blocks agent stop when required completion criteria are missing", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-session-"));
    try {
      const manager = new SessionManager({
        sessionsRoot: root,
        runtime: {
          async runTurn(input) {
            if (input.agentId === "orchestrator") {
              await input.workflowTools?.startWorkflow?.("implementor-qa-loop");
            }
            if (input.agentId === "implementor" || input.agentId.endsWith("_implementor")) {
              await input.workflowTools?.stopSelf?.("done with another agent criterion", undefined, ["qa_acceptance"]);
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
        id: "req_missing_criteria",
        method: "createSession",
        params: {
          prompt: "Implement but omit completion criteria",
          workspaceRoot: root,
          workflowId: "planner-orchestrator",
          debugMode: false
        }
      }) as { sessionId: string };
      const replay = await manager.handle({
        id: "req_missing_criteria_replay",
        method: "subscribeEvents",
        params: { sessionId: snapshot.sessionId }
      }) as { events: Array<{ type: string; agentId?: string; payload: Record<string, unknown> }> };

      expect(replay.events.some((event) => event.type === "completion.criterion.updated" && event.payload.status === "pending" && event.payload.criterionId === "implementation_ready_for_qa")).toBe(true);
      expect(replay.events.some((event) => event.type === "agent.stop_blocked" && event.agentId?.endsWith("_implementor") && Array.isArray(event.payload.missingRequiredCriteria) && event.payload.missingRequiredCriteria.includes("implementation_ready_for_qa"))).toBe(true);
      expect(replay.events.some((event) => event.type === "agent.stop_blocked" && event.agentId?.endsWith("_implementor") && Array.isArray(event.payload.invalidCompletedCriteria) && event.payload.invalidCompletedCriteria.includes("qa_acceptance"))).toBe(true);
      expect(replay.events.some((event) => event.type === "completion.criterion.updated" && event.payload.status === "completed" && event.payload.criterionId === "qa_acceptance" && event.agentId?.endsWith("_implementor"))).toBe(false);
      expect(replay.events.some((event) => event.type === "agent.stopped" && event.agentId?.endsWith("_implementor"))).toBe(false);
      expect(replay.events.some((event) => event.type === "workflow.completed")).toBe(false);
      await waitForSchedulerIdle(manager, snapshot.sessionId);
    } finally {
      await rm(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
    }
  });

  it("does not create the demo plan automatically in non-debug sessions", async () => {
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
              payload: { text: `${input.agentId} responded without creating a plan` }
            }];
          }
        }
      });
      const snapshot = await manager.handle({
        id: "req_no_demo_plan",
        method: "createSession",
        params: {
          prompt: "live planner must use tool",
          workspaceRoot: root,
          workflowId: "planner-orchestrator",
          debugMode: false
        }
      }) as { sessionId: string };
      const replay = await manager.handle({
        id: "req_no_demo_plan_replay",
        method: "subscribeEvents",
        params: { sessionId: snapshot.sessionId }
      }) as { events: Array<{ type: string; agentId?: string; payload: Record<string, unknown> }> };

      expect(replay.events.some((event) => event.type === "plan.created")).toBe(false);
      expect(replay.events.some((event) => event.type === "plan.instantiated")).toBe(false);
    } finally {
      await rm(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
    }
  });

  it("accepts planner-created plans through the plan_create tool in non-debug sessions", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-session-"));
    try {
      const manager = new SessionManager({
        sessionsRoot: root,
        runtime: {
          async runTurn(input) {
            if (input.agentId === "planner") {
              await input.workflowTools?.createPlan?.({
                version: 1,
                id: "tool_created_plan",
                name: "Tool-created implementation plan",
                description: "Plan emitted by the planner through plan_create.",
                goal: "Build the requested project",
                workflows: [{
                  workflowId: "implementation-review-qa",
                  agentPrompts: {
                    implementor: "Implement the requested project.",
                    reviewer: "Review the implementation.",
                    qa: "Run acceptance checks."
                  },
                  doneCriteria: {
                    implementor: ["Implementation exists"],
                    reviewer: ["No blockers"],
                    qa: ["Checks pass"]
                  }
                }],
                globalDoneCriteria: ["Plan persisted through planner tool"]
              });
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
        id: "req_tool_plan",
        method: "createSession",
        params: {
          prompt: "live planner creates a plan",
          workspaceRoot: root,
          workflowId: "planner-orchestrator",
          debugMode: false
        }
      }) as { sessionId: string };
      await waitForSchedulerIdle(manager, snapshot.sessionId);
      const replay = await manager.handle({
        id: "req_tool_plan_replay",
        method: "subscribeEvents",
        params: { sessionId: snapshot.sessionId }
      }) as { events: Array<{ type: string; agentId?: string; payload: Record<string, unknown> }> };

      expect(replay.events.some((event) => event.type === "plan.created" && event.agentId === "planner" && event.payload.plan && (event.payload.plan as { id?: string }).id === "tool_created_plan")).toBe(true);
      expect(replay.events.some((event) => event.type === "capability.checked" && event.agentId === "planner" && event.payload.action === "plan.create" && event.payload.allowed === true)).toBe(true);
      expect(replay.events.some((event) => event.type === "plan.instantiated" && event.payload.planId === "tool_created_plan")).toBe(true);
    } finally {
      await rm(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
    }
  });

  it("exposes workflow stop tools and records manual workflow stops", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-session-"));
    try {
      const manager = new SessionManager({
        sessionsRoot: root,
        runtime: {
          async runTurn(input) {
            if (input.agentId === "orchestrator") {
              const started = await input.workflowTools?.startWorkflow?.("implementor-reviewer");
              const workflowInstanceId = started?.match(/(wf_[A-Za-z0-9_-]+)/)?.[1];
              if (workflowInstanceId) {
                await input.workflowTools?.stopWorkflow?.(workflowInstanceId, "caller cancelled early");
              }
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
        id: "req_manual_workflow_stop",
        method: "createSession",
        params: {
          prompt: "start and stop a child workflow",
          workspaceRoot: root,
          workflowId: "planner-orchestrator",
          debugMode: false
        }
      }) as { sessionId: string };
      await waitForSchedulerIdle(manager, snapshot.sessionId);
      const replay = await manager.handle({
        id: "req_manual_workflow_stop_replay",
        method: "subscribeEvents",
        params: { sessionId: snapshot.sessionId }
      }) as { events: Array<{ type: string; agentId?: string; payload: Record<string, unknown> }> };

      expect(replay.events.some((event) => event.type === "workflow.instantiated" && event.payload.workflowInstanceId)).toBe(true);
      expect(replay.events.some((event) => event.type === "workflow.stopped" && event.payload.reason === "caller cancelled early")).toBe(true);
    } finally {
      await rm(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
    }
  });

  it("schedules child workflow execution outside the caller model turn", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-session-"));
    let releaseImplementor: () => void = () => {};
    const implementorGate = new Promise<void>((resolve) => {
      releaseImplementor = resolve;
    });
    let implementorRuns = 0;
    let manager: SessionManager | undefined;
    let sessionId: string | undefined;
    try {
      manager = new SessionManager({
        sessionsRoot: root,
        runtime: {
          async runTurn(input) {
            if (input.agentId === "orchestrator") {
              const started = await input.workflowTools?.startWorkflow?.("implementor-reviewer");
              return [{
                eventId: `evt_${crypto.randomUUID()}`,
                sessionId: input.sessionId,
                agentId: input.agentId,
                timestamp: new Date().toISOString(),
                type: "agent.message",
                payload: { text: started }
              }];
            }
            if (input.agentId.includes("reviewer")) {
              await input.workflowTools?.stopSelf?.("review approved", "approved", ["review_no_blockers"]);
              return [{
                eventId: `evt_${crypto.randomUUID()}`,
                sessionId: input.sessionId,
                agentId: input.agentId,
                timestamp: new Date().toISOString(),
                type: "agent.message",
                payload: { text: "approved with no blockers" }
              }];
            }
            if (input.agentId.includes("implementor")) {
              implementorRuns += 1;
              if (implementorRuns === 1) {
                await implementorGate;
              }
              await input.workflowTools?.stopSelf?.("implementation ready", "implemented", ["implementation_finished"]);
              return [{
                eventId: `evt_${crypto.randomUUID()}`,
                sessionId: input.sessionId,
                agentId: input.agentId,
                timestamp: new Date().toISOString(),
                type: "agent.message",
                payload: { text: "implemented and ready" }
              }];
            }
            return [];
          }
        }
      });
      const snapshot = await manager.handle({
        id: "req_async_child_workflow",
        method: "createSession",
        params: {
          prompt: "start a child workflow asynchronously",
          workspaceRoot: root,
          workflowId: "planner-orchestrator",
          debugMode: false
        }
      }) as { sessionId: string };
      sessionId = snapshot.sessionId;

      const beforeRelease = await manager.handle({
        id: "req_async_child_workflow_before_release",
        method: "subscribeEvents",
        params: { sessionId: snapshot.sessionId }
      }) as { events: ReplayEvent[] };
      expect(beforeRelease.events.some((event) => event.type === "scheduler.job.created" && event.payload.kind === "workflow-execution")).toBe(true);
      expect(beforeRelease.events.some((event) => event.type === "workflow.completed")).toBe(false);

      releaseImplementor();
      await waitForEvents(manager, snapshot.sessionId, (events) =>
        events.some((event) => event.type === "workflow.completed" && event.payload.workflowId === "implementor-reviewer")
      );
      const settledEvents = await waitForSchedulerIdle(manager, snapshot.sessionId);
      expect(settledEvents.some((event) => event.type === "scheduler.job.completed" && event.payload.kind === "workflow-execution")).toBe(true);
    } finally {
      releaseImplementor();
      if (manager && sessionId) {
        await waitForSchedulerIdle(manager, sessionId).catch(() => {});
      }
      await rm(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
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
      await rm(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
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
      await rm(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
    }
  });

  it("exposes bounded workspace command execution to command-enabled roles", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-session-"));
    try {
      const manager = new SessionManager({
        sessionsRoot: root,
        runtime: {
          async runTurn(input) {
            const output = input.agentId.includes("qa")
              ? await input.workflowTools?.runWorkspaceCommand?.("node", ["-e", "console.log(process.cwd())"])
              : "ok";
            return [{
              eventId: `evt_${crypto.randomUUID()}`,
              sessionId: input.sessionId,
              agentId: input.agentId,
              timestamp: new Date().toISOString(),
              type: "agent.message",
              payload: { text: output ?? "" }
            }];
          }
        }
      });
      const snapshot = await manager.handle({
        id: "req_command_tool",
        method: "createSession",
        params: {
          prompt: "Implement and QA with command execution",
          workspaceRoot: root,
          workflowId: "implementor-qa-loop",
          debugMode: false
        }
      }) as { sessionId: string; workspaceRoot: string };
      const replay = await manager.handle({
        id: "req_command_tool_replay",
        method: "subscribeEvents",
        params: { sessionId: snapshot.sessionId }
      }) as { events: Array<{ type: string; agentId?: string; payload: Record<string, unknown> }> };
      expect(replay.events.some((event) =>
        event.type === "capability.checked"
        && event.agentId?.includes("qa")
        && event.payload.action === "workspace.command"
        && event.payload.allowed === true
      )).toBe(true);
      expect(replay.events.some((event) =>
        event.type === "agent.tool_result"
        && event.agentId?.includes("qa")
        && event.payload.toolName === "workspace.run_command"
        && event.payload.exitCode === 0
      )).toBe(true);
      expect(replay.events.some((event) =>
        event.type === "agent.message"
        && event.agentId?.includes("qa")
        && String(event.payload.text).includes(snapshot.workspaceRoot)
      )).toBe(true);
    } finally {
      await rm(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
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
      await rm(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
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
      await waitForSchedulerIdle(manager, snapshot.sessionId);
    } finally {
      await rm(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
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
      await rm(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
    }
  });
});
