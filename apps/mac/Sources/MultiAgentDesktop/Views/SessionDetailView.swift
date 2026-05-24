import SwiftUI

struct SessionDetailView: View {
    @Bindable var store: SessionStore

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                OrchestratorChatView(store: store)
                    .frame(minWidth: 480)
                ComposerView(store: store)
            }

            GraphPanelView(graph: store.graph)
                .frame(minWidth: 360, idealWidth: 440)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    store.connectAndRefresh()
                } label: {
                    Label("Connect", systemImage: "bolt.horizontal.circle")
                }

                Button {
                    store.pauseOrchestrator()
                } label: {
                    Label("Pause", systemImage: "pause.circle")
                }

                Button {
                    store.resumeOrchestrator()
                } label: {
                    Label("Resume", systemImage: "play.circle")
                }

                Button(role: .destructive) {
                    store.cancelOrchestrator()
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                }
            }
        }
    }
}
