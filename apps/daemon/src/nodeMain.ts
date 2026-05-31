import http from "node:http";
import { WebSocketServer } from "ws";
import { SessionManager } from "./services/sessionManager.js";
import { routeDaemonMessage } from "./protocol/router.js";
import { defaultSessionsRoot } from "./services/sessionRoot.js";
import { authorizeDaemonRequest, daemonOwnershipChallenge } from "./services/daemonSecurity.js";

const port = Number(process.env.MULTIAGENT_DAEMON_PORT ?? 3767);
const sessionsRoot = defaultSessionsRoot();
const manager = new SessionManager({ sessionsRoot, port });

const server = http.createServer(async (request, response) => {
  const url = new URL(request.url ?? "/", `http://127.0.0.1:${port}`);
  if (url.pathname === "/oauth/callback" || url.pathname === "/auth/callback") {
    try {
      await manager.completeOAuthCallback(url.toString());
      response.writeHead(200, { "content-type": "text/plain" });
      response.end("OpenAI OAuth connected. You can close this window and return to The Software Factory.");
    } catch (error) {
      response.writeHead(400, { "content-type": "text/plain" });
      response.end(error instanceof Error ? error.message : String(error));
    }
    return;
  }
  if (url.pathname === "/health") {
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify({ ok: true, service: "software-factory-daemon", transport: "node" }));
    return;
  }
  if (url.pathname === "/ownership-challenge") {
    const challenge = daemonOwnershipChallenge(url.searchParams.get("nonce") ?? "");
    response.writeHead(challenge ? 200 : 404, { "content-type": "application/json" });
    response.end(JSON.stringify(challenge ? { ...challenge, transport: "node" } : { ok: false }));
    return;
  }
  const authorization = authorizeDaemonRequest({ url, headers: request.headers, port });
  if (!authorization.ok) {
    response.writeHead(authorization.status, { "content-type": "text/plain" });
    response.end(authorization.message);
    return;
  }
  response.writeHead(200, { "content-type": "application/json" });
  response.end(JSON.stringify({ ok: true, service: "software-factory-daemon-node" }));
});

const wss = new WebSocketServer({ noServer: true });
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

server.on("upgrade", (request, socket, head) => {
  const url = new URL(request.url ?? "/", `http://127.0.0.1:${port}`);
  const authorization = authorizeDaemonRequest({ url, headers: request.headers, port });
  if (!authorization.ok) {
    socket.write(`HTTP/1.1 ${authorization.status} ${authorization.message}\r\nConnection: close\r\n\r\n`);
    socket.destroy();
    return;
  }
  wss.handleUpgrade(request, socket, head, (ws) => {
    wss.emit("connection", ws, request);
  });
});

server.listen(port, "127.0.0.1", () => {
  console.log(`The Software Factory daemon listening on ws://127.0.0.1:${port}`);
});
