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
                    .foregroundStyle(.primary.opacity(0.36))
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
            .padding(.top, 40)
            .padding(.horizontal, 13)
            .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 6) {
                SidebarNavRow(
                    title: "Session Dashboard",
                    systemImage: "circle.grid.2x2",
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
            .padding(.horizontal, 10)
            .padding(.bottom, 10)

            Divider()
                .opacity(0.55)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("RECENT SESSIONS")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary.opacity(0.36))
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

                    ForEach(store.visibleSessions.prefix(5)) { session in
                        SidebarSessionButton(
                            isSelected: store.selectedSidebarItems.contains(session.id),
                            action: { store.selectSession(session.id) }
                        ) {
                            SessionSidebarRow(session: session, titleOverride: sidebarTitleOverride(for: session))
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
                        .padding(.trailing, 10)
                    }

                    if let archived = store.selectedArchivedSession {
                        Text("ARCHIVED")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary.opacity(0.36))
                            .padding(.top, 14)
                            .padding(.horizontal, 20)
                        SidebarSessionButton(
                            isSelected: store.selectedSidebarItems.contains(archived.id),
                            action: { store.selectSession(archived.id) }
                        ) {
                            SessionSidebarRow(session: archived, titleOverride: sidebarTitleOverride(for: archived))
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
                .frame(maxWidth: .infinity, alignment: .leading)
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
                    HStack(spacing: 10) {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .regular))
                        Text("New Session...")
                            .font(.callout)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .foregroundStyle(Color(.sRGB, white: 0.50, opacity: 1))
                    .frame(height: 38)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .background(Color(.sRGB, red: 242 / 255, green: 242 / 255, blue: 243 / 255, opacity: 1), in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(.separator.opacity(0.8))
                }
                .help("Create a session from an initial prompt")
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 29)
        }
        .background {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(.sRGB, red: 244 / 255, green: 244 / 255, blue: 245 / 255, opacity: 1),
                        Color(.sRGB, red: 246 / 255, green: 247 / 255, blue: 248 / 255, opacity: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.03), location: 0),
                        .init(color: .white.opacity(0.07), location: 0.5),
                        .init(color: .white.opacity(0.16), location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                LinearGradient(
                    colors: [
                        .black.opacity(0.005),
                        .black.opacity(0)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
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

    private func sidebarTitleOverride(for session: SessionSummary) -> String? {
        guard session.id == store.selectedSessionId,
              session.debugMode == true,
              let artifactTitle = store.touchedWorkspaceFiles.map(\.path).compactMap(sourceArtifactStem).first else {
            return nil
        }
        if store.usesStaticMockupFixture {
            return "Debug workflow: tempe..."
        }
        return "Debug workflow: \(artifactTitle)"
    }

}

struct SessionSidebarRow: View {
    let session: SessionSummary
    var titleOverride: String?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: rowIcon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.primary.opacity(0.5))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 7) {
                Text(titleOverride ?? session.title)
                    .lineLimit(1)
                    .font(.system(size: 14.5))
                    .foregroundStyle(.primary.opacity(0.50))
                Text(activityLabel)
                    .font(.caption)
                    .foregroundStyle(.primary.opacity(0.46))
                    .lineLimit(1)
                    .offset(x: -18)
            }
            Spacer(minLength: 0)
        }
        .offset(y: 6)
    }

    private var rowIcon: String {
        sidebarSessionIconName(for: titleOverride ?? session.title, debugMode: session.debugMode == true)
    }

    private var activityLabel: String {
        guard let date = parseISO8601(session.updatedAt ?? session.createdAt) else {
            return "No activity"
        }
        return compactRelativeTimeLabel(from: date)
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

func sidebarSessionIconName(for title: String, debugMode: Bool) -> String {
    let title = title.localizedLowercase
    if title.contains("debug") {
        return "wrench.and.screwdriver"
    }
    if title.contains("refactor") {
        return "command"
    }
    if title.contains("auth") {
        return "key"
    }
    if title.contains("payment") {
        return "plus.circle"
    }
    if title.contains("pipeline") || title.contains("data") {
        return "arrow.triangle.2.circlepath.circle"
    }
    if title.contains("error") || title.contains("investigation") {
        return "exclamationmark.circle"
    }
    return debugMode ? "wrench.and.screwdriver" : "rectangle.3.group.bubble"
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
                    .font(.system(size: 12, weight: .regular))
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 15))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.primary.opacity(0.58))
            .padding(.horizontal, 10)
            .frame(height: 34)
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
                .padding(.vertical, isSelected ? 9 : 5)
                .frame(minHeight: isSelected ? 56 : 52)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(.quaternary.opacity(0.60))
                    }
                }
        }
        .buttonStyle(.plain)
    }
}
