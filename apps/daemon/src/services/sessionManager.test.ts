import { mkdtemp, readFile, rm } from "node:fs/promises";
import { existsSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import type { SessionEvent, SessionSnapshot } from "@software-factory/shared";
import { deriveActorStates } from "./concurrency.js";
import { SessionManager } from "./sessionManager.js";
import { EventStore, makeEventId } from "./eventStore.js";
import { OpenAIAuthenticationError } from "./agentRuntime.js";

type ReplayEvent = { eventId?: string; type: string; agentId?: string; payload: Record<string, unknown>; causationId?: string };

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

  it("preserves initial prompt image attachments in logs and runtime input", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-session-images-"));
    const seenAttachments: unknown[] = [];
    try {
      const manager = new SessionManager({
        sessionsRoot: root,
        runtime: {
          async runTurn(input) {
            if (input.agentId === "orchestrator") {
              seenAttachments.push(...(input.imageAttachments ?? []));
            }
            return [];
          }
        }
      });
      const imageAttachments = [{
        id: "img_test",
        name: "mockup.png",
        mimeType: "image/png",
        dataBase64: "iVBORw0KGgo=",
        detail: "high" as const
      }];

      const snapshot = await manager.handle({
        id: "req_create_images",
        method: "createSession",
        params: {
          prompt: "Review this mockup",
          imageAttachments,
          workspaceRoot: root,
          workflowId: "planner-orchestrator",
          debugMode: true
        }
      }) as SessionSnapshot;
      const replay = await manager.handle({
        id: "req_subscribe_images",
        method: "subscribeEvents",
        params: { sessionId: snapshot.sessionId }
      }) as { events: ReplayEvent[] };

      expect(seenAttachments).toEqual(imageAttachments);
      expect(replay.events.find((event) => event.type === "session.created")?.payload.imageAttachments).toEqual(imageAttachments);
      expect(replay.events.find((event) => event.type === "message.sent" && event.agentId === "orchestrator")?.payload.imageAttachments).toEqual(imageAttachments);
    } finally {
      await rm(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
    }
  });

  it("records durable mailbox enqueue and dequeue events for delivered actor turns", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-session-"));
    try {
      const manager = new SessionManager({ sessionsRoot: root });
      const snapshot = await manager.handle({
        id: "req_create_mailbox",
        method: "createSession",
        params: {
          prompt: "Build and review a tiny parser",
          workspaceRoot: root,
          workflowId: "implementor-reviewer",
          debugMode: true
        }
      }) as SessionSnapshot;

      const events = await waitForSchedulerIdle(manager, snapshot.sessionId) as SessionEvent[];
      const enqueued = events.filter((event) => event.type === "actor.mailbox.enqueued");
      const dequeuedMessageIds = new Set(events
        .filter((event) => event.type === "actor.mailbox.dequeued")
        .map((event) => String(event.payload.messageEventId ?? ""))
        .filter(Boolean));
      const scheduledCausationIds = new Set(events
        .filter((event) => event.type === "scheduler.job.created" && ["agent-turn", "workflow-agent-turn"].includes(String(event.payload.kind ?? "")))
        .map((event) => String(event.causationId ?? ""))
        .filter(Boolean));
      const deliveredMailboxItems = enqueued.filter((event) => scheduledCausationIds.has(String(event.payload.messageEventId ?? "")));

      expect(enqueued.length).toBeGreaterThan(0);
      expect(deliveredMailboxItems.length).toBeGreaterThan(0);
      expect(deliveredMailboxItems.every((event) => dequeuedMessageIds.has(String(event.payload.messageEventId ?? "")))).toBe(true);
      for (const [dequeueIndex, event] of events.entries()) {
        if (event.type !== "actor.mailbox.dequeued") continue;
        const scheduledIndex = events.findIndex((candidate) =>
          candidate.type === "scheduler.job.created"
            && candidate.causationId === event.payload.messageEventId
        );
        expect(scheduledIndex).toBeGreaterThanOrEqual(0);
        expect(dequeueIndex).toBeGreaterThan(scheduledIndex);
      }

      const latestSnapshot = await manager.handle({
        id: "req_mailbox_snapshot",
        method: "getSnapshot",
        params: { sessionId: snapshot.sessionId }
      }) as SessionSnapshot;
      const actorStates = deriveActorStates(latestSnapshot, events);
      const implementor = actorStates.find((actor) => actor.agentId === "implementor");
      expect(implementor?.mailbox.inbound.every((event) => !scheduledCausationIds.has(String(event.payload.messageEventId ?? "")))).toBe(true);
    } finally {
      await rm(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
    }
  });

  it("queues direct messages while an actor already has an active scheduler job", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-session-"));
    let releaseImplementor: () => void = () => {};
    const implementorGate = new Promise<void>((resolve) => {
      releaseImplementor = resolve;
    });
    let implementorRuns = 0;
    try {
      const manager = new SessionManager({
        sessionsRoot: root,
        runtime: {
          async runTurn(input) {
            if (input.agentId === "orchestrator") {
              if (!input.prompt.includes("Workflow implementor-reviewer completed")) {
                await input.workflowTools?.startWorkflow?.("implementor-reviewer");
              }
            }
            if (input.agentId.includes("implementor")) {
              implementorRuns += 1;
              if (implementorRuns === 1) {
                await implementorGate;
              }
            }
            return [{
              eventId: `evt_${crypto.randomUUID()}`,
              sessionId: input.sessionId,
              agentId: input.agentId,
              timestamp: new Date().toISOString(),
              type: "agent.message",
              payload: { text: `${input.agentId} handled ${input.prompt}` }
            }];
          }
        }
      });
      const snapshot = await manager.handle({
        id: "req_queue_while_active",
        method: "createSession",
        params: {
          prompt: "start async workflow",
          workspaceRoot: root,
          workflowId: "planner-orchestrator",
          debugMode: false
        }
      }) as SessionSnapshot;
      const activeEvents = await waitForEvents(manager, snapshot.sessionId, (events) =>
        events.some((event) => event.type === "scheduler.job.started" && event.agentId?.includes("implementor"))
      );
      const implementorId = activeEvents.find((event) => event.type === "scheduler.job.started" && event.agentId?.includes("implementor"))?.agentId;
      expect(implementorId).toBeTruthy();

      await manager.handle({
        id: "req_queue_active_nudge",
        method: "sendMessage",
        params: {
          sessionId: snapshot.sessionId,
          targetAgentId: implementorId,
          text: "queued while the implementor is busy"
        }
      });
      const queued = await manager.handle({
        id: "req_queue_active_replay",
        method: "subscribeEvents",
        params: { sessionId: snapshot.sessionId }
      }) as { events: ReplayEvent[] };
      const queuedMessage = [...queued.events].reverse().find((event) =>
        event.type === "message.sent"
          && event.payload.from === "user"
          && event.payload.to === implementorId
          && event.payload.text === "queued while the implementor is busy"
      );
      expect(queuedMessage?.eventId).toBeTruthy();
      expect(queued.events.some((event) => event.type === "actor.mailbox.enqueued" && event.payload.messageEventId === queuedMessage?.eventId)).toBe(true);
      expect(queued.events.some((event) => event.type === "scheduler.job.created" && event.causationId === queuedMessage?.eventId)).toBe(false);

      releaseImplementor();
      const drained = await waitForEvents(manager, snapshot.sessionId, (events) =>
        events.some((event) => event.type === "scheduler.job.created" && event.causationId === queuedMessage?.eventId)
          && events.some((event) => event.type === "actor.mailbox.dequeued" && event.payload.messageEventId === queuedMessage?.eventId)
      );
      expect(drained.some((event) => event.type === "actor.mailbox.dequeued" && event.payload.messageEventId === queuedMessage?.eventId)).toBe(true);
      await waitForSchedulerIdle(manager, snapshot.sessionId);
    } finally {
      releaseImplementor();
      await rm(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
    }
  });

  it("reschedules mailbox input whose prior scheduler job was recovered before dequeue", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-session-"));
    try {
      const manager = new SessionManager({ sessionsRoot: root });
      const snapshot = await manager.handle({
        id: "req_recover_mailbox_session",
        method: "createSession",
        params: {
          prompt: "recover mailbox",
          workspaceRoot: root,
          workflowId: "planner-orchestrator",
          debugMode: true
        }
      }) as SessionSnapshot;
      await waitForSchedulerIdle(manager, snapshot.sessionId);

      const store = new EventStore(root);
      const messageEventId = makeEventId();
      const originalJobId = `job_${crypto.randomUUID()}`;
      await store.append({
        eventId: messageEventId,
        sessionId: snapshot.sessionId,
        agentId: "orchestrator",
        timestamp: new Date().toISOString(),
        type: "message.sent",
        payload: { from: "user", to: "orchestrator", text: "retry after recovery" }
      });
      await store.append({
        eventId: makeEventId(),
        sessionId: snapshot.sessionId,
        agentId: "orchestrator",
        timestamp: new Date().toISOString(),
        type: "actor.mailbox.enqueued",
        payload: { mailbox: "orchestrator", from: "user", messageEventId, messageType: "message.sent" },
        causationId: messageEventId
      });
      await store.append({
        eventId: makeEventId(),
        sessionId: snapshot.sessionId,
        agentId: "orchestrator",
        timestamp: new Date().toISOString(),
        type: "scheduler.job.created",
        payload: { jobId: originalJobId, kind: "agent-turn", agentId: "orchestrator", prompt: "retry after recovery" },
        causationId: messageEventId,
        correlationId: originalJobId
      });
      await store.append({
        eventId: makeEventId(),
        sessionId: snapshot.sessionId,
        agentId: "orchestrator",
        timestamp: new Date().toISOString(),
        type: "scheduler.job.started",
        payload: { jobId: originalJobId, kind: "agent-turn", agentId: "orchestrator" },
        correlationId: originalJobId
      });

      const restarted = new SessionManager({ sessionsRoot: root });
      await restarted.handle({
        id: "req_recover_mailbox_list",
        method: "listSessions",
        params: { includeArchived: true }
      });
      await restarted.handle({
        id: "req_recover_mailbox_resume",
        method: "resumeAgent",
        params: { sessionId: snapshot.sessionId, agentId: "orchestrator" }
      });
      const events = await waitForSchedulerIdle(restarted, snapshot.sessionId);
      const createdForMessage = events.filter((event) =>
        event.type === "scheduler.job.created"
          && event.causationId === messageEventId
      );
      expect(createdForMessage.map((event) => event.payload.jobId)).toContain(originalJobId);
      expect(createdForMessage.some((event) => event.payload.jobId !== originalJobId)).toBe(true);
      expect(events.some((event) => event.type === "actor.mailbox.dequeued" && event.payload.messageEventId === messageEventId)).toBe(true);
    } finally {
      await rm(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
    }
  });

  it("does not duplicate mailbox jobs when concurrent drains race on the same message", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-session-"));
    try {
      const manager = new SessionManager({ sessionsRoot: root });
      const snapshot = await manager.handle({
        id: "req_concurrent_drain_session",
        method: "createSession",
        params: {
          prompt: "concurrent drain",
          workspaceRoot: root,
          workflowId: "planner-orchestrator",
          debugMode: true
        }
      }) as SessionSnapshot;
      await waitForSchedulerIdle(manager, snapshot.sessionId);

      const store = new EventStore(root);
      const messageEventId = makeEventId();
      await store.append({
        eventId: messageEventId,
        sessionId: snapshot.sessionId,
        agentId: "orchestrator",
        timestamp: new Date().toISOString(),
        type: "message.sent",
        payload: { from: "user", to: "orchestrator", text: "schedule exactly once" }
      });
      await store.append({
        eventId: makeEventId(),
        sessionId: snapshot.sessionId,
        agentId: "orchestrator",
        timestamp: new Date().toISOString(),
        type: "actor.mailbox.enqueued",
        payload: { mailbox: "orchestrator", from: "user", messageEventId, messageType: "message.sent" },
        causationId: messageEventId
      });

      await Promise.all([
        manager.handle({
          id: "req_concurrent_drain_resume_a",
          method: "resumeAgent",
          params: { sessionId: snapshot.sessionId, agentId: "orchestrator" }
        }),
        manager.handle({
          id: "req_concurrent_drain_resume_b",
          method: "resumeAgent",
          params: { sessionId: snapshot.sessionId, agentId: "orchestrator" }
        })
      ]);
      const events = await waitForSchedulerIdle(manager, snapshot.sessionId);
      expect(events.filter((event) => event.type === "scheduler.job.created" && event.causationId === messageEventId)).toHaveLength(1);
      expect(events.filter((event) => event.type === "actor.mailbox.dequeued" && event.payload.messageEventId === messageEventId)).toHaveLength(1);
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
  }, 10_000);

  it("renames sessions durably for lists and snapshots", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-session-"));
    try {
      const manager = new SessionManager({ sessionsRoot: root });
      const snapshot = await manager.handle({
        id: "req_create_rename",
        method: "createSession",
        params: {
          prompt: "same prompt",
          workspaceRoot: root,
          workflowId: "planner-orchestrator",
          debugMode: true
        }
      }) as { sessionId: string };
      await waitForSchedulerIdle(manager, snapshot.sessionId);

      await manager.handle({
        id: "req_rename",
        method: "renameSession",
        params: { sessionId: snapshot.sessionId, title: "Fixture parser spike" }
      });

      const listed = await manager.handle({
        id: "req_list_renamed",
        method: "listSessions",
        params: { includeArchived: true }
      }) as { sessions: Array<{ id: string; title: string }> };
      expect(listed.sessions.find((session) => session.id === snapshot.sessionId)?.title).toBe("Fixture parser spike");

      const renamedSnapshot = await manager.handle({
        id: "req_snapshot_renamed",
        method: "getSnapshot",
        params: { sessionId: snapshot.sessionId }
      }) as { title: string };
      expect(renamedSnapshot.title).toBe("Fixture parser spike");
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

  it("records workspace tool rows even when policy blocks execution", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-session-"));
    try {
      const manager = new SessionManager({
        sessionsRoot: root,
        runtime: { async runTurn() { return []; } }
      });
      const created = await manager.handle({
        id: "req_workspace_policy_block",
        method: "createSession",
        params: {
          prompt: "workspace policy block",
          workspaceRoot: root,
          workflowId: "planner-orchestrator",
          debugMode: false
        }
      }) as { sessionId: string };
      const snapshot = await manager.handle({
        id: "req_workspace_policy_block_snapshot",
        method: "getSnapshot",
        params: { sessionId: created.sessionId }
      }) as { sessionId: string };

      await expect((manager as unknown as {
        writeWorkspaceFile: (snapshot: unknown, agentId: string, relativePath: string, content: string, causationId: string | undefined, publish: (event: unknown) => void) => Promise<string>;
      }).writeWorkspaceFile(snapshot, "orchestrator", "blocked.txt", "blocked\n", undefined, () => {})).rejects.toThrow();

      const replay = await manager.handle({
        id: "req_workspace_policy_block_replay",
        method: "subscribeEvents",
        params: { sessionId: created.sessionId }
      }) as { events: ReplayEvent[] };
      const callIndex = replay.events.findIndex((event) => event.type === "agent.tool_call" && event.agentId === "orchestrator" && event.payload.toolName === "workspace.write_file");
      const resultIndex = replay.events.findIndex((event) => event.type === "agent.tool_result" && event.agentId === "orchestrator" && event.payload.toolName === "workspace.write_file" && event.payload.blocked === true);
      expect(callIndex).toBeGreaterThan(-1);
      expect(resultIndex).toBeGreaterThan(callIndex);
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

  it("refreshes OpenAI OAuth after an auth failure and retries the agent turn once", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-session-"));
    try {
      const seenKeys: Array<string | undefined> = [];
      const manager = new SessionManager({
        sessionsRoot: root,
        runtime: {
          async runTurn(input) {
            seenKeys.push(input.openAI?.apiKey);
            if (seenKeys.length === 1) {
              throw new OpenAIAuthenticationError("Provided authentication token is expired. Please try signing in again.", {
                status: 401,
                code: "token_expired"
              });
            }
            return [{
              eventId: makeEventId(),
              sessionId: input.sessionId,
              agentId: input.agentId,
              timestamp: new Date().toISOString(),
              type: "agent.message",
              payload: { text: "continued after refresh" }
            }];
          }
        }
      });
      (manager as unknown as { auth: unknown }).auth = {
        refreshLiveConnectionAfterAuthError: async () => ({
          apiKey: "fresh-token",
          baseURL: "https://chatgpt.com/backend-api/wham",
          defaultHeaders: { "ChatGPT-Account-Id": "acct_123" },
          source: "codex-oauth"
        }),
        beginOAuth: async () => {
          throw new Error("should not prompt when refresh succeeds");
        },
        deleteTokens: async () => {
          throw new Error("should not delete refreshed tokens");
        }
      };

      const events = await (manager as unknown as {
        runControlledTurn: (
          sessionId: string,
          agentId: string,
          publish: (event: SessionEvent) => void,
          input: Record<string, unknown>
        ) => Promise<SessionEvent[]>;
      }).runControlledTurn("sess_auth_retry", "orchestrator", () => {}, {
        sessionId: "sess_auth_retry",
        agentId: "orchestrator",
        prompt: "continue",
        debugMode: false,
        openAI: {
          apiKey: "expired-token",
          baseURL: "https://chatgpt.com/backend-api/wham"
        }
      });

      expect(seenKeys).toEqual(["expired-token", "fresh-token"]);
      expect(events.some((event) => event.type === "agent.message" && event.payload.text === "continued after refresh")).toBe(true);
      expect(events.some((event) => event.type === "error")).toBe(false);
    } finally {
      await rm(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
    }
  });

  it("emits an OpenAI reauthentication prompt when auth refresh is unavailable", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-session-"));
    try {
      const manager = new SessionManager({
        sessionsRoot: root,
        runtime: {
          async runTurn() {
            throw new OpenAIAuthenticationError("Provided authentication token is expired. Please try signing in again.", {
              status: 401,
              code: "token_expired"
            });
          }
        },
        port: 4567
      });
      (manager as unknown as { auth: unknown }).auth = {
        refreshLiveConnectionAfterAuthError: async () => undefined,
        beginOAuth: async (port?: number) => ({
          clientId: "app_EMoamEEZ73f0CkXaXp7hrann",
          state: "state_test",
          authorizationUrl: `http://auth.example.test/start${port ? `?port=${port}` : ""}`
        }),
        deleteTokens: async () => {
          throw new Error("refreshLiveConnectionAfterAuthError owns token cleanup classification");
        }
      };

      const events = await (manager as unknown as {
        runControlledTurn: (
          sessionId: string,
          agentId: string,
          publish: (event: SessionEvent) => void,
          input: Record<string, unknown>
        ) => Promise<SessionEvent[]>;
      }).runControlledTurn("sess_auth_prompt", "orchestrator", () => {}, {
        sessionId: "sess_auth_prompt",
        agentId: "orchestrator",
        prompt: "continue",
        debugMode: false,
        openAI: {
          apiKey: "expired-token",
          baseURL: "https://chatgpt.com/backend-api/wham"
        }
      });

      const error = events.find((event) => event.type === "error");
      expect(error?.payload.authenticationRequired).toBe(true);
      expect(error?.payload.authProvider).toBe("openai");
      expect(error?.payload.authorizationUrl).toBe("http://auth.example.test/start");
      expect(error?.payload.message).toContain("Sign in again");
    } finally {
      await rm(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
    }
  });

  it("does not issue an OpenAI OAuth URL when the fixed callback listener is unavailable", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-session-"));
    try {
      const manager = new SessionManager({
        sessionsRoot: root,
        ensureOAuthCallbackReady: () => false
      });

      await expect(manager.handle({
        id: "req_begin_oauth_no_callback",
        method: "beginOpenAIOAuth",
        params: {}
      })).rejects.toThrow("callback listener is not available");
    } finally {
      await rm(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
    }
  });

  it("rechecks OpenAI OAuth callback availability on each setup attempt", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-session-"));
    try {
      let attempts = 0;
      const manager = new SessionManager({
        sessionsRoot: root,
        ensureOAuthCallbackReady: () => {
          attempts += 1;
          return attempts > 1;
        }
      });

      await expect(manager.handle({
        id: "req_begin_oauth_retry_1",
        method: "beginOpenAIOAuth",
        params: {}
      })).rejects.toThrow("callback listener is not available");

      const prompt = await manager.handle({
        id: "req_begin_oauth_retry_2",
        method: "beginOpenAIOAuth",
        params: {}
      });

      expect(attempts).toBe(2);
      expect(prompt).toMatchObject({
        clientId: "app_EMoamEEZ73f0CkXaXp7hrann"
      });
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
      expect(recoveredSnapshot.graph.activeToolCalls.some((call) => (call as { callId?: string }).callId === "call_interrupted")).toBe(false);
      await waitForSchedulerIdle(restarted, snapshot.sessionId);
    } finally {
      await rm(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
    }
  });

  it("retries recovered agent-turn jobs from durable scheduler metadata", async () => {
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
              payload: { text: `handled ${input.prompt}` }
            }];
          }
        }
      });
      const snapshot = await manager.handle({
        id: "req_retry_recovered_session",
        method: "createSession",
        params: {
          prompt: "initial",
          workspaceRoot: root,
          workflowId: "planner-orchestrator",
          debugMode: false
        }
      }) as { sessionId: string };
      await waitForSchedulerIdle(manager, snapshot.sessionId);

      const store = new EventStore(root);
      const openJobId = `job_${crypto.randomUUID()}`;
      const created = await store.append({
        eventId: makeEventId(),
        sessionId: snapshot.sessionId,
        agentId: "orchestrator",
        timestamp: new Date().toISOString(),
        type: "scheduler.job.created",
        payload: { jobId: openJobId, kind: "agent-turn", agentId: "orchestrator", prompt: "retry me" },
        correlationId: openJobId
      });
      await store.append({
        eventId: makeEventId(),
        sessionId: snapshot.sessionId,
        agentId: "orchestrator",
        timestamp: new Date().toISOString(),
        type: "scheduler.job.started",
        payload: { jobId: openJobId, kind: "agent-turn", agentId: "orchestrator" },
        causationId: created.eventId,
        correlationId: openJobId
      });

      const restarted = new SessionManager({
        sessionsRoot: root,
        runtime: {
          async runTurn(input) {
            return [{
              eventId: `evt_${crypto.randomUUID()}`,
              sessionId: input.sessionId,
              agentId: input.agentId,
              timestamp: new Date().toISOString(),
              type: "agent.message",
              payload: { text: `retried ${input.prompt}` }
            }];
          }
        }
      });
      await restarted.handle({
        id: "req_retry_recovered_list",
        method: "listSessions",
        params: { includeArchived: true }
      });
      await Promise.all([
        restarted.handle({
          id: "req_retry_recovered_job_a",
          method: "retryRecoveredJob",
          params: { sessionId: snapshot.sessionId, jobId: openJobId }
        }),
        restarted.handle({
          id: "req_retry_recovered_job_b",
          method: "retryRecoveredJob",
          params: { sessionId: snapshot.sessionId, jobId: openJobId }
        })
      ]);
      const replay = await waitForSchedulerIdle(restarted, snapshot.sessionId);
      expect(replay.some((event) => event.type === "scheduler.job.recovered" && event.payload.jobId === openJobId)).toBe(true);
      expect(replay.some((event) => event.type === "scheduler.job.retry_requested" && event.payload.jobId === openJobId && event.payload.reason === "manual retry requested")).toBe(true);
      expect(replay.some((event) => event.type === "agent.message" && event.payload.text === "retried retry me")).toBe(true);
      expect(replay.some((event) => event.type === "scheduler.job.completed" && event.payload.kind === "agent-turn" && event.payload.jobId !== openJobId)).toBe(true);
      const beforeSecondRetryCount = replay.filter((event) => event.type === "scheduler.job.created" && event.payload.kind === "agent-turn").length;
      await restarted.handle({
        id: "req_retry_recovered_job_again",
        method: "retryRecoveredJob",
        params: { sessionId: snapshot.sessionId, jobId: openJobId }
      });
      const afterSecondRetry = await waitForSchedulerIdle(restarted, snapshot.sessionId);
      expect(afterSecondRetry.filter((event) => event.type === "scheduler.job.created" && event.payload.kind === "agent-turn")).toHaveLength(beforeSecondRetryCount);
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
      expect(recoveredEvents.some((event) => event.type === "scheduler.job.retry_requested" && event.payload.jobId === openJobId && event.payload.reason === "auto-resume workflow execution after daemon restart")).toBe(true);
      expect(recoveredEvents.some((event) => event.type === "scheduler.job.created" && event.payload.kind === "workflow-execution" && event.payload.jobId !== openJobId)).toBe(true);
      const replacementWorkflowJobs = recoveredEvents.filter((event) => event.type === "scheduler.job.created" && event.payload.kind === "workflow-execution" && event.payload.jobId !== openJobId).length;
      await restarted.handle({
        id: "req_retry_auto_resumed_workflow_again",
        method: "retryRecoveredJob",
        params: { sessionId: snapshot.sessionId, jobId: openJobId }
      });
      const afterManualRetry = await waitForSchedulerIdle(restarted, snapshot.sessionId);
      expect(afterManualRetry.filter((event) => event.type === "scheduler.job.created" && event.payload.kind === "workflow-execution" && event.payload.jobId !== openJobId)).toHaveLength(replacementWorkflowJobs);
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
      await waitForSchedulerIdle(manager, snapshot.sessionId);

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
      const settled = await waitForSchedulerIdle(manager, snapshot.sessionId);
      expect(settled.some((event) => event.type === "workflow.waiting" && event.payload.workflowId === "implementor-qa-loop")).toBe(true);
    } finally {
      await rm(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
    }
  });

  it("recovers waiting open workflows by scheduling a continuation job", async () => {
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
              await input.workflowTools?.stopSelf?.("blocked on missing criteria", undefined, ["qa_acceptance"]);
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
        id: "req_waiting_recovery_session",
        method: "createSession",
        params: {
          prompt: "create waiting workflow",
          workspaceRoot: root,
          workflowId: "planner-orchestrator",
          debugMode: false
        }
      }) as { sessionId: string };
      const beforeRecovery = await waitForSchedulerIdle(manager, snapshot.sessionId);
      const waiting = beforeRecovery.find((event) => event.type === "workflow.waiting" && event.payload.workflowId === "implementor-qa-loop");
      expect(waiting).toBeTruthy();
      const waitingJobCompleted = beforeRecovery.find((event) =>
        event.type === "scheduler.job.completed"
        && event.payload.kind === "workflow-execution"
        && event.payload.workflowExecutionStatus === "waiting"
      );
      expect(waitingJobCompleted?.payload.message).toBe("workflow waiting");
      expect(waitingJobCompleted?.payload.pendingAgentIds).toContain("implementor-qa-loop_implementor");
      expect(waitingJobCompleted?.payload.pendingCriteria).toContain("implementation_ready_for_qa");
      const workflowJobCount = beforeRecovery.filter((event) => event.type === "scheduler.job.created" && event.payload.kind === "workflow-execution").length;

      const restarted = new SessionManager({
        sessionsRoot: root,
        runtime: {
          async runTurn(input) {
            return [{
              eventId: `evt_${crypto.randomUUID()}`,
              sessionId: input.sessionId,
              agentId: input.agentId,
              timestamp: new Date().toISOString(),
              type: "agent.message",
              payload: { text: "recovered" }
            }];
          }
        }
      });
      await restarted.handle({
        id: "req_waiting_recovery_list",
        method: "listSessions",
        params: { includeArchived: true }
      });
      const afterRecovery = await waitForEvents(restarted, snapshot.sessionId, (events) =>
        events.filter((event) => event.type === "scheduler.job.created" && event.payload.kind === "workflow-execution").length > workflowJobCount
      );
      expect(afterRecovery.some((event) => event.type === "scheduler.job.created" && event.payload.kind === "workflow-execution" && event.causationId === waiting?.eventId)).toBe(true);
    } finally {
      await rm(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
    }
  });

  it("continues recovery when a waiting workflow spec is unavailable", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-session-"));
    try {
      const manager = new SessionManager({ sessionsRoot: root });
      const snapshot = await manager.handle({
        id: "req_missing_workflow_waiting_session",
        method: "createSession",
        params: {
          prompt: "missing waiting workflow",
          workspaceRoot: root,
          workflowId: "planner-orchestrator",
          debugMode: true
        }
      }) as { sessionId: string };
      const store = new EventStore(root);
      await store.append({
        eventId: makeEventId(),
        sessionId: snapshot.sessionId,
        agentId: "wf_missing",
        timestamp: new Date().toISOString(),
        type: "workflow.instantiated",
        payload: {
          workflowInstanceId: "wf_missing",
          workflowId: "missing-personal-workflow",
          callerAgentId: "orchestrator",
          nodeMap: { orchestrator: "orchestrator", implementor: "missing_implementor" },
          completionCriteria: []
        }
      });
      const waiting = await store.append({
        eventId: makeEventId(),
        sessionId: snapshot.sessionId,
        agentId: "wf_missing",
        timestamp: new Date().toISOString(),
        type: "workflow.waiting",
        payload: {
          workflowInstanceId: "wf_missing",
          workflowId: "missing-personal-workflow",
          callerAgentId: "orchestrator",
          pendingAgentIds: ["missing_implementor"],
          pendingCriteria: []
        }
      });

      const restarted = new SessionManager({ sessionsRoot: root });
      await restarted.handle({
        id: "req_missing_waiting_recover",
        method: "listSessions",
        params: { includeArchived: true }
      });
      const replay = await restarted.handle({
        id: "req_missing_waiting_replay",
        method: "subscribeEvents",
        params: { sessionId: snapshot.sessionId }
      }) as { events: ReplayEvent[] };
      expect(replay.events.some((event) => event.type === "error" && event.causationId === waiting.eventId && String(event.payload.message).includes("Cannot resume waiting workflow wf_missing"))).toBe(true);
    } finally {
      await rm(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
    }
  });

  it("counts workflow turns from scheduler completions instead of transcript artifacts", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-session-"));
    try {
      const manager = new SessionManager({ sessionsRoot: root });
      const workflowRunCounts = (manager as unknown as {
        workflowRunCounts(
          events: Array<Record<string, unknown>>,
          nodeMap: Map<string, string>,
          orchestratorId: string,
          workflowInstanceId: string
        ): Map<string, number>;
      }).workflowRunCounts.bind(manager);
      const nodeMap = new Map([
        ["orchestrator", "orchestrator"],
        ["implementor", "implementation-review-qa_implementor"]
      ]);
      const baseEvent = {
        sessionId: "sess_turn_count",
        timestamp: new Date().toISOString()
      };
      const artifactEvents = Array.from({ length: 5 }, (_, index) => ({
        ...baseEvent,
        eventId: `evt_file_${index}`,
        agentId: "implementation-review-qa_implementor",
        type: "workspace.file_touched",
        payload: { workflowInstanceId: "wf_turn_count", path: `file${index}.txt` }
      }));
      const counts = workflowRunCounts([
        ...artifactEvents,
        {
          ...baseEvent,
          eventId: "evt_turn_completed",
          agentId: "implementation-review-qa_implementor",
          type: "scheduler.job.completed",
          payload: {
            kind: "workflow-agent-turn",
            workflowInstanceId: "wf_turn_count",
            agentId: "implementation-review-qa_implementor"
          }
        }
      ], nodeMap, "orchestrator", "wf_turn_count");
      expect(counts.get("implementation-review-qa_implementor")).toBe(1);

      const mixedCounts = workflowRunCounts([
        ...artifactEvents,
        {
          ...baseEvent,
          eventId: "evt_legacy_message",
          agentId: "implementation-review-qa_implementor",
          type: "agent.message",
          payload: { workflowInstanceId: "wf_turn_count", text: "legacy progress" }
        },
        {
          ...baseEvent,
          eventId: "evt_turn_completed",
          agentId: "implementation-review-qa_implementor",
          type: "scheduler.job.completed",
          payload: {
            kind: "workflow-agent-turn",
            workflowInstanceId: "wf_turn_count",
            agentId: "implementation-review-qa_implementor"
          }
        }
      ], nodeMap, "orchestrator", "wf_turn_count");
      expect(mixedCounts.get("implementation-review-qa_implementor")).toBe(2);
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

  it("closes continuous improvement when the TODO generator stops", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-session-"));
    try {
      const manager = new SessionManager({
        sessionsRoot: root,
        runtime: {
          async runTurn(input) {
            if (input.agentId === "orchestrator") {
              if (input.prompt.includes("Workflow continuous-improvement completed")) {
                return [{
                  eventId: `evt_${crypto.randomUUID()}`,
                  sessionId: input.sessionId,
                  agentId: input.agentId,
                  timestamp: new Date().toISOString(),
                  type: "agent.message",
                  payload: { text: "continuous completion observed" }
                }];
              }
              const started = await input.workflowTools?.startWorkflow?.("continuous-improvement");
              return [{
                eventId: `evt_${crypto.randomUUID()}`,
                sessionId: input.sessionId,
                agentId: input.agentId,
                timestamp: new Date().toISOString(),
                type: "agent.message",
                payload: { text: started }
              }];
            }
            if (input.agentId.includes("todo_generator")) {
              await input.workflowTools?.stopSelf?.("Project is acceptable; no further improvements remain.", "no more useful TODOs", ["continuous_assessment_complete"]);
              return [{
                eventId: `evt_${crypto.randomUUID()}`,
                sessionId: input.sessionId,
                agentId: input.agentId,
                timestamp: new Date().toISOString(),
                type: "agent.message",
                payload: { text: "continuous improvement complete" }
              }];
            }
            throw new Error(`Unexpected agent run: ${input.agentId}`);
          }
        }
      });
      const snapshot = await manager.handle({
        id: "req_continuous_stop",
        method: "createSession",
        params: {
          prompt: "start continuous improvement and stop when done",
          workspaceRoot: root,
          workflowId: "planner-orchestrator",
          debugMode: false
        }
      }) as { sessionId: string };
      const events = await waitForSchedulerIdle(manager, snapshot.sessionId);

      expect(events.some((event) => event.type === "workflow.completed" && event.payload.workflowId === "continuous-improvement")).toBe(true);
      expect(events.some((event) => event.type === "agent.stopped" && String(event.agentId ?? "").includes("todo_generator"))).toBe(true);
      expect(events.some((event) => event.type === "agent.status" && String(event.agentId ?? "").includes("continuous-improvement_implementor") && event.payload.status === "cancelled")).toBe(true);
      expect(events.some((event) => event.type === "agent.status" && String(event.agentId ?? "").includes("continuous-improvement_reviewer") && event.payload.status === "cancelled")).toBe(true);
    } finally {
      await rm(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
    }
  });

  it("returns continuous improvement control to the TODO generator after review", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-session-"));
    let todoRuns = 0;
    let implementorRuns = 0;
    let reviewerRuns = 0;
    try {
      const manager = new SessionManager({
        sessionsRoot: root,
        runtime: {
          async runTurn(input) {
            if (input.agentId === "orchestrator") {
              if (input.prompt.includes("Workflow continuous-improvement completed")) {
                return [{
                  eventId: `evt_${crypto.randomUUID()}`,
                  sessionId: input.sessionId,
                  agentId: input.agentId,
                  timestamp: new Date().toISOString(),
                  type: "agent.message",
                  payload: { text: "continuous completion observed" }
                }];
              }
              const started = await input.workflowTools?.startWorkflow?.("continuous-improvement");
              return [{
                eventId: `evt_${crypto.randomUUID()}`,
                sessionId: input.sessionId,
                agentId: input.agentId,
                timestamp: new Date().toISOString(),
                type: "agent.message",
                payload: { text: started }
              }];
            }
            if (input.agentId.includes("todo_generator")) {
              todoRuns += 1;
              if (todoRuns === 1) {
                return [{
                  eventId: `evt_${crypto.randomUUID()}`,
                  sessionId: input.sessionId,
                  agentId: input.agentId,
                  timestamp: new Date().toISOString(),
                  type: "agent.message",
                  payload: { text: "Next TODO: improve the parser." }
                }];
              }
              await input.workflowTools?.stopSelf?.("No further improvements remain after reviewed implementation.", "accepted", ["continuous_assessment_complete"]);
              return [{
                eventId: `evt_${crypto.randomUUID()}`,
                sessionId: input.sessionId,
                agentId: input.agentId,
                timestamp: new Date().toISOString(),
                type: "agent.message",
                payload: { text: "continuous improvement complete" }
              }];
            }
            if (input.agentId.includes("implementor")) {
              implementorRuns += 1;
              return [{
                eventId: `evt_${crypto.randomUUID()}`,
                sessionId: input.sessionId,
                agentId: input.agentId,
                timestamp: new Date().toISOString(),
                type: "agent.message",
                payload: { text: implementorRuns === 1 ? "implemented change for review" : "review handled, returning to todo generator" }
              }];
            }
            if (input.agentId.includes("reviewer")) {
              reviewerRuns += 1;
              await input.workflowTools?.stopSelf?.("review approved", "approved", []);
              return [{
                eventId: `evt_${crypto.randomUUID()}`,
                sessionId: input.sessionId,
                agentId: input.agentId,
                timestamp: new Date().toISOString(),
                type: "agent.message",
                payload: { text: "approved with no blockers" }
              }];
            }
            throw new Error(`Unexpected agent run: ${input.agentId}`);
          }
        }
      });
      const snapshot = await manager.handle({
        id: "req_continuous_loop",
        method: "createSession",
        params: {
          prompt: "start continuous improvement with one reviewed item",
          workspaceRoot: root,
          workflowId: "planner-orchestrator",
          debugMode: false
        }
      }) as { sessionId: string };
      const events = await waitForSchedulerIdle(manager, snapshot.sessionId);

      expect(todoRuns).toBe(2);
      expect(implementorRuns).toBe(2);
      expect(reviewerRuns).toBe(1);
      const messageEdges = events
        .filter((event) => event.type === "message.sent" && event.payload.workflowId !== "continuous-improvement")
        .map((event) => event.payload.edgeId);
      expect(messageEdges).toEqual(expect.arrayContaining(["message-implementor-reviewer", "message-implementor-todo_generator"]));
      expect(events.some((event) => event.type === "workflow.completed" && event.payload.workflowId === "continuous-improvement")).toBe(true);
    } finally {
      await rm(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
    }
  });

  it("exposes UI-QA Playwright and Computer Use guidance tools", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-session-"));
    try {
      const manager = new SessionManager({
        sessionsRoot: root,
        runtime: {
          async runTurn(input) {
            if (input.agentId === "orchestrator") {
              if (input.prompt.includes("Workflow ui-qa-review completed")) {
                return [{
                  eventId: `evt_${crypto.randomUUID()}`,
                  sessionId: input.sessionId,
                  agentId: input.agentId,
                  timestamp: new Date().toISOString(),
                  type: "agent.message",
                  payload: { text: "ui qa completion observed" }
                }];
              }
              const started = await input.workflowTools?.startWorkflow?.("ui-qa-review");
              return [{
                eventId: `evt_${crypto.randomUUID()}`,
                sessionId: input.sessionId,
                agentId: input.agentId,
                timestamp: new Date().toISOString(),
                type: "agent.message",
                payload: { text: started }
              }];
            }
            if (input.agentId.includes("ui_qa")) {
              const blockedBrowser = await input.workflowTools?.runPlaywrightCheck?.("https://example.com", "Reject non-local UI QA targets.");
              const localBrowser = await input.workflowTools?.runPlaywrightCheck?.("http://127.0.0.1:9", "Check a sample UI development task.");
              const computer = await input.workflowTools?.computerUseGuide?.();
              await input.workflowTools?.stopSelf?.("UI QA completed.", { blockedBrowser, localBrowser, computer }, ["ui_qa_review_complete"]);
              return [{
                eventId: `evt_${crypto.randomUUID()}`,
                sessionId: input.sessionId,
                agentId: input.agentId,
                timestamp: new Date().toISOString(),
                type: "agent.message",
                payload: { text: "UI QA findings: no target URL was provided; use Playwright or Computer Use harness for visual verification." }
              }];
            }
            throw new Error(`Unexpected agent run: ${input.agentId}`);
          }
        }
      });
      const snapshot = await manager.handle({
        id: "req_ui_qa_tools",
        method: "createSession",
        params: {
          prompt: "test UI-QA role on a UI development task",
          workspaceRoot: root,
          workflowId: "planner-orchestrator",
          debugMode: false
        }
      }) as { sessionId: string };
      const events = await waitForSchedulerIdle(manager, snapshot.sessionId);

      expect(events.some((event) => event.type === "capability.checked" && String(event.agentId ?? "").includes("ui_qa") && event.payload.action === "ui.browser" && event.payload.allowed === true)).toBe(true);
      expect(events.some((event) => event.type === "capability.checked" && String(event.agentId ?? "").includes("ui_qa") && event.payload.action === "ui.computer" && event.payload.allowed === true)).toBe(true);
      const browserResults = events.filter((event) => event.type === "agent.tool_result" && event.payload.toolName === "ui_qa.playwright_check");
      expect(browserResults.some((event) => String(event.payload.output ?? "").includes("Blocked Playwright UI QA target"))).toBe(true);
      expect(browserResults.some((event) => String(event.payload.output ?? "").includes("127.0.0.1:9") && !String(event.payload.output ?? "").includes("Blocked Playwright UI QA target"))).toBe(true);
      expect(events.some((event) => event.type === "agent.tool_result" && event.payload.toolName === "ui_qa.computer_use_guide")).toBe(true);
      expect(events.some((event) => event.type === "workflow.completed" && event.payload.workflowId === "ui-qa-review")).toBe(true);
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
    let orchestratorRuns = 0;
    let manager: SessionManager | undefined;
    let sessionId: string | undefined;
    try {
      manager = new SessionManager({
        sessionsRoot: root,
          runtime: {
            async runTurn(input) {
              if (input.agentId === "orchestrator") {
                orchestratorRuns += 1;
                if (input.prompt.includes("Workflow implementor-reviewer completed")) {
                  return [{
                    eventId: `evt_${crypto.randomUUID()}`,
                    sessionId: input.sessionId,
                    agentId: input.agentId,
                    timestamp: new Date().toISOString(),
                    type: "agent.message",
                    payload: { text: "workflow completion observed" }
                  }];
                }
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
      expect(orchestratorRuns).toBeGreaterThanOrEqual(2);
      expect(settledEvents.some((event) => event.type === "agent.message" && event.agentId === "orchestrator" && event.payload.text === "workflow completion observed")).toBe(true);
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

  it("skips orchestrator tool messages to completed agents without failing the turn", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-session-"));
    try {
      const manager = new SessionManager({
        sessionsRoot: root,
        runtime: {
          async runTurn(input) {
            if (input.agentId === "orchestrator" && input.prompt === "send to completed planner") {
              const result = await input.workflowTools?.sendAgentMessage?.("planner", "late follow-up");
              return [{
                eventId: `evt_${crypto.randomUUID()}`,
                sessionId: input.sessionId,
                agentId: input.agentId,
                timestamp: new Date().toISOString(),
                type: "agent.message",
                payload: { text: result ?? "" }
              }];
            }
            return [{
              eventId: `evt_${crypto.randomUUID()}`,
              sessionId: input.sessionId,
              agentId: input.agentId,
              timestamp: new Date().toISOString(),
              type: "agent.message",
              payload: { text: "idle" }
            }];
          }
        }
      });
      const snapshot = await manager.handle({
        id: "req_create_skip_completed_message",
        method: "createSession",
        params: {
          prompt: "setup",
          workspaceRoot: root,
          workflowId: "planner-orchestrator",
          debugMode: false
        }
      }) as { sessionId: string };
      const store = new EventStore(root);
      await store.append({
        eventId: makeEventId(),
        sessionId: snapshot.sessionId,
        agentId: "planner",
        timestamp: new Date().toISOString(),
        type: "agent.status",
        payload: { status: "completed" }
      });
      await store.rebuildSnapshot(snapshot.sessionId);

      await manager.handle({
        id: "req_skip_completed_message",
        method: "sendMessage",
        params: {
          sessionId: snapshot.sessionId,
          text: "send to completed planner"
        }
      });
      const replay = await manager.handle({
        id: "req_skip_completed_message_replay",
        method: "subscribeEvents",
        params: { sessionId: snapshot.sessionId }
      }) as { events: Array<{ type: string; agentId?: string; payload: Record<string, unknown> }> };

      expect(replay.events.some((event) => event.type === "message.skipped" && event.payload.to === "planner" && event.payload.targetStatus === "completed")).toBe(true);
      expect(replay.events.some((event) => event.type === "message.sent" && event.payload.to === "planner" && event.payload.text === "late follow-up")).toBe(false);
      expect(replay.events.some((event) => event.type === "error" && String(event.payload.message).includes("cannot receive messages while completed"))).toBe(false);
      expect(replay.events.some((event) => event.type === "scheduler.job.failed" && String(event.payload.message).includes("cannot receive messages while completed"))).toBe(false);
    } finally {
      await rm(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
    }
  });

  it("lets the orchestrator inspect agent event summaries and full event payloads", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-session-"));
    try {
      const manager = new SessionManager({
        sessionsRoot: root,
        runtime: {
          async runTurn(input) {
            if (input.agentId === "orchestrator" && input.prompt === "inspect implementor events") {
              const listed = await input.workflowTools?.listAgentEvents?.("implementor", 20) as { events: Array<{ eventId: string; type: string; diffPreview?: string }> };
              const touched = listed.events.find((event) => event.type === "workspace.file_touched");
              const inspected = touched
                ? await input.workflowTools?.listAgentEvents?.("implementor", 20, touched.eventId) as { inspectedEvent?: { payload?: { diff?: string } } }
                : undefined;
              return [{
                eventId: `evt_${crypto.randomUUID()}`,
                sessionId: input.sessionId,
                agentId: input.agentId,
                timestamp: new Date().toISOString(),
                type: "agent.message",
                payload: { text: JSON.stringify({ summaryCount: listed.events.length, diff: inspected?.inspectedEvent?.payload?.diff }) }
              }];
            }
            return [{
              eventId: `evt_${crypto.randomUUID()}`,
              sessionId: input.sessionId,
              agentId: input.agentId,
              timestamp: new Date().toISOString(),
              type: "agent.message",
              payload: { text: "idle" }
            }];
          }
        }
      });
      const snapshot = await manager.handle({
        id: "req_event_inspection_create",
        method: "createSession",
        params: {
          prompt: "setup inspection",
          workspaceRoot: root,
          workflowId: "planner-orchestrator",
          debugMode: false
        }
      }) as { sessionId: string };
      const store = new EventStore(root);
      const diff = "--- a/report.txt\n+++ b/report.txt\n@@\n-old\n+new\n";
      const touchedId = makeEventId();
      await store.append({
        eventId: touchedId,
        sessionId: snapshot.sessionId,
        agentId: "implementor",
        timestamp: new Date().toISOString(),
        type: "workspace.file_touched",
        payload: { path: "report.txt", diff }
      });
      await store.rebuildSnapshot(snapshot.sessionId);

      await manager.handle({
        id: "req_event_inspection",
        method: "sendMessage",
        params: { sessionId: snapshot.sessionId, text: "inspect implementor events" }
      });
      const replay = await manager.handle({
        id: "req_event_inspection_replay",
        method: "subscribeEvents",
        params: { sessionId: snapshot.sessionId }
      }) as { events: Array<{ type: string; agentId?: string; payload: Record<string, unknown> }> };
      const message = [...replay.events].reverse().find((event) => event.type === "agent.message" && event.agentId === "orchestrator");
      const output = JSON.parse(String(message?.payload.text)) as { diff?: string };
      expect(output.diff).toBe(diff);
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

  it("blocks workspace commands whose cwd is outside role allowed roots", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-session-"));
    try {
      const manager = new SessionManager({
        sessionsRoot: root,
        runtime: {
          async runTurn(input) {
            const output = input.agentId.includes("qa")
              ? await input.workflowTools?.runWorkspaceCommand?.("node", ["-e", "console.log('should not run')"], ".")
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
      await manager.handle({
        id: "req_scoped_qa_role",
        method: "upsertRole",
        params: {
          role: {
            id: "qa",
            name: "QAer",
            color: "#e74c3c",
            promptTemplate: "Run QA checks.",
            model: "gpt-5.4",
            toolPolicy: { canRead: true, canWrite: false, canRunCommands: true, canCreatePlans: false },
            workspace: { allowedRoots: ["src"] },
            expectedOutputs: [],
            reviewResponsibilities: []
          }
        }
      });
      const snapshot = await manager.handle({
        id: "req_scoped_command",
        method: "createSession",
        params: {
          prompt: "Run from disallowed cwd",
          workspaceRoot: root,
          workflowId: "implementor-qa-loop",
          debugMode: false
        }
      }) as { sessionId: string };
      const events = await waitForEvents(manager, snapshot.sessionId, (replay) =>
        replay.some((event) =>
          event.type === "agent.tool_result"
            && event.payload.toolName === "workspace.run_command"
            && event.payload.blocked === true
        )
      );

      expect(events.some((event) =>
        event.type === "agent.tool_result"
          && event.payload.toolName === "workspace.run_command"
          && event.payload.blocked === true
          && String(event.payload.output).includes("outside allowed workspace roots")
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
