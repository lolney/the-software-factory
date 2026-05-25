import SwiftUI

struct ArchivedSessionsView: View {
    @Bindable var store: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Archived Sessions")
                    .font(.title2.weight(.semibold))
                Spacer()
                Text("\(store.archivedSessions.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding()

            if store.archivedSessions.isEmpty {
                ContentUnavailableView(
                    "No Archived Sessions",
                    systemImage: "archivebox",
                    description: Text("Archived sessions remain durable and viewable here after you move them out of the main session list.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.archivedSessions) { session in
                    HStack(spacing: 12) {
                        SessionSidebarRow(session: session)
                        Spacer()
                        Button {
                            store.selectSession(session.id)
                        } label: {
                            Label("View", systemImage: "eye")
                        }
                        Button {
                            store.restoreSessions([session.id])
                        } label: {
                            Label("Restore", systemImage: "arrow.uturn.backward")
                        }
                    }
                    .padding(.vertical, 4)
                    .contextMenu {
                        Button {
                            store.selectSession(session.id)
                        } label: {
                            Label("View Session", systemImage: "eye")
                        }
                        Button {
                            store.restoreSessions([session.id])
                        } label: {
                            Label("Restore Session", systemImage: "arrow.uturn.backward")
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
