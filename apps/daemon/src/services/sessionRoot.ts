import os from "node:os";
import path from "node:path";
import { cpSync, existsSync, mkdirSync, readdirSync } from "node:fs";

const appSupportName = "The Software Factory";
const legacyAppSupportName = "MultiAgentDesktop";

export function defaultSessionsRoot() {
  const configured = process.env.MULTIAGENT_SESSIONS_ROOT;
  if (configured) return configured;
  const configuredSupportRoot = process.env.SOFTWARE_FACTORY_APP_SUPPORT_ROOT;
  if (configuredSupportRoot) {
    return migratedSessionsRoot(configuredSupportRoot);
  }
  if (process.platform === "darwin") {
    const base = path.join(os.homedir(), "Library", "Application Support");
    return migratedSessionsRoot(base);
  }
  const dataHome = process.env.XDG_DATA_HOME ?? path.join(os.homedir(), ".local", "share");
  return migratedSessionsRoot(dataHome);
}

function migratedSessionsRoot(base: string) {
  const next = path.join(base, appSupportName, "sessions");
  const legacy = path.join(base, legacyAppSupportName, "sessions");
  mergeDirectoryContents(legacy, next);
  return next;
}

function mergeDirectoryContents(source: string, destination: string) {
  if (!existsSync(source)) return;
  mkdirSync(destination, { recursive: true });
  for (const entry of readdirSync(source, { withFileTypes: true })) {
    const sourcePath = path.join(source, entry.name);
    const destinationPath = path.join(destination, entry.name);
    if (existsSync(destinationPath)) {
      if (entry.isDirectory()) {
        mergeDirectoryContents(sourcePath, destinationPath);
      }
      continue;
    }
    cpSync(sourcePath, destinationPath, { recursive: true, errorOnExist: false });
  }
}
