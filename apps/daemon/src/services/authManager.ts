import { execFile } from "node:child_process";
import crypto from "node:crypto";
import { readFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export const CODEX_PUBLIC_CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann";
export const OPENAI_OAUTH_SCOPES = [
  "openid",
  "profile",
  "email",
  "offline_access"
] as const;
export const OPENAI_WHAM_BASE_URL = "https://chatgpt.com/backend-api/wham";
export const OPENAI_OAUTH_CLIENT_NAME = "the-software-factory";
export const OPENAI_OAUTH_CLIENT_VERSION = "0.1.0";

export interface OAuthTokenSet {
  accessToken: string;
  refreshToken?: string;
  expiresAt?: string;
  email?: string;
  accountId?: string;
  scopes?: string[];
}

export interface OpenAIConnection {
  apiKey: string;
  baseURL?: string;
  defaultHeaders?: Record<string, string>;
  source: "environment" | "keychain" | "codex-oauth";
}

type AccountIdSource = "environment" | "keychain" | "oauth-token" | "codex-auth";

interface PendingOAuth {
  state: string;
  verifier: string;
  redirectUri: string;
}

export class AuthManager {
  private readonly keychainService = "local.softwarefactory.codex-oauth";
  private readonly legacyKeychainService = "local.multiagent.codex-oauth";
  private readonly keychainAccount = "codex-public-client";
  private readonly chatGPTAccountIdKeychainAccount = "chatgpt-account-id";
  private readonly apiKeychainService = "local.softwarefactory.openai-api-key";
  private readonly legacyApiKeychainService = "local.multiagent.openai-api-key";
  private readonly apiKeychainAccount = "openai-api-key";
  private readonly pending = new Map<string, PendingOAuth>();

  authorizationUrl(state: string, redirectUri = "http://localhost:3767/auth/callback", codeChallenge?: string) {
    const url = new URL("https://auth.openai.com/oauth/authorize");
    url.searchParams.set("client_id", CODEX_PUBLIC_CLIENT_ID);
    url.searchParams.set("response_type", "code");
    url.searchParams.set("redirect_uri", redirectUri);
    url.searchParams.set("scope", OPENAI_OAUTH_SCOPES.join(" "));
    url.searchParams.set("state", state);
    url.searchParams.set("id_token_add_organizations", "true");
    url.searchParams.set("codex_cli_simplified_flow", "true");
    url.searchParams.set("originator", "opencode");
    if (codeChallenge) {
      url.searchParams.set("code_challenge", codeChallenge);
      url.searchParams.set("code_challenge_method", "S256");
    }
    return url.toString();
  }

  async beginOAuth(port = 3767) {
    const state = safeToken();
    const verifier = safeToken(48);
    const redirectUri = `http://localhost:${port}/auth/callback`;
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
      account_id?: string;
      accountId?: string;
    };
    if (!raw.access_token) {
      throw new Error("OAuth token exchange did not return an access token.");
    }
    return {
      accessToken: raw.access_token,
      refreshToken: raw.refresh_token,
      expiresAt: raw.expires_in ? new Date(Date.now() + raw.expires_in * 1000).toISOString() : undefined,
      email: emailFromIdToken(raw.id_token),
      accountId: raw.account_id ?? raw.accountId ?? accountIdFromToken(raw.id_token) ?? accountIdFromToken(raw.access_token),
      scopes: [...OPENAI_OAUTH_SCOPES]
    };
  }

  async refreshTokens(tokens: OAuthTokenSet): Promise<OAuthTokenSet> {
    if (!tokens.refreshToken) {
      throw new Error("OpenAI OAuth token is expired and no refresh token is available. Reconnect OpenAI OAuth in Settings.");
    }
    const body = new URLSearchParams({
      grant_type: "refresh_token",
      client_id: CODEX_PUBLIC_CLIENT_ID,
      refresh_token: tokens.refreshToken
    });
    const response = await fetch("https://auth.openai.com/oauth/token", {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body
    });
    if (!response.ok) {
      throw new Error(`OAuth token refresh failed with HTTP ${response.status}. Reconnect OpenAI OAuth in Settings.`);
    }
    const raw = await response.json() as {
      access_token?: string;
      refresh_token?: string;
      expires_in?: number;
      id_token?: string;
      account_id?: string;
      accountId?: string;
    };
    if (!raw.access_token) {
      throw new Error("OAuth token refresh did not return an access token.");
    }
    const refreshed = {
      accessToken: raw.access_token,
      refreshToken: raw.refresh_token ?? tokens.refreshToken,
      expiresAt: raw.expires_in ? new Date(Date.now() + raw.expires_in * 1000).toISOString() : tokens.expiresAt,
      email: emailFromIdToken(raw.id_token) ?? tokens.email,
      accountId: raw.account_id ?? raw.accountId ?? accountIdFromToken(raw.id_token) ?? accountIdFromToken(raw.access_token) ?? tokens.accountId,
      scopes: tokens.scopes ?? [...OPENAI_OAUTH_SCOPES]
    };
    await this.saveTokens(refreshed);
    return refreshed;
  }

  async loadLiveConnection(): Promise<OpenAIConnection | undefined> {
    if (process.env.OPENAI_API_KEY) {
      return { apiKey: process.env.OPENAI_API_KEY, source: "environment" };
    }
    let tokens = await this.loadTokens();
    if (tokens?.accessToken) {
      if (await this.needsRefresh()) {
        tokens = await this.refreshTokens(tokens);
      }
      const resolvedAccount = await this.resolveChatGPTAccountId(tokens);
      if (!resolvedAccount.accountId) {
        const apiKey = await this.loadApiKey();
        if (apiKey) {
          return { apiKey, source: "keychain" };
        }
        return undefined;
      }
      const defaultHeaders: Record<string, string> = {
        "User-Agent": `${OPENAI_OAUTH_CLIENT_NAME}/${OPENAI_OAUTH_CLIENT_VERSION}`,
        "ChatGPT-Account-Id": resolvedAccount.accountId
      };
      return {
        apiKey: tokens.accessToken,
        baseURL: OPENAI_WHAM_BASE_URL,
        defaultHeaders,
        source: "codex-oauth"
      };
    }
    const apiKey = await this.loadApiKey();
    if (apiKey) {
      return { apiKey, source: "keychain" };
    }
    return undefined;
  }

  async saveTokens(tokens: OAuthTokenSet) {
    const payload = JSON.stringify(tokens);
    await runKeychainWrite(
      [
        "add-generic-password",
        "-a",
        this.keychainAccount,
        "-s",
        this.keychainService,
        "-w",
        payload,
        "-U"
      ],
      "Could not store OpenAI OAuth credentials in macOS Keychain."
    );
  }

  async loadTokens(): Promise<OAuthTokenSet | null> {
    const current = await this.loadTokensFromService(this.keychainService);
    if (current) return current;
    const legacy = await this.loadTokensFromService(this.legacyKeychainService);
    if (legacy) {
      await this.saveTokens(legacy);
    }
    return legacy;
  }

  private async loadTokensFromService(service: string): Promise<OAuthTokenSet | null> {
    try {
      const { stdout } = await execFileAsync("security", [
        "find-generic-password",
        "-a",
        this.keychainAccount,
        "-s",
        service,
        "-w"
      ]);
      return JSON.parse(stdout.trim()) as OAuthTokenSet;
    } catch {
      return null;
    }
  }

  async loadCodexTokens(): Promise<OAuthTokenSet | null> {
    try {
      const raw = await readFile(path.join(os.homedir(), ".codex", "auth.json"), "utf8");
      const parsed = JSON.parse(raw) as {
        access?: string;
        refresh?: string;
        expires?: number;
        accountId?: string;
        account_id?: string;
        tokens?: {
          access_token?: string;
          refresh_token?: string;
          id_token?: string;
          account_id?: string;
          accountId?: string;
          expires_at?: number;
          expires_in?: number;
        };
      };
      if (parsed.access) {
        return {
          accessToken: parsed.access,
          refreshToken: parsed.refresh,
          expiresAt: parsed.expires ? new Date(parsed.expires).toISOString() : undefined,
          accountId: parsed.accountId ?? parsed.account_id ?? accountIdFromToken(parsed.access),
          scopes: [...OPENAI_OAUTH_SCOPES]
        };
      }
      if (!parsed.tokens?.access_token) {
        return null;
      }
      return {
        accessToken: parsed.tokens.access_token,
        refreshToken: parsed.tokens.refresh_token,
        expiresAt: parsed.tokens.expires_at ? new Date(parsed.tokens.expires_at * 1000).toISOString() : undefined,
        email: emailFromIdToken(parsed.tokens.id_token),
        accountId: parsed.tokens.account_id ?? parsed.tokens.accountId ?? accountIdFromToken(parsed.tokens.id_token) ?? accountIdFromToken(parsed.tokens.access_token),
        scopes: [...OPENAI_OAUTH_SCOPES]
      };
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

  async saveApiKey(apiKey: string) {
    await runKeychainWrite(
      [
        "add-generic-password",
        "-a",
        this.apiKeychainAccount,
        "-s",
        this.apiKeychainService,
        "-w",
        apiKey,
        "-U"
      ],
      "Could not store the OpenAI API key in macOS Keychain."
    );
  }

  async saveChatGPTAccountId(accountId: string) {
    await runKeychainWrite(
      [
        "add-generic-password",
        "-a",
        this.chatGPTAccountIdKeychainAccount,
        "-s",
        this.keychainService,
        "-w",
        accountId.trim(),
        "-U"
      ],
      "Could not store the ChatGPT account id in macOS Keychain."
    );
  }

  async loadChatGPTAccountId() {
    const current = await this.loadChatGPTAccountIdFromService(this.keychainService);
    if (current) return current;
    const legacy = await this.loadChatGPTAccountIdFromService(this.legacyKeychainService);
    if (legacy) {
      await this.saveChatGPTAccountId(legacy);
    }
    return legacy;
  }

  private async loadChatGPTAccountIdFromService(service: string) {
    try {
      const { stdout } = await execFileAsync("security", [
        "find-generic-password",
        "-a",
        this.chatGPTAccountIdKeychainAccount,
        "-s",
        service,
        "-w"
      ]);
      return stdout.trim() || undefined;
    } catch {
      return undefined;
    }
  }

  async deleteChatGPTAccountId() {
    try {
      await execFileAsync("security", [
        "delete-generic-password",
        "-a",
        this.chatGPTAccountIdKeychainAccount,
        "-s",
        this.keychainService
      ]);
    } catch {
      // Deletion is idempotent for callers.
    }
  }

  async loadApiKey() {
    const current = await this.loadApiKeyFromService(this.apiKeychainService);
    if (current) return current;
    const legacy = await this.loadApiKeyFromService(this.legacyApiKeychainService);
    if (legacy) {
      await this.saveApiKey(legacy);
    }
    return legacy;
  }

  private async loadApiKeyFromService(service: string) {
    try {
      const { stdout } = await execFileAsync("security", [
        "find-generic-password",
        "-a",
        this.apiKeychainAccount,
        "-s",
        service,
        "-w"
      ]);
      return stdout.trim() || undefined;
    } catch {
      return undefined;
    }
  }

  async deleteApiKey() {
    try {
      await execFileAsync("security", [
        "delete-generic-password",
        "-a",
        this.apiKeychainAccount,
        "-s",
        this.apiKeychainService
      ]);
    } catch {
      // Deletion is idempotent for callers.
    }
  }

  async status() {
    const tokens = await this.loadTokens();
    const needsRefresh = await this.needsRefresh();
    const apiKeyConfigured = Boolean(process.env.OPENAI_API_KEY || await this.loadApiKey());
    const account = await this.resolveChatGPTAccountId(tokens ?? undefined);
    const oauthUsable = Boolean(tokens?.accessToken) && (!needsRefresh || Boolean(tokens?.refreshToken));
    const oauthLiveReady = oauthUsable && Boolean(account.accountId);
    const liveCredentialConfigured = apiKeyConfigured || oauthLiveReady;
    return {
      clientId: CODEX_PUBLIC_CLIENT_ID,
      connected: oauthUsable,
      hasTokens: Boolean(tokens),
      email: tokens?.email,
      expiresAt: tokens?.expiresAt,
      needsRefresh,
      scopes: tokens?.scopes ?? [],
      chatGPTAccountId: account.accountId,
      chatGPTAccountIdSource: account.source,
      chatGPTAccountIdConfigured: Boolean(account.accountId),
      apiKeyConfigured,
      apiKeySource: process.env.OPENAI_API_KEY ? "environment" : apiKeyConfigured ? "keychain" : undefined,
      liveCredentialConfigured,
      liveCredentialSource: process.env.OPENAI_API_KEY
        ? "environment"
        : oauthLiveReady ? "codex-oauth" : apiKeyConfigured ? "keychain" : undefined,
      whamBaseURL: OPENAI_WHAM_BASE_URL,
      liveReadinessError: oauthUsable && !account.accountId && !apiKeyConfigured
        ? "Codex OAuth is connected, but live WHAM runs need a ChatGPT account id. Configure ChatGPT-Account-Id in Settings or sign in with Codex so ~/.codex/auth.json contains tokens.account_id."
        : undefined
    };
  }

  async needsRefresh(now = new Date()) {
    const tokens = await this.loadTokens();
    if (!tokens?.expiresAt) return false;
    return new Date(tokens.expiresAt).getTime() - now.getTime() < 60_000;
  }

  private async resolveChatGPTAccountId(tokens?: OAuthTokenSet): Promise<{ accountId?: string; source?: AccountIdSource }> {
    const envAccountId = process.env.MULTIAGENT_CHATGPT_ACCOUNT_ID ?? process.env.CHATGPT_ACCOUNT_ID;
    if (envAccountId?.trim()) {
      return { accountId: envAccountId.trim(), source: "environment" };
    }
    const configured = await this.loadChatGPTAccountId();
    if (configured) {
      return { accountId: configured, source: "keychain" };
    }
    const tokenAccountId = tokens?.accountId ?? accountIdFromToken(tokens?.accessToken);
    if (tokenAccountId) {
      return { accountId: tokenAccountId, source: "oauth-token" };
    }
    const codexTokens = await this.loadCodexTokens();
    if (codexTokens?.accountId) {
      return { accountId: codexTokens.accountId, source: "codex-auth" };
    }
    return {};
  }
}

async function runKeychainWrite(args: string[], publicMessage: string) {
  try {
    await execFileAsync("security", args);
  } catch (error) {
    const stderr = typeof (error as { stderr?: unknown }).stderr === "string"
      ? (error as { stderr: string }).stderr.trim()
      : "";
    const suffix = stderr ? ` ${redactKeychainOutput(stderr)}` : "";
    throw new Error(`${publicMessage}${suffix}`);
  }
}

function redactKeychainOutput(output: string) {
  return output
    .replace(/(-w\s+)(\S+)/g, "$1[redacted]")
    .replace(/(access[_-]?token["']?\s*[:=]\s*["']?)[^"',\s}]+/gi, "$1[redacted]")
    .replace(/(refresh[_-]?token["']?\s*[:=]\s*["']?)[^"',\s}]+/gi, "$1[redacted]")
    .replace(/(api[_-]?key["']?\s*[:=]\s*["']?)[^"',\s}]+/gi, "$1[redacted]");
}

function safeToken(length = 32) {
  return base64Url(crypto.randomBytes(length));
}

function base64Url(input: Buffer) {
  return input.toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function emailFromIdToken(idToken?: string) {
  if (!idToken) return undefined;
  const decoded = jwtPayload(idToken);
  return typeof decoded?.email === "string" ? decoded.email : undefined;
}

function accountIdFromToken(token?: string) {
  const decoded = jwtPayload(token);
  if (!decoded) return undefined;
  const direct = decoded.chatgpt_account_id;
  if (typeof direct === "string" && direct) return direct;
  const directAccount = decoded.account_id;
  if (typeof directAccount === "string" && directAccount) return directAccount;
  const flattened = decoded["https://api.openai.com/auth.chatgpt_account_id"];
  if (typeof flattened === "string" && flattened) return flattened;
  const authNamespace = decoded["https://api.openai.com/auth"];
  if (isRecord(authNamespace) && typeof authNamespace.chatgpt_account_id === "string") {
    return authNamespace.chatgpt_account_id;
  }
  if (isRecord(authNamespace) && typeof authNamespace.account_id === "string") {
    return authNamespace.account_id;
  }
  if (Array.isArray(decoded.organizations)) {
    const firstOrg = decoded.organizations.find(isRecord);
    if (typeof firstOrg?.id === "string") return firstOrg.id;
  }
  return undefined;
}

function jwtPayload(token?: string): Record<string, unknown> | undefined {
  if (!token) return undefined;
  const [, payload] = token.split(".");
  if (!payload) return undefined;
  try {
    return JSON.parse(Buffer.from(payload.replace(/-/g, "+").replace(/_/g, "/"), "base64").toString("utf8")) as Record<string, unknown>;
  } catch {
    return undefined;
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
