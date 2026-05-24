import SwiftUI

struct OrchestratorChatView: View {
    @Bindable var store: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Orchestrator")
                    .font(.headline)
                Spacer()
                Text(store.connectionStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(store.transcript) { item in
                        TranscriptRow(item: item)
                    }
                }
                .padding()
            }
        }
    }
}

struct TranscriptRow: View {
    let item: TranscriptItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.agentId ?? "system")
                    .font(.caption.weight(.semibold))
                Text(item.type)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(item.text)
                .textSelection(.enabled)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
