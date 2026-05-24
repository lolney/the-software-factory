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
        }
        .padding()
        .frame(width: 520)
        .task {
            store.connectAndRefresh()
            store.refreshAuthStatus()
        }
    }
}
