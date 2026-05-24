import { SessionManager } from "./services/sessionManager.js";
import { routeDaemonMessage } from "./protocol/router.js";

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
        const response = await routeDaemonMessage(manager, String(raw), (event) => {
          ws.send(JSON.stringify({ method: "event", params: event }));
        });
        ws.send(JSON.stringify(response));
      }
    }
  });
}
