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

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Show Dashboard") {
                store.viewAllSessions()
            }
            .keyboardShortcut("0", modifiers: [.command])

            Divider()

            Button("Focus Transcript Search") {
                store.focusTranscriptSearch()
            }
            .keyboardShortcut("f", modifiers: [.command])
            .disabled(!store.canUseSessionViewCommands)

            Button("Toggle Details") {
                store.toggleInspectorVisibility()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(!store.canUseSessionViewCommands)

            Divider()

            ForEach(InspectorPanel.allCases) { panel in
                Button(showPanelTitle(panel)) {
                    store.showInspectorPanel(panel)
                }
                .keyboardShortcut(panelShortcut(panel), modifiers: [.command, .option])
                .disabled(!store.canUseSessionViewCommands)
            }

            Divider()

            Button("Zoom Graph In") {
                store.applyGraphCommand(.zoomIn)
            }
            .keyboardShortcut("+", modifiers: [.command])
            .disabled(!store.canUseSessionViewCommands)

            Button("Zoom Graph Out") {
                store.applyGraphCommand(.zoomOut)
            }
            .keyboardShortcut("-", modifiers: [.command])
            .disabled(!store.canUseSessionViewCommands)

            Button("Reset Graph View") {
                store.applyGraphCommand(.reset)
            }
            .keyboardShortcut("0", modifiers: [.command, .option])
            .disabled(!store.canUseSessionViewCommands)
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
