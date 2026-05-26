import { describe, expect, it } from "vitest";
import type { SessionEvent, SessionSnapshot } from "@multiagent/shared";
import { ActorRegistry, SchedulerProjection, deriveActorStates } from "./concurrency.js";

describe("concurrency projections", () => {
  it("derives actor state, mailbox contents, and scheduler jobs from durable events", () => {
    const events: SessionEvent[] = [
      event("evt_status_idle", "sess_projection", "implementor", "agent.status", { status: "idle" }),
      event("evt_message", "sess_projection", "orchestrator", "message.sent", { from: "orchestrator", to: "implementor", text: "build it" }),
      event("evt_mailbox", "sess_projection", "implementor", "actor.mailbox.enqueued", { mailbox: "implementor", messageEventId: "evt_message", messageType: "message.sent" }, "evt_message"),
      event("evt_job_created", "sess_projection", "implementor", "scheduler.job.created", { jobId: "job_1", kind: "workflow-agent-turn", agentId: "implementor" }),
      event("evt_job_started", "sess_projection", "implementor", "scheduler.job.started", { jobId: "job_1", kind: "workflow-agent-turn", agentId: "implementor" }),
      event("evt_status_working", "sess_projection", "implementor", "agent.status", { status: "working" })
    ];
    const snapshot = snapshotWithAgent("sess_projection", "implementor", "idle");

    const [actor] = deriveActorStates(snapshot, events);
    const scheduler = SchedulerProjection.fromEvents(snapshot.sessionId, events);

    expect(actor?.status).toBe("working");
    expect(actor?.mailbox.inbound.map((item) => item.eventId)).toContain("evt_mailbox");
    expect(actor?.activeJobIds).toEqual(["job_1"]);
    expect(scheduler.openJobs().map((job) => job.jobId)).toEqual(["job_1"]);
  });

  it("removes dequeued mailbox messages from the pending actor mailbox", () => {
    const events: SessionEvent[] = [
      event("evt_message", "sess_projection", "orchestrator", "message.sent", { from: "orchestrator", to: "implementor", text: "build it" }),
      event("evt_mailbox", "sess_projection", "implementor", "actor.mailbox.enqueued", { mailbox: "implementor", messageEventId: "evt_message" }, "evt_message"),
      event("evt_dequeue", "sess_projection", "implementor", "actor.mailbox.dequeued", { mailbox: "implementor", messageEventId: "evt_message" }, "evt_message")
    ];
    const snapshot = snapshotWithAgent("sess_projection", "implementor", "idle");

    const [actor] = deriveActorStates(snapshot, events);

    expect(actor?.mailbox.inbound).toEqual([]);
  });

  it("keeps active abort controllers separate from durable actor projection", () => {
    const registry = new ActorRegistry();
    const snapshot = snapshotWithAgent("sess_projection", "implementor", "idle");
    registry.rehydrate(snapshot, [
      event("evt_status_idle", "sess_projection", "implementor", "agent.status", { status: "idle" })
    ]);

    const controller = registry.startRun("sess_projection", "implementor");
    expect(registry.hasActiveRun("sess_projection", "implementor")).toBe(true);
    expect(() => registry.startRun("sess_projection", "implementor")).toThrow(/already has an active run/);
    registry.abortRun("sess_projection", "implementor");
    expect(controller.signal.aborted).toBe(true);
    registry.finishRun("sess_projection", "implementor", controller);
    expect(registry.hasActiveRun("sess_projection", "implementor")).toBe(false);
    expect(registry.canSchedule("sess_projection", "implementor")).toBe(true);
  });

  it("does not clear other sessions when one session is rehydrated", () => {
    const registry = new ActorRegistry();
    registry.rehydrate(snapshotWithAgent("sess_a", "implementor", "idle"), []);
    registry.rehydrate(snapshotWithAgent("sess_b", "reviewer", "idle"), []);

    expect(registry.actor("sess_a", "implementor")?.agentId).toBe("implementor");
    expect(registry.actor("sess_b", "reviewer")?.agentId).toBe("reviewer");
  });

  it("treats open scheduler jobs as making an actor unschedulable", () => {
    const registry = new ActorRegistry();
    const snapshot = snapshotWithAgent("sess_projection", "implementor", "idle");
    registry.rehydrate(snapshot, [
      event("evt_job_created", "sess_projection", "implementor", "scheduler.job.created", { jobId: "job_1", kind: "agent-turn", agentId: "implementor" }),
      event("evt_job_started", "sess_projection", "implementor", "scheduler.job.started", { jobId: "job_1", kind: "agent-turn", agentId: "implementor" })
    ]);

    expect(registry.canSchedule("sess_projection", "implementor")).toBe(false);
  });
});

function event(eventId: string, sessionId: string, agentId: string, type: SessionEvent["type"], payload: Record<string, unknown>, causationId?: string): SessionEvent {
  return {
    eventId,
    sessionId,
    agentId,
    timestamp: "2026-01-01T00:00:00.000Z",
    type,
    payload,
    causationId
  };
}

function snapshotWithAgent(sessionId: string, agentId: string, status: "idle" | "working"): SessionSnapshot {
  return {
    sessionId,
    title: "Projection",
    createdAt: "2026-01-01T00:00:00.000Z",
    updatedAt: "2026-01-01T00:00:00.000Z",
    workspaceRoot: "/tmp/workspace",
    workflowId: "planner-orchestrator",
    debugMode: true,
    archived: false,
    graph: {
      sessionId,
      workflowId: "planner-orchestrator",
      nodes: [
        { id: agentId, roleId: "implementor", label: "Implementor", status, color: "#34c759", unreadCount: 0, errorCount: 0 }
      ],
      edges: [],
      activeToolCalls: []
    },
    transcript: []
  };
}
