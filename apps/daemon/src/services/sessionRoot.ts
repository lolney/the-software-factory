import os from "node:os";
import path from "node:path";
import { existsSync } from "node:fs";

const appSupportName = "The Software Factory";
const legacyAppSupportName = "MultiAgentDesktop";

export function defaultSessionsRoot() {
  const configured = process.env.MULTIAGENT_SESSIONS_ROOT;
  if (configured) return configured;
  if (process.platform === "darwin") {
    const base = path.join(os.homedir(), "Library", "Application Support");
    const next = path.join(base, appSupportName, "sessions");
    const legacy = path.join(base, legacyAppSupportName, "sessions");
    return existsSync(legacy) && !existsSync(next) ? legacy : next;
  }
  const dataHome = process.env.XDG_DATA_HOME ?? path.join(os.homedir(), ".local", "share");
  const next = path.join(dataHome, appSupportName, "sessions");
  const legacy = path.join(dataHome, legacyAppSupportName, "sessions");
  return existsSync(legacy) && !existsSync(next) ? legacy : next;
}
