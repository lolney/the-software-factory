import { describe, expect, it } from "vitest";
import { AuthManager, CODEX_PUBLIC_CLIENT_ID, OPENAI_OAUTH_SCOPES } from "./authManager.js";

describe("AuthManager", () => {
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
});
