import { describe, expect, it } from "vitest";
import { CapabilityBroker } from "./capabilityBroker.js";

const role = {
  id: "reviewer",
  name: "Reviewer",
  color: "#f2994a",
  promptTemplate: "",
  model: "gpt-5.4",
  toolPolicy: { canRead: true, canWrite: false, canRunCommands: true, canCreatePlans: false, canUseMCP: true },
  workspace: { allowedRoots: ["."] },
  expectedOutputs: [],
  reviewResponsibilities: []
};

describe("CapabilityBroker", () => {
  it("audits allow and deny decisions from role policy", () => {
    const broker = new CapabilityBroker();
    const read = broker.check({ sessionId: "sess_test", agentId: "reviewer", role, action: "workspace.read" });
    const write = broker.check({ sessionId: "sess_test", agentId: "reviewer", role, action: "workspace.write" });

    expect(read.allowed).toBe(true);
    expect(read.event.type).toBe("capability.checked");
    expect(read.event.payload).toMatchObject({ action: "workspace.read", allowed: true, roleId: "reviewer" });
    expect(write.allowed).toBe(false);
    expect(write.event.payload).toMatchObject({ action: "workspace.write", allowed: false, roleId: "reviewer" });
  });

  it("allows MCP independently from write access", () => {
    const broker = new CapabilityBroker();
    const mcp = broker.check({ sessionId: "sess_test", agentId: "reviewer", role, action: "mcp.use" });

    expect(mcp.allowed).toBe(true);
    expect(mcp.event.payload).toMatchObject({ action: "mcp.use", allowed: true, roleId: "reviewer" });
  });
});
