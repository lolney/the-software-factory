import { DaemonRequestSchema, type DaemonResponse } from "@multiagent/shared";
import { SessionManager } from "./services/sessionManager.js";

export interface DaemonServerOptions {
  port: number;
  sessionsRoot: string;
}

export function createDaemonServer(options: DaemonServerOptions) {
  const manager = new SessionManager({ sessionsRoot: options.sessionsRoot });

  return Bun.serve({
    port: options.port,
    fetch(request, server) {
      if (server.upgrade(request)) {
        return undefined;
      }
      return new Response(JSON.stringify({ ok: true, service: "multiagent-daemon" }), {
        headers: { "content-type": "application/json" }
      });
    },
    websocket: {
      async message(ws, raw) {
        const response = await handleMessage(manager, String(raw), (event) => {
          ws.send(JSON.stringify({ method: "event", params: event }));
        });
        ws.send(JSON.stringify(response));
      }
    }
  });
}

async function handleMessage(
  manager: SessionManager,
  raw: string,
  publish: Parameters<SessionManager["setPublisher"]>[0]
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
