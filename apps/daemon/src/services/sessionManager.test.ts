import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { SessionManager } from "./sessionManager.js";

describe("SessionManager deterministic debug sessions", () => {
  it("creates a replayable multiagent debug session", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "multiagent-session-"));
    try {
      const events: string[] = [];
      const manager = new SessionManager({ sessionsRoot: root });
      manager.setPublisher((event) => events.push(event.type));

      const snapshot = await manager.handle({
        id: "req_create",
        method: "createSession",
        params: {
          prompt: "Review and QA this implementation",
          workspaceRoot: root,
          workflowId: "implementor-reviewer",
          debugMode: true
        }
      });

      expect(JSON.stringify(snapshot)).toContain("implementor-reviewer");
      expect(events).toContain("agent.tool_call");
      expect(events).toContain("workspace.file_touched");
      expect(events).toContain("message.sent");
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });
});
