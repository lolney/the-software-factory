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
});
