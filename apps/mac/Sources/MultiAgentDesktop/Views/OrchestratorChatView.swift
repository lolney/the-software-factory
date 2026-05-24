import SwiftUI

struct OrchestratorChatView: View {
    @Bindable var store: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(store.transcriptFilterLabel)
                    .font(.headline)
                if store.isTranscriptFiltered {
                    Text("filtered transcript")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        store.selectAgent(nil)
                    } label: {
                        Label("All Agents", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
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
                        if store.filteredTranscript.isEmpty {
                            Text(store.isTranscriptFiltered ? "No transcript events for this agent yet." : "No transcript events yet.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 24)
                        } else {
                            ForEach(store.filteredTranscript) { item in
                                TranscriptRow(item: item)
                                    .id(item.id)
                            }
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
