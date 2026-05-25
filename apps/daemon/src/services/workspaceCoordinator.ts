import path from "node:path";
import type { SessionEvent } from "@multiagent/shared";
import { makeEventId } from "./eventStore.js";

export interface WorkspacePolicy {
  sessionId: string;
  workspaceRoot: string;
  allowedRoots: string[];
}

export class WorkspaceCoordinator {
  private leases = new Map<string, Map<string, string>>();
  private touched = new Map<string, Map<string, Set<string>>>();

  assertAllowed(policy: WorkspacePolicy, candidatePath: string) {
    const workspaceRoot = path.resolve(policy.workspaceRoot);
    const absolute = path.resolve(workspaceRoot, candidatePath);
    const allowed = policy.allowedRoots.some((root) => {
      const allowedRoot = path.resolve(workspaceRoot, root);
      return absolute === allowedRoot || absolute.startsWith(`${allowedRoot}${path.sep}`);
    });
    if (!allowed) {
      throw new Error(`Path ${candidatePath} is outside allowed workspace roots.`);
    }
    return absolute;
  }

  claimFile(policy: WorkspacePolicy, agentId: string, candidatePath: string): SessionEvent {
    const absolute = this.assertAllowed(policy, candidatePath);
    const sessionLeases = getOrCreate(this.leases, policy.sessionId, () => new Map<string, string>());
    const existingAgent = sessionLeases.get(absolute);
    if (existingAgent && existingAgent !== agentId) {
      return this.event(policy.sessionId, agentId, "workspace.conflict_detected", {
        path: absolute,
        ownerAgentId: existingAgent,
        requestingAgentId: agentId
      });
    }
    sessionLeases.set(absolute, agentId);
    return this.event(policy.sessionId, agentId, "workspace.file_claimed", { path: absolute });
  }

  recordTouched(policy: WorkspacePolicy, agentId: string, candidatePath: string, operation: "read" | "write" | "delete" = "write", diff?: string, diffStats?: { additions: number; deletions: number }): SessionEvent {
    const absolute = this.assertAllowed(policy, candidatePath);
    const sessionTouched = getOrCreate(this.touched, policy.sessionId, () => new Map<string, Set<string>>());
    const agentTouched = getOrCreate(sessionTouched, agentId, () => new Set<string>());
    agentTouched.add(absolute);
    return this.event(policy.sessionId, agentId, "workspace.file_touched", {
      path: absolute,
      operation,
      diff,
      diffStats
    });
  }

  touchedFiles(sessionId: string, agentId: string) {
    return [...(this.touched.get(sessionId)?.get(agentId) ?? new Set<string>())];
  }

  private event(sessionId: string, agentId: string, type: SessionEvent["type"], payload: Record<string, unknown>): SessionEvent {
    return {
      eventId: makeEventId(),
      sessionId,
      agentId,
      timestamp: new Date().toISOString(),
      type,
      payload
    };
  }
}

function getOrCreate<K, V>(map: Map<K, V>, key: K, create: () => V): V {
  const existing = map.get(key);
  if (existing) return existing;
  const value = create();
  map.set(key, value);
  return value;
}
