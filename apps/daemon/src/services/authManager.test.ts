import { describe, expect, it } from "vitest";
import { AuthManager, CODEX_PUBLIC_CLIENT_ID } from "./authManager.js";

describe("AuthManager", () => {
  it("builds an authorization URL for the Codex public OAuth client", () => {
    const url = new URL(new AuthManager().authorizationUrl("state-test"));
    expect(url.searchParams.get("client_id")).toBe(CODEX_PUBLIC_CLIENT_ID);
    expect(url.searchParams.get("state")).toBe("state-test");
    expect(url.searchParams.get("response_type")).toBe("code");
  });
});
