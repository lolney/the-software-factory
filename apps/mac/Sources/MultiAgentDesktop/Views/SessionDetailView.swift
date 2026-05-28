import SwiftUI

struct SessionDetailView: View {
    @Bindable var store: SessionStore
    @State private var confirmCancel = false
    @State private var inspectorVisible = true

    var body: some View {
        GeometryReader { proxy in
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    OrchestratorChatView(store: store) {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            inspectorVisible = true
                        }
                    }
                        .frame(minWidth: 480, maxHeight: .infinity, alignment: .top)
                    ComposerView(store: store)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                if inspectorVisible && !store.isComposingNewSession {
                    Divider()
                    InspectorPanelView(store: store)
                        .frame(width: detailDrawerWidth(for: proxy.size.width))
                        .frame(maxHeight: .infinity)
                        .background(.regularMaterial)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
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
                        .disabled(store.currentWorkspaceRoot == nil)
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
                        .disabled(!store.hasTranscriptExport)
                        ShareLink(item: store.eventLogExportText) {
                            Label("Event Log", systemImage: "square.and.arrow.up")
                        }
                        .disabled(!store.hasEventLogExport)
                        ShareLink(item: store.debugLogExportText) {
                            Label("Debug Log", systemImage: "square.and.arrow.up")
                        }
                        .disabled(!store.hasDebugLogExport)
                    }
                } label: {
                    Label("Session Artifacts", systemImage: "tray.full")
                }
                .accessibilityLabel("Session Artifacts")
                .disabled(store.selectedSessionId == nil || store.isLoadingSelection)
                .help("Copy, export, or share session artifacts")

                Menu {
                    Button {
                        store.pauseOrchestrator()
                    } label: {
                        Label("Pause Scheduling", systemImage: "pause.circle")
                    }
                    .disabled(!store.canPauseOrchestrator)

                    Button {
                        store.resumeOrchestrator()
                    } label: {
                        Label("Resume Orchestrator", systemImage: "play.circle")
                    }
                    .disabled(!store.canResumeOrchestrator)
                } label: {
                    Label(store.orchestratorStatus == .paused ? "Resume Orchestrator" : "Run Controls", systemImage: store.orchestratorStatus == .paused ? "play.circle" : "play.circle")
                }
                .disabled(!store.canPauseOrchestrator && !store.canResumeOrchestrator)
                .help("Pause or resume orchestrator scheduling")

                Button {
                    store.pauseOrchestrator()
                } label: {
                    Label("Pause Scheduling", systemImage: "pause")
                }
                .disabled(!store.canPauseOrchestrator)
                .help("Pause orchestrator scheduling")

                Menu {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            inspectorVisible.toggle()
                        }
                    } label: {
                        Label(effectiveInspectorVisible ? "Hide Details" : "Show Details", systemImage: "sidebar.right")
                    }
                    .disabled(store.isComposingNewSession)
                    .help(store.isComposingNewSession ? "Details are hidden while composing a new session" : "Show or hide session details")

                    Button {
                        store.connectAndRefresh()
                    } label: {
                        Label("Connect", systemImage: "bolt.horizontal.circle")
                    }
                    .disabled(store.daemon.isConnecting)

                    Button(role: .destructive) {
                        confirmCancel = true
                    } label: {
                        Label("Stop Orchestrator", systemImage: "xmark.octagon")
                    }
                    .disabled(!store.canCancelOrchestrator)
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                .help("More session actions")
            }

            ToolbarItem(placement: .principal) {
                ToolbarSessionPill(
                    title: selectedSessionTitle,
                    isConnected: store.isConnectionHealthy
                )
            }
        }
        .confirmationDialog("Stop orchestrator?", isPresented: $confirmCancel) {
            Button("Stop Orchestrator", role: .destructive) {
                store.cancelOrchestrator()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var selectedSessionTitle: String {
        if store.isComposingNewSession {
            return "New session"
        }
        if store.currentSessionDebugMode == true,
           let artifactTitle = debugArtifactTitle {
            return "Debug workflow: \(artifactTitle)"
        }
        guard let selectedSessionId = store.selectedSessionId else {
            return "No session selected"
        }
        return (store.sessions + store.archivedSessions)
            .first { $0.id == selectedSessionId }?
            .title ?? selectedSessionId
    }

    private var debugArtifactTitle: String? {
        store.touchedWorkspaceFiles
            .map(\.path)
            .compactMap(sourceArtifactStem)
            .first
    }

    private func detailDrawerWidth(for totalWidth: CGFloat) -> CGFloat {
        min(430, max(340, totalWidth * 0.34))
    }

    private var effectiveInspectorVisible: Bool {
        inspectorVisible && !store.isComposingNewSession
    }
}

func sourceArtifactStem(from path: String) -> String? {
    let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    let stripped = name
        .replacingOccurrences(of: #"^test[_-]"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"[_-]test$"#, with: "", options: .regularExpression)
    let words = stripped
        .split { $0 == "_" || $0 == "-" }
        .map(String.init)
        .filter { !$0.isEmpty }
    guard !words.isEmpty else { return nil }
    return words.joined(separator: " ")
}

private struct ToolbarSessionPill: View {
    let title: String
    let isConnected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.callout)
                .lineLimit(1)
            Spacer(minLength: 12)
            Circle()
                .fill(isConnected ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .frame(minWidth: 354, idealWidth: 354, maxWidth: 354, minHeight: 34, idealHeight: 34, maxHeight: 34)
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(10)
        .background(.background.opacity(0.76), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator.opacity(0.5))
        }
        .help(title)
    }
}
