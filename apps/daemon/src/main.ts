import { createDaemonServer } from "./server.js";

const port = Number(process.env.MULTIAGENT_DAEMON_PORT ?? 3767);
const sessionsRoot = process.env.MULTIAGENT_SESSIONS_ROOT ?? "sessions";

createDaemonServer({ port, sessionsRoot });
