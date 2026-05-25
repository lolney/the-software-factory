import { describe, expect, it } from "vitest";
import { WorkflowEngine } from "./workflowEngine.js";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

describe("WorkflowEngine", () => {
  it("validates built-in workflows and derives graph state", () => {
    const engine = new WorkflowEngine();
    const spec = engine.get("implementor-reviewer");
    const graph = engine.graphForSession("sess_graph", spec);

    expect(graph.nodes.map((node) => node.id)).toEqual(["orchestrator", "implementor", "reviewer"]);
    expect(graph.edges.some((edge) => edge.kind === "handoff")).toBe(true);
    expect(graph.edges.some((edge) => edge.kind === "message")).toBe(true);
  });

  it("exposes the default role registry including researcher", () => {
    const engine = new WorkflowEngine();
    const roles = engine.listRoles().map((role) => role.name);
    expect(roles).toEqual(expect.arrayContaining([
      "QAer",
      "Adversarial Reviewer",
      "Implementor",
      "Planner",
      "Researcher"
    ]));
  });

  it("allows custom roles to be deleted while protecting built-in roles", () => {
    const engine = new WorkflowEngine();
    engine.upsertRole({
      id: "custom_releaser",
      name: "Release Manager",
      color: "#7f8c8d",
      promptTemplate: "Prepare release notes.",
      model: "gpt-5.4",
      toolPolicy: { canRead: true, canWrite: false, canRunCommands: false, canCreatePlans: false },
      workspace: { allowedRoots: ["."] },
      expectedOutputs: ["Release notes"],
      reviewResponsibilities: []
    });

    expect(engine.listRoles().some((role) => role.id === "custom_releaser")).toBe(true);
    engine.deleteRole("custom_releaser");
    expect(engine.listRoles().some((role) => role.id === "custom_releaser")).toBe(false);
    expect(() => engine.deleteRole("planner")).toThrow("Built-in role planner cannot be deleted.");
  });

  it("defines the requested built-in workflow templates", () => {
    const engine = new WorkflowEngine();
    const workflows = engine.list();
    expect(workflows.map((workflow) => workflow.id)).toEqual(expect.arrayContaining([
      "implementor-qa-loop",
      "implementor-reviewer"
    ]));
    expect(workflows.find((workflow) => workflow.id === "implementor-qa-loop")?.edges).toEqual(expect.arrayContaining([
      expect.objectContaining({ from: "implementor", to: "qa", kind: "handoff" }),
      expect.objectContaining({ from: "qa", to: "implementor", kind: "message" })
    ]));
    expect(workflows.find((workflow) => workflow.id === "implementor-reviewer")?.edges).toEqual(expect.arrayContaining([
      expect.objectContaining({ from: "implementor", to: "reviewer", kind: "message" }),
      expect.objectContaining({ from: "reviewer", to: "implementor", kind: "message" })
    ]));
  });

  it("loads personal roles and workflows from separate JSON directories", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-catalog-"));
    try {
      const engine = new WorkflowEngine(undefined, root);
      const createdRole = await engine.createBlankRoleFile();
      const createdWorkflow = await engine.createBlankWorkflowFile();
      await engine.reloadPersonalCatalog();

      expect(createdRole.path).toBe(path.join(root, "roles", `${createdRole.role.id}.json`));
      expect(createdWorkflow.path).toBe(path.join(root, "workflows", `${createdWorkflow.workflow.id}.json`));
      expect(engine.listRoles().some((role) => role.id === createdRole.role.id)).toBe(true);
      expect(engine.list().some((workflow) => workflow.id === createdWorkflow.workflow.id)).toBe(true);

      const roleJson = JSON.parse(await readFile(createdRole.path, "utf8")) as { name: string; promptTemplate: string };
      const workflowJson = JSON.parse(await readFile(createdWorkflow.path, "utf8")) as { name: string; nodes: unknown[] };
      expect(roleJson.name).toBe("");
      expect(roleJson.promptTemplate).toBe("");
      expect(workflowJson.name).toBe("");
      expect(workflowJson.nodes).toEqual([]);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("allows personal workflows to reference personal roles", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-catalog-"));
    try {
      await mkdir(path.join(root, "roles"), { recursive: true });
      await mkdir(path.join(root, "workflows"), { recursive: true });
      await writeFile(path.join(root, "roles", "custom_builder.json"), JSON.stringify({
        id: "custom_builder",
        name: "Custom Builder",
        color: "#7f8c8d",
        promptTemplate: "Build from a personal role.",
        model: "gpt-5.4",
        toolPolicy: { canRead: true, canWrite: true, canRunCommands: true, canCreatePlans: false },
        workspace: { allowedRoots: ["."] },
        expectedOutputs: [],
        reviewResponsibilities: []
      }), "utf8");
      await writeFile(path.join(root, "workflows", "custom_build.json"), JSON.stringify({
        version: 1,
        id: "custom_build",
        name: "Custom Build",
        description: "",
        roles: [],
        nodes: [
          { id: "orchestrator", roleId: "orchestrator", label: "Orchestrator", startsActive: true },
          { id: "builder", roleId: "custom_builder", label: "Builder" }
        ],
        edges: [
          { id: "handoff-orchestrator-builder", from: "orchestrator", to: "builder", kind: "handoff", description: "" }
        ],
        concurrency: { maxActiveAgents: 2 },
        lifecycle: { orchestratorNodeId: "orchestrator" },
        completionCriteria: [],
        stopCriteria: []
      }), "utf8");

      const engine = new WorkflowEngine(undefined, root);
      await engine.reloadPersonalCatalog();
      const workflow = engine.get("custom_build");
      const graph = engine.graphForSession("sess_custom", workflow);

      expect(graph.nodes.find((node) => node.id === "builder")?.color).toBe("#7f8c8d");
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });
});
