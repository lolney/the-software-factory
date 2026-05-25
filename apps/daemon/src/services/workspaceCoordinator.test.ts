import { describe, expect, it } from "vitest";
import { WorkspaceCoordinator, type WorkspacePolicy } from "./workspaceCoordinator.js";

describe("WorkspaceCoordinator", () => {
  const policy: WorkspacePolicy = {
    sessionId: "sess_workspace",
    workspaceRoot: "/tmp/project",
    allowedRoots: ["."]
  };

  it("blocks paths outside the workspace root", () => {
    const coordinator = new WorkspaceCoordinator();
    expect(() => coordinator.assertAllowed(policy, "../outside.txt")).toThrow(/outside allowed workspace/);
  });

  it("records file claims and detects cross-agent conflicts", () => {
    const coordinator = new WorkspaceCoordinator();

    const first = coordinator.claimFile(policy, "implementor", "src/app.ts");
    const second = coordinator.claimFile(policy, "reviewer", "src/app.ts");

    expect(first.type).toBe("workspace.file_claimed");
    expect(second.type).toBe("workspace.conflict_detected");
    expect(second.payload.ownerAgentId).toBe("implementor");
  });

  it("reconstructs file leases and touched files from durable events", () => {
    const coordinator = new WorkspaceCoordinator();
    const first = coordinator.claimFile(policy, "implementor", "src/app.ts");
    const touched = coordinator.recordTouched(policy, "implementor", "src/app.ts");
    const restarted = new WorkspaceCoordinator();

    restarted.reconstructLeases(policy.sessionId, [first, touched]);
    const conflict = restarted.claimFile(policy, "reviewer", "src/app.ts");

    expect(conflict.type).toBe("workspace.conflict_detected");
    expect(conflict.payload.ownerAgentId).toBe("implementor");
    expect(restarted.touchedFiles(policy.sessionId, "implementor")).toEqual([String(touched.payload.path)]);
  });

  it("attributes touched files to the writing agent", () => {
    const coordinator = new WorkspaceCoordinator();
    const event = coordinator.recordTouched(policy, "implementor", "src/app.ts");

    expect(event.type).toBe("workspace.file_touched");
    expect(coordinator.touchedFiles(policy.sessionId, "implementor")).toHaveLength(1);
  });
});
