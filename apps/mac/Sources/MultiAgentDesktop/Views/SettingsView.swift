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
                TextField("Daemon Port", value: $daemonPort, formatter: Self.portFormatter)
                    .frame(width: 220)
            }
        }
        .formStyle(.grouped)
    }

    private static let portFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.usesGroupingSeparator = false
        formatter.minimum = 1
        formatter.maximum = 65_535
        return formatter
    }()
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
                    saveAPIKeyButton

                    Button(role: .destructive) {
                        store.disconnectOpenAIAPIKey()
                    } label: {
                        Label("Remove API Key", systemImage: "xmark.circle")
                    }
                    .disabled(store.authStatus?.apiKeyConfigured != true || store.authStatus?.apiKeySource == "environment")
                    .help("Remove the stored API key")
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
                LabeledContent("Live Runs") {
                    Text(liveStatusLabel)
                        .foregroundStyle(store.authStatus?.liveCredentialConfigured == true ? .green : .orange)
                }
                if let email = store.authStatus?.email {
                    LabeledContent("Account", value: email)
                }
                if let accountId = store.authStatus?.chatGPTAccountId {
                    LabeledContent("ChatGPT Account ID") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(abbreviatedIdentifier(accountId))
                                .textSelection(.enabled)
                            if let source = store.authStatus?.chatGPTAccountIdSource {
                                Text(source)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                LabeledContent("Client ID", value: abbreviatedIdentifier(store.authStatus?.clientId ?? "app_EMoamEEZ73f0CkXaXp7hrann"))
                if store.authStatus?.liveCredentialSource == "codex-oauth" {
                    LabeledContent("Runtime", value: "Codex OAuth via WHAM")
                }
                if let whamBaseURL = store.authStatus?.whamBaseURL {
                    LabeledContent("WHAM Base URL", value: whamBaseURL)
                }

                HStack {
                    Button {
                        store.beginOpenAIOAuth()
                    } label: {
                        Label("Set Up…", systemImage: "person.badge.key")
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Start the OpenAI OAuth setup flow")

                    Button {
                        store.refreshAuthStatus()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .help("Refresh OpenAI authentication status")

                    Button(role: .destructive) {
                        store.disconnectOpenAIOAuth()
                    } label: {
                        Label("Disconnect", systemImage: "xmark.circle")
                    }
                    .disabled(store.authStatus?.connected != true)
                    .help("Disconnect the stored OpenAI OAuth credentials")
                }
                if let liveReadinessError = store.authStatus?.liveReadinessError {
                    Text(liveReadinessError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let error = store.lastError {
                    Text(sanitizedDisplayError(error))
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Text("Codex OAuth is used for live agent runs through the Codex WHAM backend. API keys remain available as a fallback.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("ChatGPT Account ID") {
                TextField("ChatGPT-Account-Id", text: $store.chatGPTAccountIdInput)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    saveAccountIDButton

                    Button(role: .destructive) {
                        store.disconnectChatGPTAccountId()
                    } label: {
                        Label("Forget Account ID", systemImage: "xmark.circle")
                    }
                    .disabled(store.authStatus?.chatGPTAccountIdSource != "keychain")
                    .help("Remove the stored ChatGPT account id")
                }
                Text("Usually this is discovered from the OAuth token or ~/.codex/auth.json. Configure it here only when live runs report a missing account id.")
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

    private var liveStatusLabel: String {
        if store.authStatus?.liveCredentialConfigured == true {
            return "Ready"
        }
        return "Not Ready"
    }

    @ViewBuilder
    private var saveAPIKeyButton: some View {
        let canSave = !store.openAIApiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if canSave {
            Button {
                store.saveOpenAIAPIKey()
            } label: {
                Label("Save API Key", systemImage: "key")
            }
            .buttonStyle(.borderedProminent)
            .help("Store this API key in macOS Keychain")
        } else {
            Button {
                store.saveOpenAIAPIKey()
            } label: {
                Label("Save API Key", systemImage: "key")
            }
            .buttonStyle(.bordered)
            .disabled(true)
            .help("Enter an API key to enable saving")
        }
    }

    @ViewBuilder
    private var saveAccountIDButton: some View {
        let canSave = !store.chatGPTAccountIdInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if canSave {
            Button {
                store.saveChatGPTAccountId()
            } label: {
                Label("Save Account ID", systemImage: "person.text.rectangle")
            }
            .buttonStyle(.borderedProminent)
            .help("Store this ChatGPT account id in macOS Keychain")
        } else {
            Button {
                store.saveChatGPTAccountId()
            } label: {
                Label("Save Account ID", systemImage: "person.text.rectangle")
            }
            .buttonStyle(.bordered)
            .disabled(true)
            .help("Enter an account id to enable saving")
        }
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
                .help("Refresh MCP server status from Codex configuration")
                Button {
                    store.reconnectMCPServers()
                } label: {
                    Label("Reconnect All", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .help("Reconnect all configured MCP servers")
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
    @State private var expanded = false

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
            Text(commandSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
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
                .help("Reconnect this MCP server")
                Button {
                    store.beginMCPAuth(serverId: server.id)
                } label: {
                    Label("Authenticate…", systemImage: "person.badge.key")
                }
                .disabled(!server.authenticationSupported)
                .help("Start authentication for this MCP server")
                Text(authRowSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            DisclosureGroup("Details", isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 4) {
                    detailLine("Command", commandSummary)
                    detailLine("Auth", server.authInstructions ?? "Authentication is handled by the configured command or server process.")
                    detailLine("ID", server.id)
                }
                .padding(.top, 2)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var commandSummary: String {
        server.url ?? ([server.command, server.args.joined(separator: " ")].compactMap { $0 }.joined(separator: " "))
    }

    private var authRowSummary: String {
        if server.authenticationSupported {
            return "OAuth setup available"
        }
        return "Auth handled by command"
    }

    private func detailLine(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text(value.isEmpty ? "Not configured" : value)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
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

private func abbreviatedIdentifier(_ value: String) -> String {
    guard value.count > 16 else { return value }
    return "\(value.prefix(8))...\(value.suffix(4))"
}
