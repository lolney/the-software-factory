import { readFile, readdir } from "node:fs/promises";
import { existsSync } from "node:fs";
import path from "node:path";
import YAML from "yaml";
import { GraphStateSchema, RoleSpecSchema, WorkflowSpecSchema, type GraphState, type RoleSpec, type WorkflowSpec } from "@multiagent/shared";

export class WorkflowEngine {
  private specs = new Map<string, WorkflowSpec>();
  private roleOverrides = new Map<string, RoleSpec>();
  private loaded = false;

  constructor(private readonly workflowDir = path.join(process.cwd(), "apps/daemon/src/workflows")) {
    for (const spec of builtInWorkflows) {
      this.specs.set(spec.id, WorkflowSpecSchema.parse(spec));
    }
  }

  async loadPredefined() {
    if (this.loaded) return;
    this.loaded = true;
    if (!existsSync(this.workflowDir)) return;
    const entries = await readdir(this.workflowDir, { withFileTypes: true });
    for (const entry of entries) {
      if (!entry.isFile() || !/\.(json|ya?ml)$/.test(entry.name)) continue;
      const raw = await readFile(path.join(this.workflowDir, entry.name), "utf8");
      const parsed = entry.name.endsWith(".json") ? JSON.parse(raw) : YAML.parse(raw);
      const spec = WorkflowSpecSchema.parse(parsed);
      this.specs.set(spec.id, spec);
    }
  }

  validate(spec: unknown) {
    const parsed = WorkflowSpecSchema.parse(spec);
    assertGraphReferences(parsed);
    return parsed;
  }

  get(id = "planner-orchestrator") {
    const spec = this.specs.get(id);
    if (!spec) {
      throw new Error(`Unknown workflow spec: ${id}`);
    }
    return this.validate(this.withRoleOverrides(spec));
  }

  list() {
    return [...this.specs.values()].map((spec) => this.withRoleOverrides(spec));
  }

  listRoles() {
    const roles = new Map<string, RoleSpec>();
    for (const spec of this.specs.values()) {
      for (const role of spec.roles) {
        roles.set(role.id, enforceRoleCapabilities(this.roleOverrides.get(role.id) ?? role));
      }
    }
    for (const [id, role] of this.roleOverrides) {
      roles.set(id, enforceRoleCapabilities(role));
    }
    return [...roles.values()].sort((a, b) => a.name.localeCompare(b.name));
  }

  upsertRole(role: RoleSpec) {
    const parsed = RoleSpecSchema.parse(role);
    if (parsed.id === "orchestrator" || parsed.id === "planner") {
      this.roleOverrides.set(parsed.id, enforceRoleCapabilities(parsed));
      return enforceRoleCapabilities(parsed);
    }
    this.roleOverrides.set(parsed.id, parsed);
    return parsed;
  }

  deleteRole(roleId: string) {
    if (baseRoleIds.has(roleId)) {
      throw new Error(`Built-in role ${roleId} cannot be deleted.`);
    }
    this.roleOverrides.delete(roleId);
  }

  setRoleOverrides(roles: RoleSpec[]) {
    this.roleOverrides.clear();
    for (const role of roles) {
      this.upsertRole(role);
    }
  }

  graphForSession(sessionId: string, spec: WorkflowSpec): GraphState {
    const rolesById = new Map(spec.roles.map((role) => [role.id, role]));
    return GraphStateSchema.parse({
      sessionId,
      workflowId: spec.id,
      nodes: spec.nodes.map((node) => {
        const role = rolesById.get(node.roleId);
        if (!role) throw new Error(`Node ${node.id} references missing role ${node.roleId}`);
        return {
          id: node.id,
          roleId: node.roleId,
          label: node.label,
          status: node.startsActive ? "working" : "idle",
          color: role.color,
          unreadCount: 0,
          errorCount: 0
        };
      }),
      edges: spec.edges.map((edge) => ({
        id: edge.id,
        from: edge.from,
        to: edge.to,
        kind: edge.kind,
        active: false
      })),
      activeToolCalls: []
    });
  }

  roleForNode(spec: WorkflowSpec, nodeId: string) {
    const node = spec.nodes.find((candidate) => candidate.id === nodeId);
    if (!node) return undefined;
    return spec.roles.find((role) => role.id === node.roleId);
  }

  roleById(roleId: string) {
    return this.listRoles().find((role) => role.id === roleId);
  }

  private withRoleOverrides(spec: WorkflowSpec): WorkflowSpec {
    return {
      ...spec,
      roles: spec.roles.map((role) => enforceRoleCapabilities(this.roleOverrides.get(role.id) ?? role))
    };
  }
}

