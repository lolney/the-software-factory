import SwiftUI

struct InspectorPanelView: View {
    @Bindable var store: SessionStore

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $store.inspectorPanel) {
                ForEach(InspectorPanel.allCases) { panel in
                    Text(panel.rawValue).tag(panel)
                }
            }
            .pickerStyle(.segmented)
            .padding([.top, .horizontal])

            Divider()

            switch store.inspectorPanel {
            case .graph:
                GraphPanelView(store: store)
            case .debug:
                DebugLogPanelView(store: store)
            }
        }
    }
}

struct DebugLogPanelView: View {
    @Bindable var store: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Session Debug")
                    .font(.headline)
                Spacer()
                Text("\(store.debugLogs.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding()

            if store.debugLogs.isEmpty {
                ContentUnavailableView("No Debug Logs", systemImage: "text.badge.magnifyingglass", description: Text("Logs stream here after the session emits events or errors."))
            } else {
                List(store.debugLogs) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(entry.level.rawValue.uppercased())
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(color(for: entry.level))
                                .frame(width: 42, alignment: .leading)
                            Text(entry.source)
                                .font(.caption.weight(.semibold))
                            if let agentId = entry.agentId {
                                Text(agentId)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(format(timestamp: entry.timestamp))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Text(entry.message)
                            .font(.callout)
                            .textSelection(.enabled)
                        if let eventType = entry.payload["eventType"]?.stringValue {
                            Text(eventType)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }
        }
    }

    private func color(for level: DebugLogLevel) -> Color {
        switch level {
        case .debug: .secondary
        case .info: .blue
        case .warn: .orange
        case .error: .red
        }
    }

    private func format(timestamp: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: timestamp) else { return timestamp }
        return date.formatted(date: .omitted, time: .shortened)
    }
}
