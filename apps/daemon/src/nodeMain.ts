import http from "node:http";
import { WebSocketServer } from "ws";
import { SessionManager } from "./services/sessionManager.js";
import { routeDaemonMessage } from "./protocol/router.js";

const port = Number(process.env.MULTIAGENT_DAEMON_PORT ?? 3767);
const sessionsRoot = process.env.MULTIAGENT_SESSIONS_ROOT ?? "sessions";
const manager = new SessionManager({ sessionsRoot });

const server = http.createServer((_request, response) => {
  response.writeHead(200, { "content-type": "application/json" });
  response.end(JSON.stringify({ ok: true, service: "multiagent-daemon-node" }));
});

const wss = new WebSocketServer({ server });
wss.on("connection", (ws) => {
  ws.on("message", async (raw) => {
    const response = await routeDaemonMessage(manager, String(raw), (event) => {
      ws.send(JSON.stringify({ method: "event", params: event }));
    });
    ws.send(JSON.stringify(response));
  });
});

server.listen(port, "127.0.0.1", () => {
  console.log(`multiagent daemon listening on ws://127.0.0.1:${port}`);
});
