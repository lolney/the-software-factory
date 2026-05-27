import { describe, expect, it, vi } from "vitest";

const execFileMock = vi.hoisted(() => vi.fn());

vi.mock("node:child_process", () => ({
  execFile: execFileMock
}));

import { AuthManager } from "./authManager.js";

describe("AuthManager keychain errors", () => {
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
