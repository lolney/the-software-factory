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
    async fetch(request, server) {
      const url = new URL(request.url);
      if (url.pathname === "/oauth/callback" || url.pathname === "/auth/callback") {
        try {
          await manager.completeOAuthCallback(request.url);
          return new Response("OpenAI OAuth connected. You can close this window and return to Multiagent Coding.", {
            headers: { "content-type": "text/plain" }
          });
        } catch (error) {
          return new Response(error instanceof Error ? error.message : String(error), {
            status: 400,
            headers: { "content-type": "text/plain" }
          });
        }
      }
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
        }, (entry) => {
          ws.send(JSON.stringify({ method: "debugLog", params: entry }));
        });
        ws.send(JSON.stringify(response));
      }
    }
  });
}
