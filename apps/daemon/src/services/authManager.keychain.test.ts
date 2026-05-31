import { beforeEach, describe, expect, it, vi } from "vitest";

const execFileMock = vi.hoisted(() => vi.fn());

vi.mock("node:child_process", () => ({
  execFile: execFileMock
}));

import { AuthManager } from "./authManager.js";

describe("AuthManager keychain errors", () => {
  beforeEach(() => {
    execFileMock.mockReset();
  });

  it("disconnects OAuth credentials from current and legacy keychain services", async () => {
    execFileMock.mockImplementation((_command: string, _args: string[], callback: (error: Error & { stderr?: string }) => void) => {
      callback(Object.assign(new Error("not found"), { stderr: "security: SecKeychainSearchCopyNext: The specified item could not be found." }));
    });

    await new AuthManager().deleteTokens();

    const deletedServices = execFileMock.mock.calls.map(([, args]) => serviceNameFromSecurityArgs(args));
    expect(deletedServices).toContain("local.softwarefactory.codex-oauth");
    expect(deletedServices).toContain("local.multiagent.codex-oauth");
  });

  it("disconnects ancillary credentials from current and legacy keychain services", async () => {
    execFileMock.mockImplementation((_command: string, _args: string[], callback: (error: Error & { stderr?: string }) => void) => {
      callback(Object.assign(new Error("not found"), { stderr: "security: SecKeychainSearchCopyNext: The specified item could not be found." }));
    });

    const manager = new AuthManager();
    await manager.deleteChatGPTAccountId();
    await manager.deleteApiKey();

    const deletedEntries = execFileMock.mock.calls.map(([, args]) => ({
      account: accountNameFromSecurityArgs(args),
      service: serviceNameFromSecurityArgs(args)
    }));
    expect(deletedEntries).toEqual(expect.arrayContaining([
      { account: "chatgpt-account-id", service: "local.softwarefactory.codex-oauth" },
      { account: "chatgpt-account-id", service: "local.multiagent.codex-oauth" },
      { account: "openai-api-key", service: "local.softwarefactory.openai-api-key" },
      { account: "openai-api-key", service: "local.multiagent.openai-api-key" }
    ]));
  });

  it("does not leak token payloads when keychain writes fail", async () => {
    execFileMock.mockImplementation((_command: string, _args: string[], callback: (error: Error & { stderr?: string }) => void) => {
      const error = Object.assign(
        new Error("Command failed: security add-generic-password -w {\"accessToken\":\"secret-access\"}"),
        { stderr: "security add-generic-password failed" }
      );
      callback(error);
    });

    await expect(new AuthManager().saveTokens({
      accessToken: "secret-access",
      refreshToken: "secret-refresh"
    })).rejects.toThrow("Could not store OpenAI OAuth credentials in macOS Keychain.");

    try {
      await new AuthManager().saveTokens({
        accessToken: "secret-access",
        refreshToken: "secret-refresh"
      });
    } catch (error) {
      expect(String((error as Error).message)).not.toContain("secret-access");
      expect(String((error as Error).message)).not.toContain("secret-refresh");
    }
  });
});

function serviceNameFromSecurityArgs(args: unknown) {
  if (!Array.isArray(args)) return undefined;
  const serviceIndex = args.indexOf("-s");
  return typeof args[serviceIndex + 1] === "string" ? args[serviceIndex + 1] : undefined;
}

function accountNameFromSecurityArgs(args: unknown) {
  if (!Array.isArray(args)) return undefined;
  const accountIndex = args.indexOf("-a");
  return typeof args[accountIndex + 1] === "string" ? args[accountIndex + 1] : undefined;
}
