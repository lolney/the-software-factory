import { createDaemonServer } from "./server.js";
import { defaultSessionsRoot } from "./services/sessionRoot.js";

const port = Number(process.env.MULTIAGENT_DAEMON_PORT ?? 3767);
const sessionsRoot = defaultSessionsRoot();

createDaemonServer({ port, sessionsRoot });
