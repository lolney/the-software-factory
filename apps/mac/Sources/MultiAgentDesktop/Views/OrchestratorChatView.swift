import SwiftUI

struct OrchestratorChatView: View {
    @Bindable var store: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Orchestrator")
                    .font(.headline)
                if let selectedAgentId = store.selectedAgentId {
                    Text("filtered: \(selectedAgentId)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(store.connectionStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            if store.isLoadingSelection {
                ProgressView("Loading session...")
                    .controlSize(.small)
                    .padding()
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(store.filteredTranscript) { item in
                            TranscriptRow(item: item)
                                .id(item.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: store.filteredTranscript.count) { _, _ in
                    if let last = store.filteredTranscript.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

struct TranscriptRow: View {
    let item: TranscriptItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.sender)
                    .font(.caption.weight(.semibold))
                if let recipient = item.recipient {
                    Text("-> \(recipient)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(item.type)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(item.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(item.text)
                .textSelection(.enabled)
        }
        .padding(10)
        .background(item.sender == "user" ? .thickMaterial : .regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
