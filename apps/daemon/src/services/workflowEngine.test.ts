import { describe, expect, it } from "vitest";
import { WorkflowEngine } from "./workflowEngine.js";

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
});
