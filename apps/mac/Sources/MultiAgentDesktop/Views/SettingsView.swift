import SwiftUI

struct SettingsView: View {
    @Bindable var store: SessionStore
    @AppStorage("daemonPort") private var daemonPort = 3767

    var body: some View {
        Form {
            Section("Daemon") {
                TextField("Daemon Port", value: $daemonPort, format: .number)
                    .frame(width: 220)
            }

            Section("OpenAI OAuth") {
                LabeledContent("Status") {
                    Text(store.authStatus?.connected == true ? "Connected" : "Not Connected")
                        .foregroundStyle(store.authStatus?.connected == true ? .green : .secondary)
                }
                if let email = store.authStatus?.email {
                    LabeledContent("Account", value: email)
                }
                LabeledContent("Client ID", value: store.authStatus?.clientId ?? "app_EMoamEEZ73f0CkXaXp7hrann")

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
            }

            Section("Codex MCP Servers") {
                if store.integrations.mcpServers.isEmpty {
                    Text("No MCP servers found in ~/.codex/config.toml.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.integrations.mcpServers) { server in
                        VStack(alignment: .leading, spacing: 4) {
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
                            }
                        }
                    }
                }
                HStack {
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
            }

            Section("Codex Skills") {
                if store.integrations.skills.isEmpty {
                    Text("No installed user or plugin skills found in the Codex config directories.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(skillSources, id: \.self) { source in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(source.replacingOccurrences(of: "codex-", with: "").capitalized)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(store.integrations.skills.filter { $0.source == source }) { skill in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
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
            }
        }
        .padding()
        .frame(width: 680)
        .task {
            store.connectAndRefresh()
            store.refreshAuthStatus()
            store.refreshIntegrations()
        }
    }

    private var skillSources: [String] {
        Array(Set(store.integrations.skills.map(\.source))).sorted()
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
