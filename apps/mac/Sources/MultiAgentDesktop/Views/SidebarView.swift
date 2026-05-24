import SwiftUI

struct SidebarView: View {
    @Bindable var store: SessionStore

    var body: some View {
        List(selection: $store.selectedSessionId) {
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
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button {
                store.presentNewSession = true
            } label: {
                Label("New Session", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding()
        }
    }
}
