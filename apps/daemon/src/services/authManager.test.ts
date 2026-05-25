import { afterEach, describe, expect, it, vi } from "vitest";
import { AuthManager, CODEX_PUBLIC_CLIENT_ID, OPENAI_OAUTH_SCOPES } from "./authManager.js";

describe("AuthManager", () => {
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
    expect(url.searchParams.get("scope")).not.toContain("api.connectors.invoke");
    for (const scope of OPENAI_OAUTH_SCOPES) {
      expect(url.searchParams.get("scope")?.split(" ")).toContain(scope);
    }
    expect(url.searchParams.get("originator")).toBe("opencode");
    expect(url.searchParams.get("codex_cli_simplified_flow")).toBe("true");
  });

  it("adds ChatGPT-Account-Id to WHAM OAuth live connections from token metadata", async () => {
    const manager = new AuthManager();
    vi.spyOn(manager, "loadTokens").mockResolvedValue({
      accessToken: "access-token",
      refreshToken: "refresh-token",
      accountId: "acct_from_token"
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
      refreshToken: "refresh-token"
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
      refreshToken: "refresh-token"
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
});
