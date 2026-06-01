import { SessionManager } from "./services/sessionManager.js";
import { routeDaemonMessage } from "./protocol/router.js";
import { authorizeDaemonRequest, daemonOwnershipChallenge } from "./services/daemonSecurity.js";
import { OPENAI_OAUTH_CALLBACK_PORT } from "./services/authManager.js";

export interface DaemonServerOptions {
  port: number;
  sessionsRoot: string;
}

export function createDaemonServer(options: DaemonServerOptions) {
  let oauthCallbackReady = options.port === OPENAI_OAUTH_CALLBACK_PORT;
  let callbackServer: ReturnType<typeof Bun.serve> | undefined;
  let handleOAuthCallback: (requestUrl: string) => Promise<Response>;
  const ensureOAuthCallbackReady = () => {
    if (options.port === OPENAI_OAUTH_CALLBACK_PORT || oauthCallbackReady) {
      return true;
    }
    try {
      callbackServer = Bun.serve({
        port: OPENAI_OAUTH_CALLBACK_PORT,
        hostname: "127.0.0.1",
        fetch(request) {
          const url = new URL(request.url);
          if (url.pathname === "/oauth/callback" || url.pathname === "/auth/callback") {
            return handleOAuthCallback(request.url);
          }
          return new Response("Not found.", { status: 404, headers: { "content-type": "text/plain" } });
        }
      });
      oauthCallbackReady = true;
      return true;
    } catch (error) {
      oauthCallbackReady = false;
      console.error(`OpenAI OAuth callback listener failed on 127.0.0.1:${OPENAI_OAUTH_CALLBACK_PORT}:`, error);
      return false;
    }
  };
  const manager = new SessionManager({ sessionsRoot: options.sessionsRoot, port: options.port, ensureOAuthCallbackReady });

  handleOAuthCallback = async (requestUrl: string) => {
    try {
      await manager.completeOAuthCallback(requestUrl);
      return new Response("OpenAI OAuth connected. You can close this window and return to The Software Factory.", {
        headers: { "content-type": "text/plain" }
      });
    } catch (error) {
      return new Response(error instanceof Error ? error.message : String(error), {
        status: 400,
        headers: { "content-type": "text/plain" }
      });
    }
  };

  void ensureOAuthCallbackReady();

  const daemonServer = Bun.serve({
    port: options.port,
    hostname: "127.0.0.1",
    async fetch(request, server) {
      const url = new URL(request.url);
      if (url.pathname === "/oauth/callback" || url.pathname === "/auth/callback") {
        return handleOAuthCallback(request.url);
      }
      if (url.pathname === "/health") {
        return new Response(JSON.stringify({ ok: true, service: "software-factory-daemon", transport: "bun" }), {
          headers: { "content-type": "application/json" }
        });
      }
      if (url.pathname === "/ownership-challenge") {
        const challenge = daemonOwnershipChallenge(url.searchParams.get("nonce") ?? "");
        return new Response(JSON.stringify(challenge ? { ...challenge, transport: "bun" } : { ok: false }), {
          status: challenge ? 200 : 404,
          headers: { "content-type": "application/json" }
        });
      }
      const authorization = authorizeDaemonRequest({ url, headers: request.headers, port: options.port });
      if (!authorization.ok) {
        return new Response(authorization.message, { status: authorization.status });
      }
      if (server.upgrade(request)) {
        return undefined;
      }
      return new Response(JSON.stringify({ ok: true, service: "software-factory-daemon" }), {
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
  const stopDaemon = daemonServer.stop.bind(daemonServer);
  daemonServer.stop = (closeActiveConnections?: boolean) => {
    callbackServer?.stop(closeActiveConnections);
    return stopDaemon(closeActiveConnections);
  };
  return daemonServer;
}
