import SwiftUI

struct SidebarView: View {
    @Bindable var store: SessionStore
    @State private var pendingArchiveIds: [String] = []
    @State private var showingArchiveConfirmation = false

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
        .task {
            store.connectAndRefresh()
        }
    }
}

struct SessionSidebarRow: View {
    let session: SessionSummary

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: session.archived == true ? "archivebox" : "rectangle.3.group.bubble")
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .lineLimit(1)
                Text(session.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