function enforceRoleCapabilities(role: RoleSpec): RoleSpec {
  if (role.id === "orchestrator") {
    return {
      ...role,
      toolPolicy: {
        ...role.toolPolicy,
        canRead: true,
        canWrite: false,
        canRunCommands: false,
        canCreatePlans: false
      }
    };
  }
  if (role.id === "planner") {
    return {
      ...role,
      toolPolicy: {
        ...role.toolPolicy,
        canCreatePlans: true,
        canWrite: false,
        canRunCommands: false
      }
    };
  }
  return role;
}

function assertGraphReferences(spec: WorkflowSpec) {
  const roleIds = new Set(spec.roles.map((role) => role.id));
  const nodeIds = new Set(spec.nodes.map((node) => node.id));
  if (!nodeIds.has(spec.lifecycle.orchestratorNodeId)) {
    throw new Error(`Workflow ${spec.id} lifecycle references missing orchestrator node ${spec.lifecycle.orchestratorNodeId}`);
  }
  for (const node of spec.nodes) {
    if (!roleIds.has(node.roleId)) {
      throw new Error(`Node ${node.id} references missing role ${node.roleId}`);
    }
  }
  for (const edge of spec.edges) {
    if (!nodeIds.has(edge.from) || !nodeIds.has(edge.to)) {
      throw new Error(`Edge ${edge.id} references a missing node.`);
    }
  }
}

const baseRoles: WorkflowSpec["roles"] = [
  {
    id: "orchestrator",
    name: "Orchestrator",
    color: "#4f7cff",
    promptTemplate: [
      "Coordinate the session without directly modifying files or creating plans.",
      "You may instantiate planner-created plans, inspect agent state, read workspace files, and send messages to agents.",
      "All implementation must happen through implementor, reviewer, QA, researcher, or other workflow agents."
    ].join(" "),
    model: "gpt-5.4",
    toolPolicy: { canRead: true, canWrite: false, canRunCommands: false, canCreatePlans: false },
    workspace: { allowedRoots: ["."] },
    expectedOutputs: ["Instantiated plan", "Agent coordination summary", "Durable transcript"],
    reviewResponsibilities: []
  },
  {
    id: "planner",
    name: "Planner",
    color: "#9b51e0",
    promptTemplate: "Create a decision-complete plan: one or more workflows, agent prompts, and done criteria for each participating agent.",
    model: "gpt-5.4",
    toolPolicy: { canRead: true, canWrite: false, canRunCommands: false, canCreatePlans: true },
    workspace: { allowedRoots: ["."] },
    expectedOutputs: ["PlanSpec"],
    reviewResponsibilities: []
  },
  {
    id: "implementor",
    name: "Implementor",
    color: "#27ae60",
    promptTemplate: "Implement scoped code changes inside the session workspace.",
    model: "gpt-5.4",
    toolPolicy: { canRead: true, canWrite: true, canRunCommands: true, canCreatePlans: false },
    workspace: { allowedRoots: ["."] },
    expectedOutputs: ["Code changes", "Implementation notes"],
    reviewResponsibilities: []
  },
  {
    id: "reviewer",
    name: "Adversarial Reviewer",
    color: "#f2994a",
    promptTemplate: "Review implementation transcript and diffs, then send concise findings.",
    model: "gpt-5.4",
    toolPolicy: { canRead: true, canWrite: false, canRunCommands: true, canCreatePlans: false },
    workspace: { allowedRoots: ["."] },
    expectedOutputs: ["Review findings"],
    reviewResponsibilities: ["Correctness", "Regression risk", "Missing tests"]
  },
  {
    id: "qa",
    name: "QAer",
    color: "#eb5757",
    promptTemplate: "Run acceptance checks and decide whether to hand back issues.",
    model: "gpt-5.4",
    toolPolicy: { canRead: true, canWrite: false, canRunCommands: true, canCreatePlans: false },
    workspace: { allowedRoots: ["."] },
    expectedOutputs: ["Acceptance result"],
    reviewResponsibilities: ["Build", "Tests", "Manual QA"]
  },
  {
    id: "researcher",
    name: "Researcher",
    color: "#56ccf2",
    promptTemplate: "Research technical context, APIs, libraries, and project constraints before implementation.",
    model: "gpt-5.4",
    toolPolicy: { canRead: true, canWrite: false, canRunCommands: true, canCreatePlans: false },
    workspace: { allowedRoots: ["."] },
    expectedOutputs: ["Research notes", "Cited implementation context"],
    reviewResponsibilities: ["External context", "API correctness", "Dependency risk"]
  }
];

const baseRoleIds = new Set(baseRoles.map((role) => role.id));

