import type { RoleSpec, SessionEvent } from "@software-factory/shared";
import { makeEventId } from "./eventStore.js";

export type CapabilityAction =
  | "workspace.read"
  | "workspace.write"
  | "workspace.command"
  | "plan.create"
  | "mcp.use"
  | "ui.browser"
  | "ui.computer";

export interface CapabilityDecisionInput {
  sessionId: string;
  agentId: string;
  role?: RoleSpec;
  action: CapabilityAction;
  resource?: Record<string, unknown>;
}

export class CapabilityBroker {
  check(input: CapabilityDecisionInput): { allowed: boolean; reason: string; event: SessionEvent } {
    const allowed = this.allowed(input.role, input.action);
    const reason = allowed
      ? "allowed by role tool policy"
      : `role ${input.role?.id ?? "unknown"} is not allowed to use ${input.action}`;
    return {
      allowed,
      reason,
      event: {
        eventId: makeEventId(),
        sessionId: input.sessionId,
        agentId: input.agentId,
        timestamp: new Date().toISOString(),
        type: "capability.checked",
        payload: {
          action: input.action,
          allowed,
          reason,
          roleId: input.role?.id,
          resource: input.resource ?? {}
        }
      }
    };
  }

  private allowed(role: RoleSpec | undefined, action: CapabilityAction) {
    if (!role) return false;
    switch (action) {
      case "workspace.read":
        return role.toolPolicy.canRead;
      case "workspace.write":
        return role.toolPolicy.canWrite;
      case "workspace.command":
        return role.toolPolicy.canRunCommands;
      case "plan.create":
        return role.toolPolicy.canCreatePlans;
      case "mcp.use":
        return role.toolPolicy.canUseMCP === true;
      case "ui.browser":
        return role.toolPolicy.canUseBrowser === true;
      case "ui.computer":
        return role.toolPolicy.canUseComputer === true;
    }
  }
}
