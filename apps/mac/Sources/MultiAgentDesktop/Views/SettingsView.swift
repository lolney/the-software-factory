import SwiftUI

struct SettingsView: View {
    @Bindable var store: SessionStore
    @AppStorage("daemonPort") private var daemonPort = 3767

    var body: some View {
        TabView {
            DaemonSettingsPane(daemonPort: $daemonPort)
                .tabItem {
                    Label("Daemon", systemImage: "server.rack")
                }

            AuthSettingsPane(store: store)
                .tabItem {
                    Label("Auth", systemImage: "person.badge.key")
                }

            MCPServersSettingsPane(store: store)
                .tabItem {
                    Label("MCP Servers", systemImage: "point.3.connected.trianglepath.dotted")
                }

            SkillsSettingsPane(skills: store.integrations.skills)
                .tabItem {
                    Label("Skills", systemImage: "wand.and.stars")
                }
        }
        .padding()
        .frame(width: 720, height: 520)
        .task {
            store.connectAndRefresh()
            store.refreshAuthStatus()
            store.refreshIntegrations()
        }
    }
}

private struct DaemonSettingsPane: View {
    @Binding var daemonPort: Int

    var body: some View {
        Form {
            Section("Daemon") {
                TextField("Daemon Port", value: $daemonPort, format: .number)
                    .frame(width: 220)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AuthSettingsPane: View {
    @Bindable var store: SessionStore

    var body: some View {
        Form {
            Section("OpenAI API Key") {
                LabeledContent("Status") {
                    Text(store.authStatus?.apiKeyConfigured == true ? "Configured" : "Not Configured")
                        .foregroundStyle(store.authStatus?.apiKeyConfigured == true ? .green : .secondary)
                }
                if let source = store.authStatus?.apiKeySource {
                    LabeledContent("Source", value: source)
                }
                SecureField("OpenAI API key", text: $store.openAIApiKeyInput)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button {
                        store.saveOpenAIAPIKey()
                    } label: {
                        Label("Save API Key", systemImage: "key")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.openAIApiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button(role: .destructive) {
                        store.disconnectOpenAIAPIKey()
                    } label: {
                        Label("Remove API Key", systemImage: "xmark.circle")
                    }
                    .disabled(store.authStatus?.apiKeyConfigured != true || store.authStatus?.apiKeySource == "environment")
                }
                Text("Live agent runs prefer Codex OAuth. This API key is a fallback or developer override and is stored in macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("OpenAI OAuth") {
                LabeledContent("Status") {
                    Text(authStatusLabel)
                        .foregroundStyle(store.authStatus?.connected == true ? .green : .secondary)
                }
                if let email = store.authStatus?.email {
                    LabeledContent("Account", value: email)
                }
                LabeledContent("Client ID", value: store.authStatus?.clientId ?? "app_EMoamEEZ73f0CkXaXp7hrann")
                if store.authStatus?.liveCredentialSource == "codex-oauth" {
                    LabeledContent("Live Runs", value: "Codex OAuth via WHAM")
                }
                if let whamBaseURL = store.authStatus?.whamBaseURL {
                    LabeledContent("WHAM Base URL", value: whamBaseURL)
                }

                HStack {
                    Button {
                        store.beginOpenAIOAuth()
                    } label: {
                        Label("Set Up", systemImage: "person.badge.key")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        store.refreshAuthStatus()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }

                    Button(role: .destructive) {
                        store.disconnectOpenAIOAuth()
                    } label: {
                        Label("Disconnect", systemImage: "xmark.circle")
                    }
                    .disabled(store.authStatus?.connected != true)
                }
                if let error = store.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Text("Codex OAuth is used for live agent runs through the Codex WHAM backend. API keys remain available as a fallback.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var authStatusLabel: String {
        if store.authStatus?.connected == true { return "Connected" }
        return "Not Connected"
    }
}

private struct MCPServersSettingsPane: View {
    @Bindable var store: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Codex MCP Servers")
                    .font(.headline)
                Spacer()
                Button {
                    store.refreshIntegrations()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                Button {
                    store.reconnectMCPServers()
                } label: {
                    Label("Reconnect All", systemImage: "point.3.connected.trianglepath.dotted")
                }
            }

            if store.integrations.mcpServers.isEmpty {
                ContentUnavailableView("No MCP Servers", systemImage: "point.3.connected.trianglepath.dotted", description: Text("No MCP servers found in ~/.codex/config.toml."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(store.integrations.mcpServers) { server in
                            MCPServerRow(server: server, store: store)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

private struct MCPServerRow: View {
    let server: MCPServerCatalogItem
    @Bindable var store: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(server.name)
                    .font(.headline)
                Spacer()
                Text(authLabel(server))
                    .font(.caption)
                    .foregroundStyle(server.authenticationSupported ? .blue : .secondary)
                Text(server.status)
                    .font(.caption)
                    .foregroundStyle(server.status == "connected" ? .green : server.status == "failed" ? .red : .secondary)
            }
            Text(server.url ?? ([server.command, server.args.joined(separator: " ")].compactMap { $0 }.joined(separator: " ")))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let error = server.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            HStack {
                Button {
                    store.reconnectMCPServers(serverId: server.id)
                } label: {
                    Label("Reconnect", systemImage: "arrow.triangle.2.circlepath")
                }
                Button {
                    store.beginMCPAuth(serverId: server.id)
                } label: {
                    Label("Authenticate", systemImage: "person.badge.key")
                }
                .disabled(!server.authenticationSupported)
                Text(server.authInstructions ?? "Reconnect retries the configured transport.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    private func authLabel(_ server: MCPServerCatalogItem) -> String {
        switch server.authStatus {
        case "supported_unknown":
            return "Auth: supported"
        case "connected":
            return "Auth: connected"
        case "failed":
            return "Auth: failed"
        default:
            return "Auth: not supported"
        }
    }
}

private struct SkillsSettingsPane: View {
    let skills: [SkillCatalogItem]

    private var skillSources: [String] {
        Array(Set(skills.map(\.source))).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Codex Skills")
                    .font(.headline)
                Spacer()
                Text("\(skills.count) installed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if skills.isEmpty {
                ContentUnavailableView("No Skills", systemImage: "wand.and.stars", description: Text("No installed user or plugin skills found in the Codex config directories."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(skillSources, id: \.self) { source in
                            SkillSourceSection(source: source, skills: skills.filter { $0.source == source })
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

private struct SkillSourceSection: View {
    let source: String
    let skills: [SkillCatalogItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(source.replacingOccurrences(of: "codex-", with: "").capitalized)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(skills) { skill in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(skill.name)
                            .font(.headline)
                        Text(skill.source.replacingOccurrences(of: "codex-", with: ""))
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .background(.quaternary, in: Capsule())
                    }
                    if !skill.description.isEmpty {
                        Text(skill.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Text(skill.path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
    }
}
