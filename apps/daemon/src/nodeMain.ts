import http from "node:http";
import { WebSocketServer } from "ws";
import { SessionManager } from "./services/sessionManager.js";
import { routeDaemonMessage } from "./protocol/router.js";
import { defaultSessionsRoot } from "./services/sessionRoot.js";

const port = Number(process.env.MULTIAGENT_DAEMON_PORT ?? 3767);
const sessionsRoot = defaultSessionsRoot();
const manager = new SessionManager({ sessionsRoot });

const server = http.createServer(async (request, response) => {
  const url = new URL(request.url ?? "/", `http://127.0.0.1:${port}`);
  if (url.pathname === "/oauth/callback" || url.pathname === "/auth/callback") {
    try {
      await manager.completeOAuthCallback(url.toString());
      response.writeHead(200, { "content-type": "text/plain" });
      response.end("OpenAI OAuth connected. You can close this window and return to Multiagent Coding.");
    } catch (error) {
      response.writeHead(400, { "content-type": "text/plain" });
      response.end(error instanceof Error ? error.message : String(error));
    }
    return;
  }
  response.writeHead(200, { "content-type": "application/json" });
  response.end(JSON.stringify({ ok: true, service: "multiagent-daemon-node" }));
});

const wss = new WebSocketServer({ server });
wss.on("connection", (ws) => {
  ws.on("message", async (raw) => {
    const response = await routeDaemonMessage(manager, String(raw), (event) => {
      ws.send(JSON.stringify({ method: "event", params: event }));
    }, (entry) => {
      ws.send(JSON.stringify({ method: "debugLog", params: entry }));
    });
    ws.send(JSON.stringify(response));
  });
});

server.listen(port, "127.0.0.1", () => {
  console.log(`multiagent daemon listening on ws://127.0.0.1:${port}`);
});
