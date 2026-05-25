import SwiftUI

struct SidebarView: View {
    @Bindable var store: SessionStore

    var body: some View {
        List(selection: $store.selectedSidebarItem) {
            Section("Menu") {
                Label("Roles", systemImage: "person.2")
                    .tag("roles")
                Label("Workflows", systemImage: "point.3.connected.trianglepath.dotted")
                    .tag("workflows")
            }

            Section("Sessions") {
                if store.isComposingNewSession {
                    Label("New Session", systemImage: "plus.message")
                        .tag(SessionStore.newSessionDraftId)
                }
                ForEach(store.sessions) { session in
                    HStack(spacing: 10) {
                        Image(systemName: "rectangle.3.group.bubble")
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
                    .tag(session.id)
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: store.selectedSidebarItem) { _, newValue in
            store.selectSidebarItem(newValue)
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                store.beginNewSession()
            } label: {
                Label("New Session", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding()
        }
        .task {
            store.connectAndRefresh()
        }
    }
}
