import SwiftUI

struct SidebarView: View {
    @Bindable var store: SessionStore
    @State private var pendingArchiveIds: [String] = []
    @State private var showingArchiveConfirmation = false
    @State private var pendingRenameId: String?
    @State private var renameTitle = ""
    @State private var showingRenameDialog = false

    var body: some View {
        List(selection: $store.selectedSidebarItems) {
            Section("Menu") {
                Label("Roles", systemImage: "person.2")
                    .tag("roles")
                Label("Workflows", systemImage: "point.3.connected.trianglepath.dotted")
                    .tag("workflows")
                Label("Session Dashboard", systemImage: "tablecells")
                    .tag(SessionStore.sessionDashboardId)
                Label("Archived Sessions", systemImage: "archivebox")
                    .tag("archived")
            }

            Section("Sessions") {
                if store.isComposingNewSession {
                    Label("New Session…", systemImage: "plus.message")
                        .tag(SessionStore.newSessionDraftId)
                }
                ForEach(store.sessions) { session in
                    SessionSidebarRow(session: session)
                    .tag(session.id)
                    .contextMenu {
                        Button {
                            store.selectSession(session.id)
                        } label: {
                            Label("View Session", systemImage: "rectangle.3.group.bubble")
                        }
                        if store.selectedSessionIdsForActions.count > 1 {
                            Button {
                                store.viewSelectedSessions()
                            } label: {
                                Label("View Selected Sessions", systemImage: "tablecells")
                            }
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
                        if store.selectedSessionIdsForActions.count > 1 {
                            Button {
                                store.archiveSelectedSessions()
                            } label: {
                                Label("Archive Selected Sessions", systemImage: "archivebox.fill")
                            }
                        }
                    }
                }
            }

            if let archived = store.selectedArchivedSession {
                Section("Archived") {
                    SessionSidebarRow(session: archived)
                        .tag(archived.id)
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
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: store.selectedSidebarItems) { _, newValue in
            store.selectSidebarItems(newValue)
        }
        .safeAreaInset(edge: .bottom) {
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
                    Label("New Session…", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .help("Create a session from an initial prompt")
            }
            .padding()
        }
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
        HStack(spacing: 10) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.title)
                        .lineLimit(1)
                    if (session.failureCount ?? 0) > 0 {
                        Text("\(session.failureCount ?? 0)")
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .background(.red, in: Capsule())
                    }
                }
                HStack(spacing: 4) {
                    Text(statusLabel)
                    Text("•")
                    Text(activityLabel)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                Text(session.detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private var statusIcon: String {
        if session.archived == true { return "archivebox" }
        switch session.status {
        case "completed": return "checkmark.circle.fill"
        case "failed": return "xmark.octagon.fill"
        case "cancelled": return "stop.circle.fill"
        case "paused": return "pause.circle.fill"
        case "active": return "circle.fill"
        default: return "rectangle.3.group.bubble"
        }
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
