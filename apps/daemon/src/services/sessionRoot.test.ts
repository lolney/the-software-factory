import { afterEach, describe, expect, it } from "vitest";
import path from "node:path";
import { defaultSessionsRoot } from "./sessionRoot.js";

const originalRoot = process.env.MULTIAGENT_SESSIONS_ROOT;
const originalDataHome = process.env.XDG_DATA_HOME;

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
});

describe("defaultSessionsRoot", () => {
  it("honors explicit MULTIAGENT_SESSIONS_ROOT", () => {
    process.env.MULTIAGENT_SESSIONS_ROOT = "/tmp/multiagent-sessions";
    expect(defaultSessionsRoot()).toBe("/tmp/multiagent-sessions");
  });

  it("uses Application Support on macOS", () => {
    delete process.env.MULTIAGENT_SESSIONS_ROOT;
    if (process.platform !== "darwin") return;
    expect(defaultSessionsRoot()).toContain(path.join("Library", "Application Support", "MultiAgentDesktop", "sessions"));
  });
});
