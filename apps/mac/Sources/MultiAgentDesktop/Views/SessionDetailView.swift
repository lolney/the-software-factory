import SwiftUI

struct SessionDetailView: View {
    @Bindable var store: SessionStore
    @State private var confirmCancel = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                OrchestratorChatView(store: store)
                    .frame(minWidth: 480, maxHeight: .infinity)
                ComposerView(store: store)
            }
            .frame(maxHeight: .infinity)

            InspectorPanelView(store: store)
                .frame(minWidth: 360, idealWidth: 440, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Button {
                        store.openWorkspace(tool: .vsCode)
                    } label: {
                        Label("VS Code", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    Button {
                        store.openWorkspace(tool: .finder)
                    } label: {
                        Label("Finder", systemImage: "folder")
                    }
                    Button {
                        store.openWorkspace(tool: .iTerm)
                    } label: {
                        Label("iTerm", systemImage: "terminal")
                    }
                } label: {
                    Label("Open", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .disabled(store.currentWorkspaceRoot == nil || store.isLoadingSelection)

                Button {
                    store.connectAndRefresh()
                } label: {
                    Label("Connect", systemImage: "bolt.horizontal.circle")
                }
                .disabled(store.daemon.isConnecting)

                Menu {
                    ForEach(store.graph.nodes) { node in
                        Button {
                            store.setControlAgent(node.id)
                        } label: {
                            Label(node.label, systemImage: node.id == store.selectedControlAgentId ? "checkmark.circle.fill" : "circle")
                        }
                    }
                } label: {
                    Label("Control: \(store.selectedControlAgentLabel)", systemImage: "scope")
                }
                .disabled(store.graph.nodes.isEmpty || store.isLoadingSelection)

                Button {
                    store.pauseOrchestrator()
                } label: {
                    Label("Pause Scheduling", systemImage: "pause.circle")
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

            ToolbarItem(placement: .status) {
                if let mode = store.currentSessionDebugMode {
                    Label(mode ? "Debug" : "Live", systemImage: mode ? "ladybug" : "bolt.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .confirmationDialog("Cancel \(store.selectedControlAgentLabel) for this session?", isPresented: $confirmCancel) {
            Button("Cancel \(store.selectedControlAgentLabel)", role: .destructive) {
                store.cancelOrchestrator()
            }
        }
    }
}
