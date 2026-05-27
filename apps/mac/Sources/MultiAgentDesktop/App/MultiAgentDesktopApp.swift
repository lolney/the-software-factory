import SwiftUI
import AppKit

@main
struct TheSoftwareFactoryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = SessionStore()

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
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Session…") {
                    store.beginNewSession()
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
        }

        Settings {
            SettingsView(store: store)
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
