import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { AuthManager, CODEX_PUBLIC_CLIENT_ID, OPENAI_OAUTH_SCOPES } from "./authManager.js";

describe("AuthManager", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
  });

  afterEach(() => {
    vi.restoreAllMocks();
    delete process.env.MULTIAGENT_CHATGPT_ACCOUNT_ID;
    delete process.env.CHATGPT_ACCOUNT_ID;
  });

  it("builds an authorization URL for the Codex public OAuth client", () => {
    const url = new URL(new AuthManager().authorizationUrl("state-test"));
    expect(url.searchParams.get("client_id")).toBe(CODEX_PUBLIC_CLIENT_ID);
    expect(url.searchParams.get("state")).toBe("state-test");
    expect(url.searchParams.get("response_type")).toBe("code");
    expect(url.searchParams.get("redirect_uri")).toBe("http://localhost:3767/auth/callback");
    for (const scope of OPENAI_OAUTH_SCOPES) {
      expect(url.searchParams.get("scope")?.split(" ")).toContain(scope);
    }
    expect(url.searchParams.get("originator")).toBe("codex_cli_rs");
    expect(url.searchParams.get("codex_cli_simplified_flow")).toBe("true");
    expect(url.searchParams.get("scope")?.split(" ")).toEqual(expect.arrayContaining([
      "api.connectors.read",
      "api.connectors.invoke"
    ]));
  });

  it("adds ChatGPT-Account-Id to WHAM OAuth live connections from token metadata", async () => {
    const manager = new AuthManager();
    vi.spyOn(manager, "loadTokens").mockResolvedValue({
      accessToken: "access-token",
      refreshToken: "refresh-token",
      expiresAt: futureExpiry(),
      accountId: "acct_from_token",
      scopes: [...OPENAI_OAUTH_SCOPES]
    });
    vi.spyOn(manager, "needsRefresh").mockResolvedValue(false);
    vi.spyOn(manager, "loadChatGPTAccountId").mockResolvedValue(undefined);

    const connection = await manager.loadLiveConnection();

    expect(connection?.source).toBe("codex-oauth");
    expect(connection?.baseURL).toContain("/wham");
    expect(connection?.defaultHeaders?.["ChatGPT-Account-Id"]).toBe("acct_from_token");
  });

  it("can resolve ChatGPT-Account-Id from the existing Codex auth file shape", async () => {
    const manager = new AuthManager();
    vi.spyOn(manager, "loadTokens").mockResolvedValue({
      accessToken: "access-token",
      refreshToken: "refresh-token",
      expiresAt: futureExpiry(),
      scopes: [...OPENAI_OAUTH_SCOPES]
    });
    vi.spyOn(manager, "needsRefresh").mockResolvedValue(false);
    vi.spyOn(manager, "loadChatGPTAccountId").mockResolvedValue(undefined);
    vi.spyOn(manager, "loadCodexTokens").mockResolvedValue({
      accessToken: "codex-access-token",
      refreshToken: "codex-refresh-token",
      accountId: "acct_from_codex_auth"
    });

    const connection = await manager.loadLiveConnection();

    expect(connection?.source).toBe("codex-oauth");
    expect(connection?.defaultHeaders?.["ChatGPT-Account-Id"]).toBe("acct_from_codex_auth");
  });

  it("does not report OAuth live readiness without a ChatGPT account id", async () => {
    const manager = new AuthManager();
    vi.spyOn(manager, "loadTokens").mockResolvedValue({
      accessToken: "access-token",
      refreshToken: "refresh-token",
      expiresAt: futureExpiry(),
      scopes: [...OPENAI_OAUTH_SCOPES]
    });
    vi.spyOn(manager, "needsRefresh").mockResolvedValue(false);
    vi.spyOn(manager, "loadChatGPTAccountId").mockResolvedValue(undefined);
    vi.spyOn(manager, "loadCodexTokens").mockResolvedValue(null);
    vi.spyOn(manager, "loadApiKey").mockResolvedValue(undefined);

    const status = await manager.status();

    expect(status.connected).toBe(true);
    expect(status.liveCredentialConfigured).toBe(false);
    expect(status.liveReadinessError).toContain("ChatGPT account id");
  });

  it("does not report stale OAuth credentials as connected when refresh fails", async () => {
    const manager = new AuthManager();
    vi.spyOn(manager, "loadTokens").mockResolvedValue({
      accessToken: "stale-access-token",
      refreshToken: "invalid-refresh-token"
    });
    vi.spyOn(manager, "refreshTokens").mockRejectedValue(new Error("OAuth token refresh failed with HTTP 401."));
    const deleteTokens = vi.spyOn(manager, "deleteTokens").mockResolvedValue(undefined);
    vi.spyOn(manager, "loadApiKey").mockResolvedValue(undefined);
    vi.spyOn(manager, "loadChatGPTAccountId").mockResolvedValue(undefined);
    vi.spyOn(manager, "loadCodexTokens").mockResolvedValue(null);

    const status = await manager.status();

    expect(deleteTokens).toHaveBeenCalled();
    expect(status.connected).toBe(false);
    expect(status.hasTokens).toBe(false);
    expect(status.liveCredentialConfigured).toBe(false);
    expect(status.liveReadinessError).toContain("could not be refreshed");
  });

  it("does not delete OAuth credentials on transient refresh failures", async () => {
    const manager = new AuthManager();
    vi.spyOn(manager, "loadTokens").mockResolvedValue({
      accessToken: "stale-access-token",
      refreshToken: "refresh-token"
    });
    vi.spyOn(manager, "refreshTokens").mockRejectedValue(new Error("fetch failed"));
    const deleteTokens = vi.spyOn(manager, "deleteTokens").mockResolvedValue(undefined);
    vi.spyOn(manager, "loadApiKey").mockResolvedValue(undefined);
    vi.spyOn(manager, "loadChatGPTAccountId").mockResolvedValue(undefined);
    vi.spyOn(manager, "loadCodexTokens").mockResolvedValue(null);

    const status = await manager.status();

    expect(deleteTokens).not.toHaveBeenCalled();
    expect(status.connected).toBe(false);
    expect(status.hasTokens).toBe(true);
    expect(status.liveReadinessError).toContain("could not be refreshed right now");
  });

  it("stores granted OAuth scopes from the token exchange response", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response(JSON.stringify({
      access_token: "access-token",
      refresh_token: "refresh-token",
      expires_in: 3600,
      scope: "openid profile email offline_access"
    }), { status: 200 }));
    const manager = new AuthManager();

    const tokens = await manager.exchangeCode("code", {
      state: "state",
      verifier: "verifier",
      redirectUri: "http://localhost:3767/auth/callback"
    });

    expect(tokens.scopes).toEqual(["openid", "profile", "email", "offline_access"]);
  });

  it("uses requested OAuth scopes when a successful token exchange omits granted scopes", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response(JSON.stringify({
      access_token: "access-token",
      refresh_token: "refresh-token",
      expires_in: 3600
    }), { status: 200 }));
    const manager = new AuthManager();

    const tokens = await manager.exchangeCode("code", {
      state: "state",
      verifier: "verifier",
      redirectUri: "http://localhost:3767/auth/callback"
    });

    expect(tokens.scopes).toEqual([...OPENAI_OAUTH_SCOPES]);
  });

  it("stores granted OAuth scopes from the refresh response", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response(JSON.stringify({
      access_token: "access-token",
      refresh_token: "next-refresh-token",
      expires_in: 3600,
      scopes: ["openid", "profile"]
    }), { status: 200 }));
    const manager = new AuthManager();
    vi.spyOn(manager, "saveTokens").mockResolvedValue(undefined);

    const tokens = await manager.refreshTokens({
      accessToken: "old-access-token",
      refreshToken: "old-refresh-token",
      scopes: [...OPENAI_OAUTH_SCOPES]
    });

    expect(tokens.scopes).toEqual(["openid", "profile"]);
  });

  it("does not report OAuth credentials as live-ready when required scopes are missing", async () => {
    const manager = new AuthManager();
    vi.spyOn(manager, "loadTokens").mockResolvedValue({
      accessToken: "access-token",
      refreshToken: "refresh-token",
      expiresAt: futureExpiry(),
      accountId: "acct_from_token",
      scopes: ["openid", "profile", "email", "offline_access"]
    });
    vi.spyOn(manager, "loadChatGPTAccountId").mockResolvedValue(undefined);
    vi.spyOn(manager, "loadCodexTokens").mockResolvedValue(null);
    vi.spyOn(manager, "loadApiKey").mockResolvedValue(undefined);

    const status = await manager.status();
    const connection = await manager.loadLiveConnection();

    expect(status.connected).toBe(false);
    expect(status.hasTokens).toBe(true);
    expect(status.liveCredentialConfigured).toBe(false);
    expect(status.liveReadinessError).toContain("missing required scopes");
    expect(connection).toBeUndefined();
  });

  it("allows live OAuth readiness when connector scopes are present without optional identity scopes", async () => {
    const manager = new AuthManager();
    vi.spyOn(manager, "loadTokens").mockResolvedValue({
      accessToken: "access-token",
      refreshToken: "refresh-token",
      expiresAt: futureExpiry(),
      accountId: "acct_from_token",
      scopes: ["api.connectors.read", "api.connectors.invoke"]
    });
    vi.spyOn(manager, "loadChatGPTAccountId").mockResolvedValue(undefined);

    const status = await manager.status();
    const connection = await manager.loadLiveConnection();

    expect(status.connected).toBe(true);
    expect(status.liveCredentialConfigured).toBe(true);
    expect(connection?.source).toBe("codex-oauth");
  });

  it("treats expired OAuth credentials without a refresh token as permanently unusable", async () => {
    const manager = new AuthManager();
    vi.spyOn(manager, "loadTokens").mockResolvedValue({
      accessToken: "expired-access-token",
      expiresAt: new Date(Date.now() - 60 * 1000).toISOString(),
      scopes: [...OPENAI_OAUTH_SCOPES]
    });
    const deleteTokens = vi.spyOn(manager, "deleteTokens").mockResolvedValue(undefined);
    vi.spyOn(manager, "loadApiKey").mockResolvedValue(undefined);
    vi.spyOn(manager, "loadChatGPTAccountId").mockResolvedValue(undefined);
    vi.spyOn(manager, "loadCodexTokens").mockResolvedValue(null);

    const status = await manager.status();

    expect(deleteTokens).toHaveBeenCalled();
    expect(status.hasTokens).toBe(false);
    expect(status.connected).toBe(false);
    expect(status.liveReadinessError).toContain("Sign in again");
  });

  it("clears access-only OAuth credentials after a live auth failure", async () => {
    const manager = new AuthManager();
    vi.spyOn(manager, "loadTokens").mockResolvedValue({
      accessToken: "access-only-token",
      scopes: [...OPENAI_OAUTH_SCOPES]
    });
    const deleteTokens = vi.spyOn(manager, "deleteTokens").mockResolvedValue(undefined);

    const connection = await manager.refreshLiveConnectionAfterAuthError();

    expect(connection).toBeUndefined();
    expect(deleteTokens).toHaveBeenCalled();
  });
});

function futureExpiry() {
  return new Date(Date.now() + 60 * 60 * 1000).toISOString();
}
