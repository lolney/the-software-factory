import { DaemonRequestSchema, type DaemonResponse, type SessionEvent } from "@multiagent/shared";
import { SessionManager } from "../services/sessionManager.js";

export async function routeDaemonMessage(
  manager: SessionManager,
  raw: string,
  publish: (event: SessionEvent) => void
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

  manager.setPublisher(publish);

  try {
    const result = await manager.handle(request.data);
    return { id: request.data.id, ok: true, result };
  } catch (error) {
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
