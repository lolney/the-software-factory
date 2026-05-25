import { z } from "zod";

export const SafeIdSchema = z.string().regex(/^[A-Za-z0-9_-]+$/);

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

export const CompletionCriterionSchema = z.object({
  id: SafeIdSchema,
  description: z.string().min(1),
  ownerNodeId: SafeIdSchema.optional(),
  required: z.boolean().default(true)
});

export const RoleSpecSchema = z.object({
  id: SafeIdSchema,
  name: z.string(),
  color: z.string().regex(/^#[0-9a-fA-F]{6}$/),
  promptTemplate: z.string(),
  model: z.string().default("gpt-5.4"),
  toolPolicy: z.object({
    canRead: z.boolean().default(true),
    canWrite: z.boolean().default(true),
    canRunCommands: z.boolean().default(true),
    canCreatePlans: z.boolean().default(false)
  }).prefault({}),
  workspace: z.object({
    allowedRoots: z.array(z.string()).default(["."])
  }).prefault({}),
  expectedOutputs: z.array(z.string()).default([]),
  reviewResponsibilities: z.array(z.string()).default([])
});

export const WorkflowNodeSchema = z.object({
  id: SafeIdSchema,
  roleId: SafeIdSchema,
  label: z.string().min(1),
  startsActive: z.boolean().default(false),
  dependencies: z.array(SafeIdSchema).default([])
});

export const WorkflowEdgeSchema = z.object({
  id: SafeIdSchema,
  from: SafeIdSchema,
  to: SafeIdSchema,
  kind: WorkflowEdgeKindSchema,
  description: z.string().default("")
});

export const WorkflowSpecSchema = z.object({
  version: z.literal(1),
  id: SafeIdSchema,
  name: z.string(),
  description: z.string().default(""),
  roles: z.array(RoleSpecSchema).default([]),
  nodes: z.array(WorkflowNodeSchema).default([]),
  edges: z.array(WorkflowEdgeSchema).default([]),
  concurrency: z.object({
    maxActiveAgents: z.number().int().positive().default(4)
  }).prefault({}),
  lifecycle: z.object({
    plannerNodeId: SafeIdSchema.optional(),
    orchestratorNodeId: SafeIdSchema
  }),
  completionCriteria: z.array(CompletionCriterionSchema).default([]),
  stopCriteria: z.array(z.string()).default([])
});

export const PlanWorkflowSchema = z.object({
  workflowId: SafeIdSchema,
  anchorNodeId: SafeIdSchema.optional(),
  agentPrompts: z.record(SafeIdSchema, z.string()).default({}),
  doneCriteria: z.record(SafeIdSchema, z.array(z.string())).default({}),
  completionCriteria: z.record(SafeIdSchema, z.array(CompletionCriterionSchema)).default({})
});

export const PlanSpecSchema = z.object({
  version: z.literal(1),
  id: SafeIdSchema,
  name: z.string().min(1),
  description: z.string().default(""),
  goal: z.string().min(1),
  workflows: z.array(PlanWorkflowSchema).min(1),
  globalDoneCriteria: z.array(z.string()).default([])
});

export const SessionEventTypeSchema = z.enum([
  "session.created",
  "session.archived",
  "session.restored",
  "session.snapshot",
  "scheduler.job.created",
  "scheduler.job.started",
  "scheduler.job.heartbeat",
  "scheduler.job.completed",
  "scheduler.job.failed",
  "scheduler.job.recovered",
  "plan.created",
  "plan.instantiated",
  "graph.updated",
  "workflow.instantiated",
  "workflow.completed",
  "workflow.stopped",
  "completion.criterion.updated",
  "agent.created",
  "agent.status",
  "agent.stopped",
  "agent.stop_blocked",
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
  "client.ack",
  "error"
]);

export const SessionEventSchema = z.object({
  eventId: SafeIdSchema,
  sessionId: SafeIdSchema,
  agentId: SafeIdSchema.optional(),
  timestamp: z.string().datetime(),
  type: SessionEventTypeSchema,
  payload: z.record(z.string(), z.unknown()).default({}),
  causationId: z.string().optional(),
  correlationId: z.string().optional()
});

export const DebugLogLevelSchema = z.enum(["debug", "info", "warn", "error"]);

export const DebugLogEntrySchema = z.object({
  logId: SafeIdSchema,
  sessionId: SafeIdSchema,
  timestamp: z.string().datetime(),
  level: DebugLogLevelSchema,
  source: z.string().default("daemon"),
  agentId: SafeIdSchema.optional(),
  message: z.string(),
  payload: z.record(z.string(), z.unknown()).default({}),
  causationId: z.string().optional(),
  correlationId: z.string().optional()
});

export const MCPServerCatalogItemSchema = z.object({
  id: SafeIdSchema,
  name: z.string(),
  transport: z.enum(["stdio", "streamable_http", "sse", "unknown"]),
  command: z.string().optional(),
  args: z.array(z.string()).default([]),
  url: z.string().optional(),
  authenticationSupported: z.boolean().default(false),
  authStatus: z.enum(["not_supported", "supported_unknown", "connected", "failed"]).default("not_supported"),
  authUrl: z.string().optional(),
  authInstructions: z.string().optional(),
  status: z.enum(["configured", "connected", "failed"]).default("configured"),
  error: z.string().optional()
});

export const SkillCatalogItemSchema = z.object({
  id: SafeIdSchema,
  name: z.string(),
  description: z.string().default(""),
  path: z.string(),
  source: z.string().default("codex")
});

export const GraphNodeSchema = z.object({
  id: SafeIdSchema,
  roleId: SafeIdSchema,
  label: z.string(),
  status: AgentStatusSchema,
  color: z.string(),
  unreadCount: z.number().int().nonnegative().default(0),
  errorCount: z.number().int().nonnegative().default(0)
});

export const GraphEdgeSchema = z.object({
  id: SafeIdSchema,
  from: SafeIdSchema,
  to: SafeIdSchema,
  kind: WorkflowEdgeKindSchema,
  active: z.boolean().default(false)
});

export const GraphStateSchema = z.object({
  sessionId: SafeIdSchema,
  workflowId: SafeIdSchema,
  nodes: z.array(GraphNodeSchema),
  edges: z.array(GraphEdgeSchema),
  activeToolCalls: z.array(z.object({
    agentId: SafeIdSchema,
    toolName: z.string(),
    callId: z.string()
  })).default([])
});

export const SessionSnapshotSchema = z.object({
  sessionId: SafeIdSchema,
  title: z.string(),
  createdAt: z.string().datetime(),
  updatedAt: z.string().datetime(),
  workspaceRoot: z.string(),
  workflowId: SafeIdSchema,
  debugMode: z.boolean().default(false),
  archived: z.boolean().default(false),
  model: z.string().optional(),
  reasoningEffort: z.enum(["none", "minimal", "low", "medium", "high", "xhigh"]).optional(),
  graph: GraphStateSchema,
  transcript: z.array(SessionEventSchema)
});

export const DaemonRequestSchema = z.discriminatedUnion("method", [
  z.object({ id: z.string(), method: z.literal("createSession"), params: z.object({
    prompt: z.string(),
    workspaceRoot: z.string().optional(),
    workflowId: SafeIdSchema.optional(),
    debugMode: z.boolean().default(false),
    model: z.string().optional(),
    reasoningEffort: z.enum(["none", "minimal", "low", "medium", "high", "xhigh"]).optional()
  }) }),
  z.object({ id: z.string(), method: z.literal("sendMessage"), params: z.object({ sessionId: SafeIdSchema, targetAgentId: SafeIdSchema.optional(), text: z.string() }) }),
  z.object({ id: z.string(), method: z.literal("pauseAgent"), params: z.object({ sessionId: SafeIdSchema, agentId: SafeIdSchema }) }),
  z.object({ id: z.string(), method: z.literal("resumeAgent"), params: z.object({ sessionId: SafeIdSchema, agentId: SafeIdSchema }) }),
  z.object({ id: z.string(), method: z.literal("cancelAgent"), params: z.object({ sessionId: SafeIdSchema, agentId: SafeIdSchema }) }),
  z.object({ id: z.string(), method: z.literal("getSnapshot"), params: z.object({ sessionId: SafeIdSchema }) }),
  z.object({ id: z.string(), method: z.literal("listSessions"), params: z.object({ includeArchived: z.boolean().optional() }).default({}) }),
  z.object({ id: z.string(), method: z.literal("archiveSessions"), params: z.object({ sessionIds: z.array(SafeIdSchema).min(1), archived: z.boolean().default(true) }) }),
  z.object({ id: z.string(), method: z.literal("subscribeEvents"), params: z.object({ sessionId: SafeIdSchema }) }),
  z.object({ id: z.string(), method: z.literal("subscribeDebugLogs"), params: z.object({ sessionId: SafeIdSchema }) }),
  z.object({ id: z.string(), method: z.literal("ackClientEvent"), params: z.object({ sessionId: SafeIdSchema, eventId: SafeIdSchema }) }),
  z.object({ id: z.string(), method: z.literal("getAuthStatus"), params: z.object({}).default({}) }),
  z.object({ id: z.string(), method: z.literal("beginOpenAIOAuth"), params: z.object({ port: z.number().int().positive().optional() }).default({}) }),
  z.object({ id: z.string(), method: z.literal("disconnectOpenAIOAuth"), params: z.object({}).default({}) }),
  z.object({ id: z.string(), method: z.literal("setChatGPTAccountId"), params: z.object({ accountId: z.string().min(1) }) }),
  z.object({ id: z.string(), method: z.literal("disconnectChatGPTAccountId"), params: z.object({}).default({}) }),
  z.object({ id: z.string(), method: z.literal("setOpenAIAPIKey"), params: z.object({ apiKey: z.string().min(1) }) }),
  z.object({ id: z.string(), method: z.literal("disconnectOpenAIAPIKey"), params: z.object({}).default({}) }),
  z.object({ id: z.string(), method: z.literal("listRoles"), params: z.object({}).default({}) }),
  z.object({ id: z.string(), method: z.literal("upsertRole"), params: z.object({ role: RoleSpecSchema }) }),
  z.object({ id: z.string(), method: z.literal("deleteRole"), params: z.object({ roleId: SafeIdSchema }) }),
  z.object({ id: z.string(), method: z.literal("listWorkflows"), params: z.object({}).default({}) }),
  z.object({ id: z.string(), method: z.literal("createRoleFile"), params: z.object({}).default({}) }),
  z.object({ id: z.string(), method: z.literal("createWorkflowFile"), params: z.object({}).default({}) }),
  z.object({ id: z.string(), method: z.literal("listIntegrations"), params: z.object({}).default({}) }),
  z.object({ id: z.string(), method: z.literal("beginMCPAuth"), params: z.object({ serverId: SafeIdSchema }) }),
  z.object({ id: z.string(), method: z.literal("reconnectMCPServers"), params: z.object({ serverId: SafeIdSchema.optional() }).default({}) }),
  z.object({ id: z.string(), method: z.literal("instantiateWorkflow"), params: z.object({ sessionId: SafeIdSchema, workflowId: SafeIdSchema, anchorNodeId: SafeIdSchema.optional() }) })
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

export const DaemonDebugLogNotificationSchema = z.object({
  method: z.literal("debugLog"),
  params: DebugLogEntrySchema
});

export type AgentStatus = z.infer<typeof AgentStatusSchema>;
export type WorkflowEdgeKind = z.infer<typeof WorkflowEdgeKindSchema>;
export type CompletionCriterion = z.infer<typeof CompletionCriterionSchema>;
export type RoleSpec = z.infer<typeof RoleSpecSchema>;
export type WorkflowSpec = z.infer<typeof WorkflowSpecSchema>;
export type PlanSpec = z.infer<typeof PlanSpecSchema>;
export type SessionEvent = z.infer<typeof SessionEventSchema>;
export type DebugLogLevel = z.infer<typeof DebugLogLevelSchema>;
export type DebugLogEntry = z.infer<typeof DebugLogEntrySchema>;
export type MCPServerCatalogItem = z.infer<typeof MCPServerCatalogItemSchema>;
export type SkillCatalogItem = z.infer<typeof SkillCatalogItemSchema>;
export type GraphState = z.infer<typeof GraphStateSchema>;
export type SessionSnapshot = z.infer<typeof SessionSnapshotSchema>;
export type DaemonRequest = z.infer<typeof DaemonRequestSchema>;
export type DaemonResponse = z.infer<typeof DaemonResponseSchema>;
