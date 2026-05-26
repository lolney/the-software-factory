import type { GraphState, SessionEvent, SessionSnapshot } from "@multiagent/shared";

export type ActorStatus = GraphState["nodes"][number]["status"];

export interface ActorState {
  sessionId: string;
  agentId: string;
  roleId?: string;
  status: ActorStatus;
  mailbox: ActorMailbox;
  activeJobIds: string[];
  terminalJobIds: string[];
  lastEventId?: string;
}

export interface ActorMailbox {
  inbound: SessionEvent[];
  outbound: SessionEvent[];
  controls: SessionEvent[];
}

export interface SchedulerJobRecord {
  jobId: string;
  sessionId: string;
  agentId: string;
  kind: string;
  status: "created" | "started" | "heartbeat" | "completed" | "failed" | "recovered" | "retry_requested";
  created?: SessionEvent;
  latest: SessionEvent;
  terminal?: SessionEvent;
  workflowInstanceId?: string;
  workflowId?: string;
  callerAgentId?: string;
}

export interface ScheduledJob {
  jobId: string;
  kind: string;
  createdEventId: string;
  workflowInstanceId?: string;
  workflowId?: string;
  callerAgentId?: string;
  heartbeat: ReturnType<typeof setInterval>;
}

export class ActorRegistry {
  private readonly actors = new Map<string, ActorState>();
  private readonly activeRuns = new Map<string, AbortController>();

  rehydrate(snapshot: SessionSnapshot, events: SessionEvent[]) {
    const next = new Map<string, ActorState>();
    for (const node of snapshot.graph.nodes) {
      const state = deriveActorState(snapshot.sessionId, node.id, node.roleId, node.status, events);
      next.set(actorKey(snapshot.sessionId, node.id), state);
    }
    for (const key of this.actors.keys()) {
      if (key.startsWith(`${snapshot.sessionId}:`)) {
        this.actors.delete(key);
      }
    }
    for (const [key, state] of next) {
      this.actors.set(key, state);
    }
  }

  actor(sessionId: string, agentId: string) {
    return this.actors.get(actorKey(sessionId, agentId));
  }

  canSchedule(sessionId: string, agentId: string, fallbackStatus: ActorStatus = "idle") {
    const actor = this.actor(sessionId, agentId);
    const status = actor?.status ?? fallbackStatus;
    if ((actor?.activeJobIds.length ?? 0) > 0) return false;
    return !["paused", "cancelled", "failed"].includes(status);
  }

  canEmitFrom(sessionId: string, agentId: string, fallbackStatus: ActorStatus = "idle") {
    const actor = this.actor(sessionId, agentId);
    const status = actor?.status ?? fallbackStatus;
    return !["paused", "cancelled", "failed"].includes(status);
  }

  startRun(sessionId: string, agentId: string) {
    const key = actorKey(sessionId, agentId);
    if (this.activeRuns.has(key)) {
      throw new Error(`Actor ${agentId} in session ${sessionId} already has an active run.`);
    }
    const controller = new AbortController();
    this.activeRuns.set(key, controller);
    return controller;
  }

  abortRun(sessionId: string, agentId: string) {
    this.activeRuns.get(actorKey(sessionId, agentId))?.abort();
  }

  finishRun(sessionId: string, agentId: string, controller: AbortController) {
    const key = actorKey(sessionId, agentId);
    if (this.activeRuns.get(key) === controller) {
      this.activeRuns.delete(key);
    }
  }

  hasActiveRun(sessionId: string, agentId: string) {
    return this.activeRuns.has(actorKey(sessionId, agentId));
  }
}

export class SchedulerProjection {
  readonly jobs: Map<string, SchedulerJobRecord>;

  private constructor(jobs: Map<string, SchedulerJobRecord>) {
    this.jobs = jobs;
  }

