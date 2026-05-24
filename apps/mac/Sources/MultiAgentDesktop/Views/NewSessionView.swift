import SwiftUI

struct NewSessionView: View {
    @Bindable var store: SessionStore
    @State private var prompt = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Session")
                .font(.title2.weight(.semibold))

            TextEditor(text: $prompt)
                .font(.body)
                .frame(minWidth: 420, idealWidth: 620, maxWidth: 720, minHeight: 180, idealHeight: 260, maxHeight: 320)
                .scrollContentBackground(.hidden)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))

            Picker("Mode", selection: $store.debugMode) {
                Text("Live").tag(false)
                Text("Debug").tag(true)
            }
            .pickerStyle(.segmented)
            .disabled(store.isCreatingSession)

            Text(store.debugMode ? "Debug uses deterministic pre-programmed agent I/O." : "Live uses OpenAI authentication from Settings or OPENAI_API_KEY.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !store.debugMode && store.authStatus?.connected != true {
                Label("Live mode needs OpenAI OAuth in Settings or OPENAI_API_KEY on the daemon.", systemImage: "person.badge.key")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if store.isCreatingSession {
                ProgressView("Creating session...")
                    .controlSize(.small)
            }

            if let error = store.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    store.cancelNewSession()
                }
                Button("Create") {
                    store.createSession(prompt: prompt)
                }
                .buttonStyle(.borderedProminent)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isCreatingSession)
            }
        }
        .padding()
        .task {
            store.connectAndRefresh()
            store.refreshAuthStatus()
        }
    }
}
