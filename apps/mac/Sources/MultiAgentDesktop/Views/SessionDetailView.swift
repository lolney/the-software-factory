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

            GraphPanelView(store: store)
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
                    Label("Pause Agent", systemImage: "pause.circle")
                }
                .disabled(!store.canPauseOrchestrator)

                Button {
                    store.resumeOrchestrator()
                } label: {
                    Label("Resume Agent", systemImage: "play.circle")
                }
                .disabled(!store.canResumeOrchestrator)

                Button(role: .destructive) {
                    confirmCancel = true
                } label: {
                    Label("Cancel Agent", systemImage: "xmark.circle")
                }
                .disabled(!store.canCancelOrchestrator)
            }
        }
        .confirmationDialog("Cancel the selected agent for this session?", isPresented: $confirmCancel) {
            Button("Cancel Agent", role: .destructive) {
                store.cancelOrchestrator()
            }
        }
    }
}
