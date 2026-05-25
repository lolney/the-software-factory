import { describe, expect, it } from "vitest";
import { authorizeDaemonRequest, isAllowedOrigin } from "./daemonSecurity.js";

describe("daemon security", () => {
  it("allows absent or loopback origins and rejects remote origins", () => {
    expect(isAllowedOrigin(undefined, 3767)).toBe(true);
    expect(isAllowedOrigin("http://127.0.0.1:3767", 3767)).toBe(true);
    expect(isAllowedOrigin("http://localhost:3767", 3767)).toBe(true);
    expect(isAllowedOrigin("null", 3767)).toBe(false);
    expect(isAllowedOrigin("https://example.com", 3767)).toBe(false);
    expect(isAllowedOrigin("http://127.0.0.1:9999", 3767)).toBe(false);
  });

  it("requires the configured daemon token", () => {
    const previous = process.env.MULTIAGENT_DAEMON_TOKEN;
    process.env.MULTIAGENT_DAEMON_TOKEN = "secret-token";
    try {
      const headers = new Headers({ origin: "http://127.0.0.1:3767" });
      expect(authorizeDaemonRequest({
        url: new URL("ws://127.0.0.1:3767/?token=secret-token"),
        headers,
        port: 3767
      }).ok).toBe(true);
      expect(authorizeDaemonRequest({
        url: new URL("ws://127.0.0.1:3767/"),
        headers: new Headers({ origin: "http://127.0.0.1:3767", "x-multiagent-token": "secret-token" }),
        port: 3767
      }).ok).toBe(true);
      expect(authorizeDaemonRequest({
        url: new URL("ws://127.0.0.1:3767/?token=wrong"),
        headers,
        port: 3767
      })).toMatchObject({ ok: false, status: 401 });
    } finally {
      if (previous === undefined) {
        delete process.env.MULTIAGENT_DAEMON_TOKEN;
      } else {
        process.env.MULTIAGENT_DAEMON_TOKEN = previous;
      }
    }
  });

  it("fails closed when no token is configured unless explicitly opted out", () => {
    const previousToken = process.env.MULTIAGENT_DAEMON_TOKEN;
    const previousOptOut = process.env.MULTIAGENT_DAEMON_ALLOW_UNAUTHENTICATED;
    delete process.env.MULTIAGENT_DAEMON_TOKEN;
    delete process.env.MULTIAGENT_DAEMON_ALLOW_UNAUTHENTICATED;
    try {
      expect(authorizeDaemonRequest({
        url: new URL("ws://127.0.0.1:3767/"),
        headers: new Headers(),
        port: 3767
      })).toMatchObject({ ok: false, status: 503 });
      process.env.MULTIAGENT_DAEMON_ALLOW_UNAUTHENTICATED = "1";
      expect(authorizeDaemonRequest({
        url: new URL("ws://127.0.0.1:3767/"),
        headers: new Headers(),
        port: 3767
      }).ok).toBe(true);
    } finally {
      if (previousToken === undefined) {
        delete process.env.MULTIAGENT_DAEMON_TOKEN;
      } else {
        process.env.MULTIAGENT_DAEMON_TOKEN = previousToken;
      }
      if (previousOptOut === undefined) {
        delete process.env.MULTIAGENT_DAEMON_ALLOW_UNAUTHENTICATED;
      } else {
        process.env.MULTIAGENT_DAEMON_ALLOW_UNAUTHENTICATED = previousOptOut;
      }
    }
  });
});
