import os from "node:os";
import path from "node:path";

export function defaultSessionsRoot() {
  const configured = process.env.MULTIAGENT_SESSIONS_ROOT;
  if (configured) return configured;
  if (process.platform === "darwin") {
    return path.join(os.homedir(), "Library", "Application Support", "MultiAgentDesktop", "sessions");
  }
  const dataHome = process.env.XDG_DATA_HOME ?? path.join(os.homedir(), ".local", "share");
  return path.join(dataHome, "MultiAgentDesktop", "sessions");
}
