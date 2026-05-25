import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { CodexIntegrationManager } from "./codexIntegrationManager.js";

describe("CodexIntegrationManager", () => {
  it("reads MCP servers and installed skills from Codex config", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "codex-integrations-"));
    try {
      await writeFile(path.join(root, "config.toml"), [
        "[mcp_servers.docs]",
        "command = \"npx\"",
        "args = [\"-y\", \"docs-mcp\"]",
        "",
        "[mcp_servers.remote]",
        "url = \"http://127.0.0.1:5050/mcp\"",
        ""
      ].join("\n"), "utf8");
      const skillDir = path.join(root, "skills", "release-notes");
      await mkdir(skillDir, { recursive: true });
      await writeFile(path.join(skillDir, "SKILL.md"), [
        "---",
        "name: release-notes",
        "description: Draft release notes from commits.",
        "---",
        ""
      ].join("\n"), "utf8");

      const catalog = await new CodexIntegrationManager(root).listCatalog();

      expect(catalog.mcpServers).toEqual(expect.arrayContaining([
        expect.objectContaining({ name: "docs", transport: "stdio", command: "npx", args: ["-y", "docs-mcp"] }),
        expect.objectContaining({ name: "remote", transport: "streamable_http", url: "http://127.0.0.1:5050/mcp" })
      ]));
      expect(catalog.skills).toEqual(expect.arrayContaining([
        expect.objectContaining({ name: "release-notes", description: "Draft release notes from commits." })
      ]));
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });
});
