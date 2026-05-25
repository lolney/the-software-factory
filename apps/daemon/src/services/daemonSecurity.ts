import type http from "node:http";
import { createHmac } from "node:crypto";

export function configuredDaemonToken() {
  return process.env.MULTIAGENT_DAEMON_TOKEN?.trim() || undefined;
}

export function allowUnauthenticatedDaemon() {
  return process.env.MULTIAGENT_DAEMON_ALLOW_UNAUTHENTICATED === "1";
}

export function requestToken(url: URL, headers: Headers | http.IncomingHttpHeaders) {
  const queryToken = url.searchParams.get("token")?.trim();
  if (queryToken) return queryToken;
  const raw = headers instanceof Headers ? headers.get("x-multiagent-token") : headers["x-multiagent-token"];
  return Array.isArray(raw) ? raw[0]?.trim() : raw?.trim();
}

export function isAllowedOrigin(origin: string | undefined | null, port: number) {
  if (!origin) return true;
  if (origin === "null") return false;
  try {
    const parsed = new URL(origin);
    const hostname = parsed.hostname.toLowerCase();
    const originPort = parsed.port || (parsed.protocol === "https:" ? "443" : "80");
    return (hostname === "127.0.0.1" || hostname === "localhost" || hostname === "::1") && originPort === String(port);
  } catch {
    return false;
  }
}

export function authorizeDaemonRequest(input: {
  url: URL;
  headers: Headers | http.IncomingHttpHeaders;
  port: number;
  requireToken?: boolean;
}) {
  const expectedToken = configuredDaemonToken();
  if (input.requireToken !== false && !expectedToken && !allowUnauthenticatedDaemon()) {
    return { ok: false, status: 503, message: "Daemon token is not configured." };
  }
  if (input.requireToken !== false && expectedToken && requestToken(input.url, input.headers) !== expectedToken) {
    return { ok: false, status: 401, message: "Unauthorized daemon request." };
  }
  const origin = input.headers instanceof Headers ? input.headers.get("origin") : input.headers.origin;
  const originValue = Array.isArray(origin) ? origin[0] : origin;
  if (!isAllowedOrigin(originValue, input.port)) {
    return { ok: false, status: 403, message: "Forbidden daemon origin." };
  }
  return { ok: true, status: 200, message: "ok" };
}

export function daemonOwnershipChallenge(nonce: string) {
  const token = configuredDaemonToken();
  const normalizedNonce = nonce.trim();
  if (!token || normalizedNonce.length < 16 || normalizedNonce.length > 256) {
    return undefined;
  }
  return {
    ok: true,
    service: "multiagent-daemon",
    nonce: normalizedNonce,
    proof: createHmac("sha256", token).update(normalizedNonce).digest("hex")
  };
}
