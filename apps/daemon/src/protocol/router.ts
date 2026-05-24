import { DaemonRequestSchema, type DaemonResponse, type DebugLogEntry, type SessionEvent } from "@multiagent/shared";
import { SessionManager } from "../services/sessionManager.js";

export async function routeDaemonMessage(
  manager: SessionManager,
  raw: string,
  publish: (event: SessionEvent) => void,
  publishLog: (entry: DebugLogEntry) => void = () => {}
): Promise<DaemonResponse> {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return { id: "unknown", ok: false, error: { code: "bad_json", message: "Request was not valid JSON." } };
  }

  const request = DaemonRequestSchema.safeParse(parsed);
  if (!request.success) {
    return { id: "unknown", ok: false, error: { code: "bad_request", message: request.error.message } };
  }

  try {
    const result = await manager.handle(request.data, publish, publishLog);
    return { id: request.data.id, ok: true, result };
  } catch (error) {
    const sessionId = "sessionId" in request.data.params ? request.data.params.sessionId : undefined;
    if (typeof sessionId === "string") {
      await manager.logErrorForSession(sessionId, error instanceof Error ? error.message : String(error), {
        requestId: request.data.id,
        method: request.data.method
      }, publishLog);
    }
    return {
      id: request.data.id,
      ok: false,
      error: {
        code: "internal_error",
        message: error instanceof Error ? error.message : String(error)
      }
    };
  }
}
