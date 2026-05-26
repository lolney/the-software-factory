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
                .help("Open the current session workspace")

                Menu {
                    Menu("Copy") {
                        Button {
                            store.copyTranscript()
                        } label: {
                            Label("Transcript", systemImage: "text.bubble")
                        }
                        Button {
                            store.copySessionEventLog()
                        } label: {
                            Label("Event Log", systemImage: "list.bullet.rectangle")
                        }
                        Button {
                            store.copyDebugLog()
                        } label: {
                            Label("Debug Log", systemImage: "ladybug")
                        }
                        Divider()
                        Button {
                            store.copyCurrentWorkspacePath()
                        } label: {
                            Label("Workspace Path", systemImage: "folder")
                        }
                    }
                    Menu("Export") {
                        Button {
                            store.exportTranscript()
                        } label: {
                            Label("Transcript...", systemImage: "square.and.arrow.down")
                        }
                        Button {
                            store.exportSessionEventLog()
                        } label: {
                            Label("Event Log...", systemImage: "square.and.arrow.down")
                        }
                        Button {
                            store.exportDebugLog()
                        } label: {
                            Label("Debug Log...", systemImage: "square.and.arrow.down")
                        }
                    }
                    Menu("Share") {
                        ShareLink(item: store.transcriptExportText) {
                            Label("Transcript", systemImage: "square.and.arrow.up")
                        }
                        .disabled(store.transcriptExportText.isEmpty)
                        ShareLink(item: store.eventLogExportText) {
                            Label("Event Log", systemImage: "square.and.arrow.up")
                        }
                        .disabled(store.eventLogExportText.isEmpty)
                        ShareLink(item: store.debugLogExportText) {
                            Label("Debug Log", systemImage: "square.and.arrow.up")
                        }
                        .disabled(store.debugLogExportText.isEmpty)
                    }
                } label: {
                    Label("Artifacts", systemImage: "doc.on.doc")
                }
                .disabled(store.selectedSessionId == nil || store.isLoadingSelection)
                .help("Copy, export, or share session artifacts")

                Button {
                    store.connectAndRefresh()
                } label: {
                    Label("Connect", systemImage: "bolt.horizontal.circle")
                }
                .disabled(store.daemon.isConnecting)
                .help("Connect or refresh the local daemon connection")

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
                .help("Choose which agent the toolbar controls target")

                Button {
                    store.pauseOrchestrator()
                } label: {
                    Label("Pause Scheduling", systemImage: "pause.circle")
                }
                .disabled(!store.canPauseOrchestrator)
                .help("Pause scheduling for the selected agent")

                Button {
                    store.resumeOrchestrator()
                } label: {
                    Label("Resume Agent", systemImage: "play.circle")
                }
                .disabled(!store.canResumeOrchestrator)
                .help("Resume the selected agent")

                Button(role: .destructive) {
                    confirmCancel = true
                } label: {
                    Label("Stop Agent", systemImage: "xmark.octagon")
                }
                .disabled(!store.canCancelOrchestrator)
                .help("Stop the selected agent")
            }

            ToolbarItem(placement: .status) {
                if let mode = store.currentSessionDebugMode {
                    Label(mode ? "Debug" : "Live", systemImage: mode ? "ladybug" : "bolt.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .confirmationDialog("Stop \(store.selectedControlAgentLabel)?", isPresented: $confirmCancel) {
            Button("Stop \(store.selectedControlAgentLabel)", role: .destructive) {
                store.cancelOrchestrator()
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
