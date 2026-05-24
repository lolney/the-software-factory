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

            HStack {
                Spacer()
                Button("Cancel") {
                    store.presentNewSession = false
                }
                Button("Create") {
                    let title = prompt.split(separator: "\n").first.map(String.init) ?? "Untitled Session"
                    let id = "sess-\(UUID().uuidString.prefix(8))"
                    store.sessions.insert(SessionSummary(id: id, title: title, detail: "Local session"), at: 0)
                    store.selectedSessionId = id
                    store.presentNewSession = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
    }
}
