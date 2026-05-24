import { z } from "zod";

export const AgentStatusSchema = z.enum([
  "idle",
  "working",
  "waiting",
  "paused",
  "cancelled",
  "failed",
  "completed"
]);

export const WorkflowEdgeKindSchema = z.enum(["handoff", "message"]);

export const RoleSpecSchema = z.object({
  id: z.string().min(1),
  name: z.string().min(1),
  color: z.string().regex(/^#[0-9a-fA-F]{6}$/),
  promptTemplate: z.string().min(1),
  model: z.string().default("gpt-5.4"),
  toolPolicy: z.object({
    canRead: z.boolean().default(true),
    canWrite: z.boolean().default(true),
    canRunCommands: z.boolean().default(true)
  }).prefault({}),
  workspace: z.object({
    allowedRoots: z.array(z.string()).default(["."])
  }).prefault({}),
  expectedOutputs: z.array(z.string()).default([]),
  reviewResponsibilities: z.array(z.string()).default([])
});

export const WorkflowNodeSchema = z.object({
  id: z.string().min(1),
  roleId: z.string().min(1),
  label: z.string().min(1),
  startsActive: z.boolean().default(false)
});

export const WorkflowEdgeSchema = z.object({
  id: z.string().min(1),
  from: z.string().min(1),
  to: z.string().min(1),
  kind: WorkflowEdgeKindSchema,
  description: z.string().default("")
});

export const WorkflowSpecSchema = z.object({
  version: z.literal(1),
  id: z.string().min(1),
  name: z.string().min(1),
  description: z.string().default(""),
  roles: z.array(RoleSpecSchema).min(1),
  nodes: z.array(WorkflowNodeSchema).min(1),
  edges: z.array(WorkflowEdgeSchema).default([]),
  concurrency: z.object({
    maxActiveAgents: z.number().int().positive().default(4)
  }).prefault({}),
  lifecycle: z.object({
    plannerNodeId: z.string().optional(),
    orchestratorNodeId: z.string().min(1)
  }),
  stopCriteria: z.array(z.string()).default([])
});

export const SessionEventTypeSchema = z.enum([
  "session.created",
  "session.snapshot",
  "agent.created",
  "agent.status",
  "agent.message",
  "agent.tool_call",
  "agent.tool_result",
  "agent.reasoning",
  "handoff.created",
  "message.sent",
  "workspace.file_claimed",
  "workspace.file_touched",
  "workspace.conflict_detected",
  "control.pause",
  "control.resume",
  "control.cancel",
  "control.nudge",
  "error"
]);

export const SessionEventSchema = z.object({
  eventId: z.string().min(1),
  sessionId: z.string().min(1),
  agentId: z.string().min(1).optional(),
  timestamp: z.string().datetime(),
  type: SessionEventTypeSchema,
  payload: z.record(z.string(), z.unknown()).default({}),
  causationId: z.string().optional(),
  correlationId: z.string().optional()
});

export const GraphNodeSchema = z.object({
  id: z.string(),
  roleId: z.string(),
  label: z.string(),
  status: AgentStatusSchema,
  color: z.string(),
  unreadCount: z.number().int().nonnegative().default(0),
  errorCount: z.number().int().nonnegative().default(0)
});

export const GraphEdgeSchema = z.object({
  id: z.string(),
  from: z.string(),
  to: z.string(),
  kind: WorkflowEdgeKindSchema,
  active: z.boolean().default(false)
});

export const GraphStateSchema = z.object({
  sessionId: z.string(),
  workflowId: z.string(),
  nodes: z.array(GraphNodeSchema),
  edges: z.array(GraphEdgeSchema),
  activeToolCalls: z.array(z.object({
    agentId: z.string(),
    toolName: z.string(),
    callId: z.string()
  })).default([])
});

export const SessionSnapshotSchema = z.object({
  sessionId: z.string(),
  title: z.string(),
  createdAt: z.string().datetime(),
  updatedAt: z.string().datetime(),
  workspaceRoot: z.string(),
  workflowId: z.string(),
  graph: GraphStateSchema,
  transcript: z.array(SessionEventSchema)
});

export const DaemonRequestSchema = z.discriminatedUnion("method", [
  z.object({ id: z.string(), method: z.literal("createSession"), params: z.object({ prompt: z.string(), workspaceRoot: z.string().optional(), workflowId: z.string().optional() }) }),
  z.object({ id: z.string(), method: z.literal("sendMessage"), params: z.object({ sessionId: z.string(), targetAgentId: z.string().optional(), text: z.string() }) }),
  z.object({ id: z.string(), method: z.literal("pauseAgent"), params: z.object({ sessionId: z.string(), agentId: z.string() }) }),
  z.object({ id: z.string(), method: z.literal("resumeAgent"), params: z.object({ sessionId: z.string(), agentId: z.string() }) }),
  z.object({ id: z.string(), method: z.literal("cancelAgent"), params: z.object({ sessionId: z.string(), agentId: z.string() }) }),
  z.object({ id: z.string(), method: z.literal("getSnapshot"), params: z.object({ sessionId: z.string() }) }),
  z.object({ id: z.string(), method: z.literal("listSessions"), params: z.object({}).default({}) }),
  z.object({ id: z.string(), method: z.literal("subscribeEvents"), params: z.object({ sessionId: z.string() }) }),
  z.object({ id: z.string(), method: z.literal("ackClientEvent"), params: z.object({ sessionId: z.string(), eventId: z.string() }) })
]);

export const DaemonResponseSchema = z.object({
  id: z.string(),
  ok: z.boolean(),
  result: z.unknown().optional(),
  error: z.object({
    code: z.string(),
    message: z.string()
  }).optional()
});

export const DaemonNotificationSchema = z.object({
  method: z.literal("event"),
  params: SessionEventSchema
});

export type AgentStatus = z.infer<typeof AgentStatusSchema>;
export type WorkflowEdgeKind = z.infer<typeof WorkflowEdgeKindSchema>;
export type RoleSpec = z.infer<typeof RoleSpecSchema>;
export type WorkflowSpec = z.infer<typeof WorkflowSpecSchema>;
export type SessionEvent = z.infer<typeof SessionEventSchema>;
export type GraphState = z.infer<typeof GraphStateSchema>;
export type SessionSnapshot = z.infer<typeof SessionSnapshotSchema>;
export type DaemonRequest = z.infer<typeof DaemonRequestSchema>;
export type DaemonResponse = z.infer<typeof DaemonResponseSchema>;