  static fromEvents(sessionId: string, events: SessionEvent[]) {
    const jobs = new Map<string, SchedulerJobRecord>();
    for (const event of events) {
      if (!isSchedulerEvent(event)) continue;
      const jobId = String(event.payload.jobId ?? "");
      if (!jobId) continue;
      const existing = jobs.get(jobId);
      const status = schedulerStatus(event.type);
      const agentId = event.agentId ?? String(event.payload.agentId ?? "");
      const kind = String(event.payload.kind ?? existing?.kind ?? "");
      const record: SchedulerJobRecord = {
        jobId,
        sessionId,
        agentId,
        kind,
        status,
        created: event.type === "scheduler.job.created" ? event : existing?.created,
        latest: event,
        terminal: ["completed", "failed", "recovered"].includes(status) ? event : existing?.terminal,
        workflowInstanceId: stringPayload(event.payload.workflowInstanceId) ?? existing?.workflowInstanceId,
        workflowId: stringPayload(event.payload.workflowId) ?? existing?.workflowId,
        callerAgentId: stringPayload(event.payload.callerAgentId) ?? existing?.callerAgentId
      };
      jobs.set(jobId, record);
    }
    return new SchedulerProjection(jobs);
  }

  openJobs() {
    return [...this.jobs.values()].filter((job) => !job.terminal);
  }

  terminalJobIds() {
    return new Set([...this.jobs.values()].filter((job) => job.terminal).map((job) => job.jobId));
  }
}

export function deriveActorStates(snapshot: SessionSnapshot, events: SessionEvent[]) {
  return snapshot.graph.nodes.map((node) => deriveActorState(snapshot.sessionId, node.id, node.roleId, node.status, events));
}

function deriveActorState(sessionId: string, agentId: string, roleId: string | undefined, graphStatus: ActorStatus, events: SessionEvent[]): ActorState {
  const scheduler = SchedulerProjection.fromEvents(sessionId, events);
  const agentEvents = events.filter((event) => event.agentId === agentId || event.payload.from === agentId || event.payload.to === agentId);
  const latestStatus = [...events].reverse().find((event) => event.agentId === agentId && event.type === "agent.status")?.payload.status;
  const dequeuedMessageIds = new Set(events
    .filter((event) => event.type === "actor.mailbox.dequeued" && event.payload.mailbox === agentId)
    .map((event) => String(event.payload.messageEventId ?? ""))
    .filter(Boolean));
  const pendingInbound = events.filter((event) =>
    event.type === "actor.mailbox.enqueued"
      && event.payload.mailbox === agentId
      && !dequeuedMessageIds.has(String(event.payload.messageEventId ?? ""))
  );
  const activeJobIds = scheduler.openJobs().filter((job) => job.agentId === agentId).map((job) => job.jobId);
  const terminalJobIds = [...scheduler.jobs.values()]
    .filter((job) => job.agentId === agentId && job.terminal)
    .map((job) => job.jobId);
  return {
    sessionId,
    agentId,
    roleId,
    status: typeof latestStatus === "string" ? latestStatus as ActorStatus : graphStatus,
    mailbox: {
      inbound: pendingInbound,
      outbound: events.filter((event) => event.payload.from === agentId),
      controls: events.filter((event) => event.agentId === agentId && event.type.startsWith("control."))
    },
    activeJobIds,
    terminalJobIds,
    lastEventId: agentEvents.at(-1)?.eventId
  };
}

function actorKey(sessionId: string, agentId: string) {
  return `${sessionId}:${agentId}`;
}

function isSchedulerEvent(event: SessionEvent) {
  return event.type === "scheduler.job.created"
    || event.type === "scheduler.job.started"
    || event.type === "scheduler.job.heartbeat"
    || event.type === "scheduler.job.completed"
    || event.type === "scheduler.job.failed"
    || event.type === "scheduler.job.recovered"
    || event.type === "scheduler.job.retry_requested";
}

function schedulerStatus(type: SessionEvent["type"]): SchedulerJobRecord["status"] {
  switch (type) {
  case "scheduler.job.started": return "started";
  case "scheduler.job.heartbeat": return "heartbeat";
  case "scheduler.job.completed": return "completed";
  case "scheduler.job.failed": return "failed";
  case "scheduler.job.recovered": return "recovered";
  case "scheduler.job.retry_requested": return "retry_requested";
  default: return "created";
  }
}

function stringPayload(value: unknown) {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}
