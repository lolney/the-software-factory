import { readFile, readdir } from "node:fs/promises";
import { existsSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { MCPServerStdio, MCPServerStreamableHttp, type MCPServer } from "@openai/agents";
import type { MCPServerCatalogItem, SkillCatalogItem } from "@software-factory/shared";

type RawMCPServer = {
  name: string;
  command?: string;
  args: string[];
  env?: Record<string, string>;
  cwd?: string;
  url?: string;
  authUrl?: string;
  transport: MCPServerCatalogItem["transport"];
};

export class CodexIntegrationManager {
  private connected = new Map<string, MCPServer>();
  private errors = new Map<string, string>();

  constructor(private readonly codexHome = process.env.CODEX_HOME ?? path.join(os.homedir(), ".codex")) {}

  async listCatalog() {
    return {
      mcpServers: await this.listMCPServers(),
      skills: await this.listSkills()
    };
  }

  async listMCPServers(): Promise<MCPServerCatalogItem[]> {
    const servers = await this.readMCPServerConfig();
    return servers.map((server) => ({
      id: safeId(server.name),
      name: server.name,
      transport: server.transport,
      command: server.command,
      args: server.args,
      url: server.url,
      authenticationSupported: Boolean(server.authUrl),
      authStatus: server.authUrl ? "supported_unknown" : "not_supported",
      authUrl: server.authUrl,
      authInstructions: server.authUrl
        ? "Authentication support is configured. Open the authentication URL, complete the server-specific flow, then reconnect."
        : "This Codex MCP server entry does not expose an authentication URL. Authentication is handled by the configured command or server process.",
      status: this.connected.has(server.name) ? "connected" : this.errors.has(server.name) ? "failed" : "configured",
      error: this.errors.get(server.name)
    }));
  }

  async listSkills(): Promise<SkillCatalogItem[]> {
    const roots = [
      path.join(this.codexHome, "skills"),
      path.join(this.codexHome, "skills", ".system"),
      path.join(this.codexHome, "plugins", "cache")
    ];
    const skills: SkillCatalogItem[] = [];
    for (const root of roots) {
      if (!existsSync(root)) continue;
      for (const skillPath of await findSkillFiles(root)) {
        const entryName = path.basename(path.dirname(skillPath));
        const raw = await readFile(skillPath, "utf8");
        const meta = parseSkillFrontmatter(raw);
        skills.push({
          id: safeId(path.relative(this.codexHome, skillPath)),
          name: meta.name || entryName,
          description: meta.description || "",
          path: skillPath,
          source: root.includes(`${path.sep}plugins${path.sep}`) ? "codex-plugin" : root.includes(`${path.sep}.system`) ? "codex-system" : "codex-user"
        });
      }
    }
    return skills.sort((a, b) => a.name.localeCompare(b.name));
  }

  async getConnectedMCPServers(): Promise<MCPServer[]> {
    await this.connectMissingMCPServers();
    return [...this.connected.values()];
  }

  async beginMCPAuth(serverId: string) {
    const server = (await this.readMCPServerConfig()).find((candidate) => safeId(candidate.name) === serverId);
    if (!server) throw new Error(`Unknown MCP server: ${serverId}`);
    return {
      authorizationUrl: server.authUrl,
      message: server.authUrl
        ? "Open the MCP server authentication URL, complete the server-specific flow, then reconnect the server."
        : "This MCP server does not advertise an authentication URL in Codex config.",
      integrations: await this.listCatalog()
    };
  }

  async reconnectMCPServers(options: { serverId?: string; failedOnly?: boolean; suppressErrors?: boolean } = {}) {
    const configured = await this.readMCPServerConfig();
    const selected = configured.filter((server) => {
      if (options.serverId && safeId(server.name) !== options.serverId) return false;
      if (options.failedOnly && !this.errors.has(server.name)) return false;
      return true;
    });

    for (const server of selected) {
      await this.connected.get(server.name)?.close().catch(() => undefined);
      this.connected.delete(server.name);
      this.errors.delete(server.name);
      try {
        const instance = this.createMCPServer(server);
        if (!instance) continue;
        await instance.connect();
        this.connected.set(server.name, instance);
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        this.errors.set(server.name, message);
      }
    }
    return this.listCatalog();
  }

  private async connectMissingMCPServers() {
    const configured = await this.readMCPServerConfig();
    for (const server of configured) {
      if (this.connected.has(server.name) || this.errors.has(server.name)) continue;
      try {
        const instance = this.createMCPServer(server);
        if (!instance) continue;
        await instance.connect();
        this.connected.set(server.name, instance);
      } catch (error) {
        this.errors.set(server.name, error instanceof Error ? error.message : String(error));
      }
    }
  }

  private createMCPServer(server: RawMCPServer): MCPServer | undefined {
    if (server.transport === "streamable_http" && server.url) {
      return new MCPServerStreamableHttp({
        name: server.name,
        url: server.url,
        cacheToolsList: true
      });
    }
    if (server.command) {
      return new MCPServerStdio({
        name: server.name,
        command: server.command,
        args: server.args,
        env: server.env,
        cwd: server.cwd,
        cacheToolsList: true
      });
    }
    return undefined;
  }

  private async readMCPServerConfig(): Promise<RawMCPServer[]> {
    const configPath = path.join(this.codexHome, "config.toml");
    if (!existsSync(configPath)) return [];
    const raw = await readFile(configPath, "utf8");
    const sections = parseTomlSections(raw);
    const servers: RawMCPServer[] = [];
    for (const [section, values] of sections) {
      const match = section.match(/^mcp_servers\.(.+)$/);
      if (!match || section.includes(".tools.")) continue;
      const name = unquote(match[1]);
      const command = stringValue(values.command);
      const args = arrayValue(values.args);
      const env = objectValue(values.env);
      const cwd = stringValue(values.cwd);
      const url = stringValue(values.url);
      const authUrl = stringValue(values.auth_url) ?? stringValue(values.authUrl) ?? stringValue(values.oauth_url);
      servers.push({
        name,
        command,
        args,
        env,
        cwd,
        url,
        authUrl,
        transport: url ? "streamable_http" : command ? "stdio" : "unknown"
      });
    }
    return servers.sort((a, b) => a.name.localeCompare(b.name));
  }
}

async function findSkillFiles(root: string, depth = 0): Promise<string[]> {
  if (depth > 7) return [];
  const skill = path.join(root, "SKILL.md");
  if (existsSync(skill)) return [skill];
  const files: string[] = [];
  for (const entry of await readdir(root, { withFileTypes: true }).catch(() => [])) {
    if (!entry.isDirectory()) continue;
    if (entry.name === "node_modules" || entry.name.startsWith(".")) continue;
    files.push(...await findSkillFiles(path.join(root, entry.name), depth + 1));
  }
  return files;
}

function parseTomlSections(raw: string) {
  const sections = new Map<string, Record<string, string>>();
  let current = "";
  sections.set(current, {});
  for (const line of raw.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const section = trimmed.match(/^\[(.+)]$/);
    if (section) {
      current = section[1];
      sections.set(current, {});
      continue;
    }
    const equals = trimmed.indexOf("=");
    if (equals < 0) continue;
    sections.get(current)![trimmed.slice(0, equals).trim()] = trimmed.slice(equals + 1).trim();
  }
  return sections;
}

function stringValue(raw: string | undefined) {
  if (!raw) return undefined;
  return unquote(raw);
}

function arrayValue(raw: string | undefined) {
  if (!raw) return [];
  const match = raw.match(/^\[(.*)]$/);
  if (!match) return [];
  return match[1]
    .split(",")
    .map((part) => unquote(part.trim()))
    .filter(Boolean);
}

function objectValue(raw: string | undefined) {
  if (!raw?.startsWith("{")) return undefined;
  const entries: Record<string, string> = {};
  for (const part of raw.replace(/^\{|\}$/g, "").split(",")) {
    const equals = part.indexOf("=");
    if (equals < 0) continue;
    entries[unquote(part.slice(0, equals).trim())] = unquote(part.slice(equals + 1).trim());
  }
  return entries;
}

function unquote(value: string) {
  return value.replace(/^"(.*)"$/, "$1").replace(/\\"/g, "\"");
}

function parseSkillFrontmatter(raw: string) {
  const meta: Record<string, string> = {};
  const match = raw.match(/^---\n([\s\S]*?)\n---/);
  if (!match) return meta;
  for (const line of match[1].split(/\r?\n/)) {
    const index = line.indexOf(":");
    if (index < 0) continue;
    meta[line.slice(0, index).trim()] = line.slice(index + 1).trim();
  }
  return meta;
}

function safeId(value: string) {
  return value.replace(/[^A-Za-z0-9_-]/g, "_");
}
