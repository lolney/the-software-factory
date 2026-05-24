import { execFile } from "node:child_process";
import crypto from "node:crypto";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export const CODEX_PUBLIC_CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann";

export interface OAuthTokenSet {
  accessToken: string;
  refreshToken?: string;
  expiresAt?: string;
  email?: string;
}

interface PendingOAuth {
  state: string;
  verifier: string;
  redirectUri: string;
}

export class AuthManager {
  private readonly keychainService = "local.multiagent.codex-oauth";
  private readonly keychainAccount = "codex-public-client";
  private readonly pending = new Map<string, PendingOAuth>();

  authorizationUrl(state: string, redirectUri = "http://127.0.0.1:3767/oauth/callback", codeChallenge?: string) {
    const url = new URL("https://auth.openai.com/oauth/authorize");
    url.searchParams.set("client_id", CODEX_PUBLIC_CLIENT_ID);
    url.searchParams.set("response_type", "code");
    url.searchParams.set("redirect_uri", redirectUri);
    url.searchParams.set("scope", "openid profile email offline_access");
    url.searchParams.set("state", state);
    if (codeChallenge) {
      url.searchParams.set("code_challenge", codeChallenge);
      url.searchParams.set("code_challenge_method", "S256");
    }
    return url.toString();
  }

  beginOAuth(port = 3767) {
    const state = safeToken();
    const verifier = safeToken(48);
    const redirectUri = `http://127.0.0.1:${port}/oauth/callback`;
    const codeChallenge = base64Url(crypto.createHash("sha256").update(verifier).digest());
    this.pending.set(state, { state, verifier, redirectUri });
    return {
      clientId: CODEX_PUBLIC_CLIENT_ID,
      state,
      authorizationUrl: this.authorizationUrl(state, redirectUri, codeChallenge)
    };
  }

  async completeOAuthCallback(callbackUrl: string) {
    const url = new URL(callbackUrl);
    const code = url.searchParams.get("code");
    const state = url.searchParams.get("state");
    if (!code || !state) {
      throw new Error("OAuth callback is missing code or state.");
    }
    const pending = this.pending.get(state);
    if (!pending) {
      throw new Error("OAuth callback state is unknown or expired.");
    }
    this.pending.delete(state);
    const tokens = await this.exchangeCode(code, pending);
    await this.saveTokens(tokens);
    return this.status();
  }

  async exchangeCode(code: string, pending: PendingOAuth): Promise<OAuthTokenSet> {
    const body = new URLSearchParams({
      grant_type: "authorization_code",
      client_id: CODEX_PUBLIC_CLIENT_ID,
      code,
      redirect_uri: pending.redirectUri,
      code_verifier: pending.verifier
    });
    const response = await fetch("https://auth.openai.com/oauth/token", {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body
    });
    if (!response.ok) {
      throw new Error(`OAuth token exchange failed with HTTP ${response.status}.`);
    }
    const raw = await response.json() as {
      access_token?: string;
      refresh_token?: string;
      expires_in?: number;
      id_token?: string;
    };
    if (!raw.access_token) {
      throw new Error("OAuth token exchange did not return an access token.");
    }
    return {
      accessToken: raw.access_token,
      refreshToken: raw.refresh_token,
      expiresAt: raw.expires_in ? new Date(Date.now() + raw.expires_in * 1000).toISOString() : undefined,
      email: emailFromIdToken(raw.id_token)
    };
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

  async deleteTokens() {
    try {
      await execFileAsync("security", [
        "delete-generic-password",
        "-a",
        this.keychainAccount,
        "-s",
        this.keychainService
      ]);
    } catch {
      // The user may already be disconnected; deletion is idempotent for callers.
    }
  }

  async status() {
    const tokens = await this.loadTokens();
    return {
      clientId: CODEX_PUBLIC_CLIENT_ID,
      connected: Boolean(tokens) && !(await this.needsRefresh()),
      hasTokens: Boolean(tokens),
      email: tokens?.email,
      expiresAt: tokens?.expiresAt,
      needsRefresh: await this.needsRefresh()
    };
  }

  async needsRefresh(now = new Date()) {
    const tokens = await this.loadTokens();
    if (!tokens?.expiresAt) return false;
    return new Date(tokens.expiresAt).getTime() - now.getTime() < 60_000;
  }
}

function safeToken(length = 32) {
  return base64Url(crypto.randomBytes(length));
}

function base64Url(input: Buffer) {
  return input.toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function emailFromIdToken(idToken?: string) {
  if (!idToken) return undefined;
  const [, payload] = idToken.split(".");
  if (!payload) return undefined;
  try {
    const decoded = JSON.parse(Buffer.from(payload.replace(/-/g, "+").replace(/_/g, "/"), "base64").toString("utf8")) as { email?: string };
    return decoded.email;
  } catch {
    return undefined;
  }
}
