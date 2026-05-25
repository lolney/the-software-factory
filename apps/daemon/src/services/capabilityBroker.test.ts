import { describe, expect, it } from "vitest";
import { CapabilityBroker } from "./capabilityBroker.js";

const role = {
  id: "reviewer",
  name: "Reviewer",
  color: "#f2994a",
  promptTemplate: "",
  model: "gpt-5.4",
  toolPolicy: { canRead: true, canWrite: false, canRunCommands: true, canCreatePlans: false },
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
});
