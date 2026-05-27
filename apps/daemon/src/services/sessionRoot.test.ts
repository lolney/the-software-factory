import { afterEach, describe, expect, it } from "vitest";
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { mkdtempSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { defaultSessionsRoot } from "./sessionRoot.js";

const originalRoot = process.env.MULTIAGENT_SESSIONS_ROOT;
const originalDataHome = process.env.XDG_DATA_HOME;
const originalSupportRoot = process.env.SOFTWARE_FACTORY_APP_SUPPORT_ROOT;

afterEach(() => {
  if (originalRoot === undefined) {
    delete process.env.MULTIAGENT_SESSIONS_ROOT;
  } else {
    process.env.MULTIAGENT_SESSIONS_ROOT = originalRoot;
  }
  if (originalDataHome === undefined) {
    delete process.env.XDG_DATA_HOME;
  } else {
    process.env.XDG_DATA_HOME = originalDataHome;
  }
  if (originalSupportRoot === undefined) {
    delete process.env.SOFTWARE_FACTORY_APP_SUPPORT_ROOT;
  } else {
    process.env.SOFTWARE_FACTORY_APP_SUPPORT_ROOT = originalSupportRoot;
  }
});

describe("defaultSessionsRoot", () => {
  it("honors explicit MULTIAGENT_SESSIONS_ROOT", () => {
    process.env.MULTIAGENT_SESSIONS_ROOT = "/tmp/multiagent-sessions";
    expect(defaultSessionsRoot()).toBe("/tmp/multiagent-sessions");
  });

  it("uses Application Support on macOS", () => {
    delete process.env.MULTIAGENT_SESSIONS_ROOT;
    if (process.platform !== "darwin") return;
    expect(defaultSessionsRoot()).toContain(path.join("Library", "Application Support", "The Software Factory", "sessions"));
  });

  it("merges legacy sessions into the renamed application support directory", () => {
    const temp = mkdtempSync(path.join(os.tmpdir(), "software-factory-session-root-"));
    const legacySession = path.join(temp, "MultiAgentDesktop", "sessions", "sess_legacy");
    const nextSessions = path.join(temp, "The Software Factory", "sessions");
    try {
      process.env.SOFTWARE_FACTORY_APP_SUPPORT_ROOT = temp;
      delete process.env.MULTIAGENT_SESSIONS_ROOT;
      mkdirSync(legacySession, { recursive: true });
      mkdirSync(path.join(nextSessions, "sess_existing"), { recursive: true });
      writeFileSync(path.join(legacySession, "events.jsonl"), "{\"type\":\"session.created\"}\n");

      expect(defaultSessionsRoot()).toBe(nextSessions);
      expect(defaultSessionsRoot()).toBe(nextSessions);
      expect(path.join(nextSessions, "sess_legacy", "events.jsonl")).toSatisfy((file: string) => {
        try {
          return readFileSync(file, "utf8").includes("session.created");
        } catch {
          return false;
        }
      });
    } finally {
      rmSync(temp, { recursive: true, force: true });
    }
  });
});