const builtInWorkflows: WorkflowSpec[] = [
  {
    version: 1,
    id: "planner-orchestrator",
    name: "Planner to Orchestrator",
    description: "Planner proposes a graph, then the orchestrator launches and supervises it.",
    roles: baseRoles,
    nodes: [
      { id: "orchestrator", roleId: "orchestrator", label: "Orchestrator", startsActive: true },
      { id: "planner", roleId: "planner", label: "Planner", startsActive: false }
    ],
    edges: [
      { id: "handoff-orchestrator-planner", from: "orchestrator", to: "planner", kind: "handoff", description: "Ask planner for workflow details." },
      { id: "message-planner-orchestrator", from: "planner", to: "orchestrator", kind: "message", description: "Return proposed workflow." }
    ],
    concurrency: { maxActiveAgents: 2 },
    lifecycle: { plannerNodeId: "planner", orchestratorNodeId: "orchestrator" },
    stopCriteria: ["Orchestrator marks the user goal completed."]
  },
  {
    version: 1,
    id: "implementor-reviewer",
    name: "Implementor and Reviewer Parallel",
    description: "Implementor edits while reviewer continuously inspects transcript and diffs.",
    roles: baseRoles,
    nodes: [
      { id: "orchestrator", roleId: "orchestrator", label: "Orchestrator", startsActive: true },
      { id: "implementor", roleId: "implementor", label: "Implementor", startsActive: false },
      { id: "reviewer", roleId: "reviewer", label: "Reviewer", startsActive: false }
    ],
    edges: [
      { id: "handoff-orchestrator-implementor", from: "orchestrator", to: "implementor", kind: "handoff", description: "Assign implementation." },
      { id: "message-reviewer-implementor", from: "reviewer", to: "implementor", kind: "message", description: "Send review findings." },
      { id: "message-implementor-reviewer", from: "implementor", to: "reviewer", kind: "message", description: "Share diffs for review." }
    ],
    concurrency: { maxActiveAgents: 3 },
    lifecycle: { orchestratorNodeId: "orchestrator" },
    stopCriteria: ["Reviewer reports no blocking findings.", "Orchestrator accepts final implementation."]
  },
  {
    version: 1,
    id: "implementor-qa-loop",
    name: "Implementor QA Loop",
    description: "QA runs checks and hands back issues until acceptance.",
    roles: baseRoles,
    nodes: [
      { id: "orchestrator", roleId: "orchestrator", label: "Orchestrator", startsActive: true },
      { id: "implementor", roleId: "implementor", label: "Implementor", startsActive: false },
      { id: "qa", roleId: "qa", label: "QA", startsActive: false }
    ],
    edges: [
      { id: "handoff-orchestrator-implementor", from: "orchestrator", to: "implementor", kind: "handoff", description: "Assign implementation." },
      { id: "handoff-implementor-qa", from: "implementor", to: "qa", kind: "handoff", description: "Request QA." },
      { id: "message-qa-implementor", from: "qa", to: "implementor", kind: "message", description: "Return issues or acceptance." }
    ],
    concurrency: { maxActiveAgents: 2 },
    lifecycle: { orchestratorNodeId: "orchestrator" },
    stopCriteria: ["QA marks acceptance.", "Orchestrator summarizes completion."]
  },
  {
    version: 1,
    id: "implementation-review-qa",
    name: "Implementation Review QA",
    description: "Implementor builds, reviewer critiques, implementor revises, and QA verifies acceptance.",
    roles: baseRoles,
    nodes: [
      { id: "orchestrator", roleId: "orchestrator", label: "Orchestrator", startsActive: true },
      { id: "implementor", roleId: "implementor", label: "Implementor", startsActive: false },
      { id: "reviewer", roleId: "reviewer", label: "Reviewer", startsActive: false },
      { id: "qa", roleId: "qa", label: "QA", startsActive: false }
    ],
    edges: [
      { id: "handoff-orchestrator-implementor", from: "orchestrator", to: "implementor", kind: "handoff", description: "Assign scoped implementation from the active plan." },
      { id: "message-implementor-reviewer", from: "implementor", to: "reviewer", kind: "message", description: "Share implementation notes and touched files." },
      { id: "message-reviewer-implementor", from: "reviewer", to: "implementor", kind: "message", description: "Return blocking review findings or approval." },
      { id: "handoff-implementor-qa", from: "implementor", to: "qa", kind: "handoff", description: "Request acceptance checks after implementation and review." },
      { id: "message-qa-implementor", from: "qa", to: "implementor", kind: "message", description: "Return acceptance result or issues." }
    ],
    concurrency: { maxActiveAgents: 3 },
    lifecycle: { orchestratorNodeId: "orchestrator" },
    stopCriteria: ["Implementation matches the plan.", "Reviewer has no blocking findings.", "QA acceptance checks pass."]
  }
];
