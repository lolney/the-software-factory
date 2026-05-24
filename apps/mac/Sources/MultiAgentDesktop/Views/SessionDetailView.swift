import SwiftUI

struct SessionDetailView: View {
    @Bindable var store: SessionStore
    @State private var confirmCancel = false

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
                .disabled(store.daemon.isConnecting)

                Button {
                    store.pauseOrchestrator()
                } label: {
                    Label("Pause Orchestrator", systemImage: "pause.circle")
                }
                .disabled(!store.hasActiveSession || !store.daemon.isConnected)

                Button {
                    store.resumeOrchestrator()
                } label: {
                    Label("Resume Orchestrator", systemImage: "play.circle")
                }
                .disabled(!store.hasActiveSession || !store.daemon.isConnected)

                Button(role: .destructive) {
                    confirmCancel = true
                } label: {
                    Label("Cancel Orchestrator", systemImage: "xmark.circle")
                }
                .disabled(!store.hasActiveSession || !store.daemon.isConnected)
            }
        }
        .confirmationDialog("Cancel the orchestrator for this session?", isPresented: $confirmCancel) {
            Button("Cancel Orchestrator", role: .destructive) {
                store.cancelOrchestrator()
            }
        }
    }
}
