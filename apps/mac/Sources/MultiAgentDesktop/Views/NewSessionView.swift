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

            Toggle("Deterministic Debug Session", isOn: $store.debugMode)
                .disabled(store.isCreatingSession)

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
                    store.presentNewSession = false
                }
                .disabled(store.isCreatingSession)
                Button("Create") {
                    store.createSession(prompt: prompt)
                }
                .buttonStyle(.borderedProminent)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isCreatingSession)
            }
        }
        .padding()
    }
}
