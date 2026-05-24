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
                .frame(width: 620, height: 260)
                .scrollContentBackground(.hidden)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))

            Toggle("Deterministic Debug Session", isOn: $store.debugMode)

            HStack {
                Spacer()
                Button("Cancel") {
                    store.presentNewSession = false
                }
                Button("Create") {
                    store.createSession(prompt: prompt)
                    store.presentNewSession = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
    }
}
