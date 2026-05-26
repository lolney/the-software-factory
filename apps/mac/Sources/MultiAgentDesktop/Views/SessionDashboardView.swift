import SwiftUI

struct SessionDashboardView: View {
    @Bindable var store: SessionStore
    @State private var tableSelection = Set<String>()
    @State private var pendingArchiveSessionIds: [String] = []
    @State private var isConfirmingArchive = false
    @State private var selectedStatusFilter: String? = nil

    private let statusFilterOrder = ["active", "paused", "failed", "completed", "cancelled", "idle", "archived"]

    private var baseRows: [SessionSummary] {
        let all = store.sessions + store.archivedSessions
        guard !store.dashboardSessionFilterIds.isEmpty else { return all }
        return all.filter { store.dashboardSessionFilterIds.contains($0.id) }
    }

    private var rows: [SessionSummary] {
        guard let selectedStatusFilter else { return baseRows }
        return baseRows.filter { normalizedStatus(for: $0) == selectedStatusFilter }
    }

    private var visibleSelection: [String] {
        let visibleIds = Set(rows.map(\.id))
        return Array(tableSelection.intersection(visibleIds))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Session Dashboard")
                            .font(.title2.weight(.semibold))
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !store.dashboardSessionFilterIds.isEmpty {
                        Button {
                            selectedStatusFilter = nil
                            store.viewAllSessions()
                        } label: {
                            Label("Show All", systemImage: "line.3.horizontal.decrease.circle")
                        }
                    }
                    if !visibleSelection.isEmpty {
                        Button {
                            requestArchive(visibleSelection)
                        } label: {
                            Label("Archive Selected", systemImage: "archivebox")
                        }
                        Button {
                            store.restoreSessions(visibleSelection)
                        } label: {
                            Label("Restore Selected", systemImage: "arrow.uturn.backward")
                        }
                    }
                }
                statusFilters
            }
            .padding()

            if rows.isEmpty {
                ContentUnavailableView(emptyStateTitle, systemImage: "tablecells", description: Text(emptyStateDescription))
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
                                    requestArchive([session.id])
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
        .confirmationDialog("Archive sessions?", isPresented: $isConfirmingArchive) {
            Button(archiveButtonTitle, role: .destructive) {
                store.archiveSessions(pendingArchiveSessionIds)
                tableSelection.subtract(pendingArchiveSessionIds)
                pendingArchiveSessionIds = []
            }
            Button("Cancel", role: .cancel) {
                pendingArchiveSessionIds = []
            }
        } message: {
            Text("Archived sessions are hidden from the main list and can be restored from Archived Sessions.")
        }
    }

    private var subtitle: String {
        if store.dashboardSessionFilterIds.isEmpty {
            return selectedStatusFilter.map { "\(rows.count) \(statusFilterLabel($0).lowercased()) sessions" } ?? "All sessions"
        }
        let scoped = "\(baseRows.count) selected sessions"
        if let selectedStatusFilter {
            return "\(rows.count) \(statusFilterLabel(selectedStatusFilter).lowercased()) of \(scoped)"
        }
        return scoped
    }

    private var statusFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                statusFilterButton(label: "All", count: baseRows.count, status: nil)
                ForEach(statusFilterOrder, id: \.self) { status in
                    statusFilterButton(label: statusFilterLabel(status), count: count(for: status), status: status)
                }
            }
        }
    }

    private func statusFilterButton(label: String, count: Int, status: String?) -> some View {
        let isSelected = selectedStatusFilter == status
        return Button {
            selectedStatusFilter = status
            tableSelection.formIntersection(visibleIds(for: status))
        } label: {
            HStack(spacing: 5) {
                Text(label)
                Text("\(count)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(isSelected ? .white.opacity(0.85) : .secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.12), in: Capsule())
            .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
        .disabled(count == 0 && status != nil)
        .opacity(count == 0 && status != nil ? 0.45 : 1)
    }

    private var emptyStateTitle: String {
        selectedStatusFilter == nil ? "No Sessions" : "No \(statusFilterLabel(selectedStatusFilter ?? "").lowercased()) sessions"
    }

    private var emptyStateDescription: String {
        if selectedStatusFilter != nil {
            return "Choose another status filter or show all sessions."
        }
        return "Create a session or choose a different dashboard filter."
    }

    private func count(for status: String) -> Int {
        baseRows.filter { normalizedStatus(for: $0) == status }.count
    }

    private func visibleIds(for status: String?) -> Set<String> {
        guard let status else { return Set(baseRows.map(\.id)) }
        return Set(baseRows.filter { normalizedStatus(for: $0) == status }.map(\.id))
    }

    private func normalizedStatus(for session: SessionSummary) -> String {
        if session.archived == true { return "archived" }
        if let status = session.status, !status.isEmpty { return status }
        return (session.activeAgents ?? 0) > 0 ? "active" : "idle"
    }

    private func statusFilterLabel(_ status: String) -> String {
        switch status {
        case "active": return "Active"
        case "paused": return "Paused"
        case "failed": return "Failed"
        case "completed": return "Completed"
        case "cancelled": return "Cancelled"
        case "archived": return "Archived"
        default: return "Idle"
        }
    }

    private var archiveButtonTitle: String {
        pendingArchiveSessionIds.count == 1 ? "Archive Session" : "Archive \(pendingArchiveSessionIds.count) Sessions"
    }

    private func requestArchive(_ sessionIds: [String]) {
        pendingArchiveSessionIds = sessionIds
        isConfirmingArchive = true
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
