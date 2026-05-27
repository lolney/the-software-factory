import SwiftUI

struct SidebarView: View {
    @Bindable var store: SessionStore
    @State private var pendingArchiveIds: [String] = []
    @State private var showingArchiveConfirmation = false
    @State private var pendingRenameId: String?
    @State private var renameTitle = ""
    @State private var showingRenameDialog = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("SESSIONS")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    store.beginNewSession()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .background(.background.opacity(0.62), in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(.separator.opacity(0.4))
                }
                .help("Create a session from an initial prompt")
            }
            .padding(.top, 36)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 6) {
                SidebarNavRow(
                    title: "Session Dashboard",
                    systemImage: "square.grid.2x2",
                    isSelected: store.selectedSidebarItem == SessionStore.sessionDashboardId
                ) {
                    store.selectSidebarItem(SessionStore.sessionDashboardId)
                }
                SidebarNavRow(
                    title: "All Sessions",
                    systemImage: "tray.full",
                    isSelected: false
                ) {
                    if let sessionId = store.selectedSessionId ?? store.sessions.first?.id {
                        store.selectSession(sessionId)
                    }
                }
                SidebarNavRow(
                    title: "Workflows",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    isSelected: store.selectedSidebarItem == "workflows"
                ) {
                    store.selectSidebarItem("workflows")
                }
                SidebarNavRow(
                    title: "Archived",
                    systemImage: "archivebox",
                    isSelected: store.selectedSidebarItem == "archived"
                ) {
                    store.selectSidebarItem("archived")
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 18)

            Divider()
                .opacity(0.55)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("RECENT SESSIONS")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 18)
                        .padding(.horizontal, 20)

                    if store.isComposingNewSession {
                        SidebarSessionButton(
                            isSelected: store.selectedSidebarItem == SessionStore.newSessionDraftId,
                            action: { store.selectSidebarItem(SessionStore.newSessionDraftId) }
                        ) {
                            HStack(spacing: 10) {
                                Image(systemName: "plus.message")
                                    .frame(width: 16)
                                Text("New Session...")
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                        }
                        .padding(.horizontal, 10)
                    }

                    ForEach(store.visibleSessions.prefix(8)) { session in
                        SidebarSessionButton(
                            isSelected: store.selectedSidebarItems.contains(session.id),
                            action: { store.selectSession(session.id) }
                        ) {
                            SessionSidebarRow(session: session)
                        }
                        .contextMenu {
                            Button {
                                store.selectSession(session.id)
                            } label: {
                                Label("View Session", systemImage: "rectangle.3.group.bubble")
                            }
                            Button {
                                pendingRenameId = session.id
                                renameTitle = session.title
                                showingRenameDialog = true
                            } label: {
                                Label("Rename Session", systemImage: "pencil")
                            }
                            Button {
                                pendingArchiveIds = [session.id]
                                showingArchiveConfirmation = true
                            } label: {
                                Label("Archive Session", systemImage: "archivebox")
                            }
                        }
                        .padding(.horizontal, 10)
                    }

                    if let archived = store.selectedArchivedSession {
                        Text("ARCHIVED")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 14)
                            .padding(.horizontal, 20)
                        SidebarSessionButton(
                            isSelected: store.selectedSidebarItems.contains(archived.id),
                            action: { store.selectSession(archived.id) }
                        ) {
                            SessionSidebarRow(session: archived)
                        }
                        .contextMenu {
                            Button {
                                store.selectSession(archived.id)
                            } label: {
                                Label("View Session", systemImage: "eye")
                            }
                            Button {
                                store.restoreSessions([archived.id])
                            } label: {
                                Label("Restore Session", systemImage: "arrow.uturn.backward")
                            }
                            Button {
                                pendingRenameId = archived.id
                                renameTitle = archived.title
                                showingRenameDialog = true
                            } label: {
                                Label("Rename Session", systemImage: "pencil")
                            }
                        }
                        .padding(.horizontal, 10)
                    }
                }
                .padding(.bottom, 20)
            }

            VStack(spacing: 8) {
                if store.selectedSessionIdsForActions.count > 1 {
                    Button {
                        store.viewSelectedSessions()
                    } label: {
                        Label("View \(store.selectedSessionIdsForActions.count) Sessions", systemImage: "tablecells")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .help("Open a dashboard filtered to the selected sessions")

                    Button {
                        pendingArchiveIds = store.selectedSessionIdsForActions
                        showingArchiveConfirmation = true
                    } label: {
                        Label("Archive \(store.selectedSessionIdsForActions.count) Sessions", systemImage: "archivebox")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .help("Archive the selected sessions")
                }

                Button {
                    store.beginNewSession()
                } label: {
                    Label("New Session...", systemImage: "plus")
                        .font(.callout)
                        .padding(.horizontal, 12)
                        .frame(height: 38)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .help("Create a session from an initial prompt")
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .background(.bar)
        .confirmationDialog("Archive selected sessions?", isPresented: $showingArchiveConfirmation) {
            Button("Archive \(pendingArchiveIds.count) Sessions", role: .destructive) {
                store.archiveSessions(pendingArchiveIds)
                pendingArchiveIds = []
            }
            Button("Cancel", role: .cancel) {
                pendingArchiveIds = []
            }
        } message: {
            Text("Archived sessions are removed from the main session list but remain viewable and restorable.")
        }
        .alert("Rename Session", isPresented: $showingRenameDialog) {
            TextField("Session title", text: $renameTitle)
            Button("Rename") {
                if let pendingRenameId {
                    store.renameSession(pendingRenameId, title: renameTitle)
                }
                pendingRenameId = nil
                renameTitle = ""
            }
            Button("Cancel", role: .cancel) {
                pendingRenameId = nil
                renameTitle = ""
            }
        } message: {
            Text("Use a short title that distinguishes this session in the sidebar.")
        }
        .task {
            store.connectAndRefresh()
        }
    }

}

struct SessionSidebarRow: View {
    let session: SessionSummary

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: rowIcon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 5) {
                Text(session.title)
                    .lineLimit(1)
                    .font(.callout)
                Text(activityLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                if showsStatusDot {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                }
                if (session.failureCount ?? 0) > 0 {
                    Text("\(session.failureCount ?? 0)")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .background(.red, in: Capsule())
                }
            }
        }
    }

    private var rowIcon: String {
        session.debugMode == true ? "figure.mind.and.body" : "rectangle.3.group.bubble"
    }

    private var showsStatusDot: Bool {
        session.archived == true || ["active", "failed", "cancelled", "paused"].contains(session.status ?? "")
    }

    private var secondaryLine: String {
        let status = statusLabel == "Idle" ? "" : "\(statusLabel) · "
        return "\(status)\(activityLabel)"
    }

    private var statusColor: Color {
        if session.archived == true { return .secondary }
        switch session.status {
        case "completed": return .green
        case "failed": return .red
        case "cancelled", "paused": return .orange
        case "active": return .blue
        default: return .secondary
        }
    }

    private var statusLabel: String {
        if session.archived == true { return "Archived" }
        switch session.status {
        case "completed": return "Completed"
        case "failed": return "Failed"
        case "cancelled": return "Cancelled"
        case "paused": return "Paused"
        case "active":
            if let activeAgents = session.activeAgents, activeAgents > 0 {
                return "Active \(activeAgents)"
            }
            return "Active"
        default:
            return "Idle"
        }
    }

    private var activityLabel: String {
        guard let date = parseISO8601(session.updatedAt ?? session.createdAt) else {
            return "No activity"
        }
        return date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }

    private func parseISO8601(_ timestamp: String?) -> Date? {
        guard let timestamp else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: timestamp) {
            return date
        }
        return ISO8601DateFormatter().date(from: timestamp)
    }
}

private struct SidebarNavRow: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .regular))
                    .frame(width: 18)
                Text(title)
                    .font(.callout)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(.quaternary.opacity(0.5))
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct SidebarSessionButton<Content: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        Button(action: action) {
            content
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .frame(minHeight: 56)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(.quaternary.opacity(0.65))
                    }
                }
        }
        .buttonStyle(.plain)
    }
}
