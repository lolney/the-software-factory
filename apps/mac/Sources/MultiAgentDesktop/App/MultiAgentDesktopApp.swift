import SwiftUI
import AppKit

@main
struct TheSoftwareFactoryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = SessionStore.bootstrap()

    var body: some Scene {
        WindowGroup("The Software Factory", id: "main") {
            ContentView(store: store)
                .frame(minWidth: 1100, minHeight: 720)
                .task {
                    appDelegate.onWillTerminate = { [store] in
                        store.shutdownLocalDaemon()
                    }
                    store.connectAndRefresh()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        store.refreshForAppActivation()
                    }
                }
        }
        .defaultSize(width: 1586, height: 992)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Session…") {
                    store.beginNewSession()
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
            SoftwareFactoryViewMenuCommands(store: store)
        }

        Settings {
            SettingsView(store: store)
        }
    }
}

private struct SoftwareFactoryViewMenuCommands: Commands {
    let store: SessionStore
    @FocusedValue(\.softwareFactoryViewCommands) private var viewCommands

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Show Dashboard") {
                store.viewAllSessions()
            }
            .keyboardShortcut("0", modifiers: [.command])

            Divider()

            Button("Focus Transcript Search") {
                viewCommands?.focusTranscriptSearch()
            }
            .keyboardShortcut("f", modifiers: [.command])
            .disabled(viewCommands == nil)

            Button("Toggle Details") {
                viewCommands?.toggleDetails()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(viewCommands?.canShowDetails != true)

            Divider()

            ForEach(InspectorPanel.allCases) { panel in
                Button(showPanelTitle(panel)) {
                    viewCommands?.showPanel(panel)
                }
                .keyboardShortcut(panelShortcut(panel), modifiers: [.command, .option])
                .disabled(viewCommands?.canShowDetails != true)
            }

            Divider()

            Button("Zoom Graph In") {
                viewCommands?.applyGraphCommand(.zoomIn)
            }
            .keyboardShortcut("+", modifiers: [.command])
            .disabled(viewCommands?.canShowDetails != true)

            Button("Zoom Graph Out") {
                viewCommands?.applyGraphCommand(.zoomOut)
            }
            .keyboardShortcut("-", modifiers: [.command])
            .disabled(viewCommands?.canShowDetails != true)

            Button("Reset Graph View") {
                viewCommands?.applyGraphCommand(.reset)
            }
            .keyboardShortcut("0", modifiers: [.command, .option])
            .disabled(viewCommands?.canShowDetails != true)
        }
    }

    private func showPanelTitle(_ panel: InspectorPanel) -> String {
        "Show \(panel.rawValue) Panel"
    }

    private func panelShortcut(_ panel: InspectorPanel) -> KeyEquivalent {
        switch panel {
        case .graph: return "1"
        case .plan: return "2"
        case .workspace: return "3"
        case .debug: return "4"
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var onWillTerminate: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationWillTerminate(_ notification: Notification) {
        onWillTerminate?()
    }
}
