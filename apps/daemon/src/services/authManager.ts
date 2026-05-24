import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export const CODEX_PUBLIC_CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann";

export interface OAuthTokenSet {
  accessToken: string;
  refreshToken?: string;
  expiresAt?: string;
}

export class AuthManager {
  private readonly keychainService = "local.multiagent.codex-oauth";
  private readonly keychainAccount = "codex-public-client";

  authorizationUrl(state: string, redirectUri = "http://127.0.0.1:3767/oauth/callback") {
    const url = new URL("https://auth.openai.com/oauth/authorize");
    url.searchParams.set("client_id", CODEX_PUBLIC_CLIENT_ID);
    url.searchParams.set("response_type", "code");
    url.searchParams.set("redirect_uri", redirectUri);
    url.searchParams.set("scope", "openid profile email offline_access");
    url.searchParams.set("state", state);
    return url.toString();
  }

  async saveTokens(tokens: OAuthTokenSet) {
    const payload = JSON.stringify(tokens);
    await execFileAsync("security", [
      "add-generic-password",
      "-a",
      this.keychainAccount,
      "-s",
      this.keychainService,
      "-w",
      payload,
      "-U"
    ]);
  }

  async loadTokens(): Promise<OAuthTokenSet | null> {
    try {
      const { stdout } = await execFileAsync("security", [
        "find-generic-password",
        "-a",
        this.keychainAccount,
        "-s",
        this.keychainService,
        "-w"
      ]);
      return JSON.parse(stdout.trim()) as OAuthTokenSet;
    } catch {
      return null;
    }
  }

  async needsRefresh(now = new Date()) {
    const tokens = await this.loadTokens();
    if (!tokens?.expiresAt) return false;
    return new Date(tokens.expiresAt).getTime() - now.getTime() < 60_000;
  }
}
