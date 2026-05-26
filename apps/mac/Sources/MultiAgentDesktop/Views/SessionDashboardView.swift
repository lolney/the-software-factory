import SwiftUI

struct SessionDashboardView: View {
    @Bindable var store: SessionStore
    @State private var tableSelection = Set<String>()

    private var rows: [SessionSummary] {
        let all = store.sessions + store.archivedSessions
        guard !store.dashboardSessionFilterIds.isEmpty else { return all }
        return all.filter { store.dashboardSessionFilterIds.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Session Dashboard")
                        .font(.title2.weight(.semibold))
                    Text(store.dashboardSessionFilterIds.isEmpty ? "All sessions" : "\(rows.count) selected sessions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !store.dashboardSessionFilterIds.isEmpty {
                    Button {
                        store.viewAllSessions()
                    } label: {
                        Label("Show All", systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
                if !tableSelection.isEmpty {
                    Button {
                        store.archiveSessions(Array(tableSelection))
                    } label: {
                        Label("Archive Selected", systemImage: "archivebox")
                    }
                    Button {
                        store.restoreSessions(Array(tableSelection))
                    } label: {
                        Label("Restore Selected", systemImage: "arrow.uturn.backward")
                    }
                }
            }
            .padding()

            if rows.isEmpty {
                ContentUnavailableView("No Sessions", systemImage: "tablecells", description: Text("Create a session or choose a different dashboard filter."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(rows, selection: $tableSelection) {
                    TableColumn("Session") { session in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.title)
                                .lineLimit(1)
                            Text(session.id)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    TableColumn("Status") { session in
                        HStack(spacing: 6) {
                            Image(systemName: statusIcon(for: session))
                                .foregroundStyle(statusColor(for: session))
                                .font(.caption2)
                            Text(statusLabel(for: session))
                        }
                    }
                    TableColumn("Mode") { session in
                        Text(session.debugMode == true ? "Debug" : "Live")
                            .foregroundStyle(.secondary)
                    }
                    TableColumn("Active/Paused") { session in
                        Text("\(session.activeAgents ?? 0)")
                            .monospacedDigit()
                    }
                    TableColumn("Failures") { session in
                        Text("\(session.failureCount ?? 0)")
                            .foregroundStyle((session.failureCount ?? 0) > 0 ? .red : .secondary)
                            .monospacedDigit()
                    }
                    TableColumn("Workflow") { session in
                        Text(session.detail)
                            .lineLimit(1)
                    }
                    TableColumn("Last Activity") { session in
                        Text(dateLabel(session.updatedAt ?? session.createdAt))
                            .foregroundStyle(.secondary)
                    }
                    TableColumn("Workspace") { session in
                        Text(session.workspaceRoot ?? "None")
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    TableColumn("Actions") { session in
                        HStack(spacing: 8) {
                            Button {
                                store.selectSession(session.id)
                            } label: {
                                Label("View", systemImage: "eye")
                            }
                            if session.archived == true {
                                Button {
                                    store.restoreSessions([session.id])
                                } label: {
                                    Label("Restore", systemImage: "arrow.uturn.backward")
                                }
                            } else {
                                Button {
                                    store.archiveSessions([session.id])
                                } label: {
                                    Label("Archive", systemImage: "archivebox")
                                }
                            }
                        }
                        .labelStyle(.iconOnly)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func dateLabel(_ timestamp: String?) -> String {
        guard let timestamp,
              let date = parseISO8601(timestamp) else {
            return "Unknown"
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func parseISO8601(_ timestamp: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: timestamp) {
            return date
        }
        return ISO8601DateFormatter().date(from: timestamp)
    }

    private func statusLabel(for session: SessionSummary) -> String {
        if session.archived == true { return "Archived" }
        switch session.status {
        case "completed": return "Completed"
        case "failed": return "Failed"
        case "cancelled": return "Cancelled"
        case "paused": return "Paused"
        case "active": return "Active"
        case "idle": return "Idle"
        default: return (session.activeAgents ?? 0) > 0 ? "Active" : "Idle"
        }
    }

    private func statusIcon(for session: SessionSummary) -> String {
        if session.archived == true { return "archivebox" }
        switch session.status {
        case "completed": return "checkmark.circle.fill"
        case "failed": return "xmark.octagon.fill"
        case "cancelled": return "stop.circle.fill"
        case "paused": return "pause.circle.fill"
        case "active": return "circle.fill"
        default: return "circle"
        }
    }

    private func statusColor(for session: SessionSummary) -> Color {
        if session.archived == true { return .secondary }
        switch session.status {
        case "completed": return .green
        case "failed": return .red
        case "cancelled": return .orange
        case "paused": return .orange
        case "active": return .blue
        default: return .secondary
        }
    }
}
