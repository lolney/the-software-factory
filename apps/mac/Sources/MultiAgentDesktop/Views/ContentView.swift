import SwiftUI
import AppKit

struct ContentView: View {
    @Bindable var store: SessionStore

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(282)
        } detail: {
            switch store.selectedSidebarItem {
            case "roles":
                RolesView(store: store)
            case "workflows":
                WorkflowsView(store: store)
            case "archived":
                ArchivedSessionsView(store: store)
            case SessionStore.sessionDashboardId:
                SessionDashboardView(store: store)
            default:
                SessionDetailView(store: store)
            }
        }
        .toolbar(removing: .sidebarToggle)
        .background(WindowToolbarConfigurator())
    }
}

private struct WindowToolbarConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> ToolbarConfigurationView {
        ToolbarConfigurationView()
    }

    func updateNSView(_ nsView: ToolbarConfigurationView, context: Context) {
        nsView.configureSoon()
    }
}

private final class ToolbarConfigurationView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureSoon()
    }

    func configureSoon() {
        DispatchQueue.main.async { [weak self] in
            self?.configureWindowToolbar()
        }
    }

    private func configureWindowToolbar() {
        guard let window, let toolbar = window.toolbar else { return }
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        ensureTitleAccessory(on: window)

        for index in toolbar.items.indices.reversed()
        where isSidebarToggle(toolbar.items[index]) {
            toolbar.removeItem(at: index)
        }
    }

    private func ensureTitleAccessory(on window: NSWindow) {
        let identifier = NSUserInterfaceItemIdentifier("software-factory-title-accessory")
        if window.titlebarAccessoryViewControllers.contains(where: { $0.view.identifier == identifier }) {
            return
        }

        let label = NSTextField(labelWithString: "The Software Factory")
        label.identifier = identifier
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = NSColor(calibratedWhite: 0.13, alpha: 1)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.required, for: .horizontal)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 34))
        container.identifier = identifier
        container.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 68),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor)
        ])

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = container
        accessory.layoutAttribute = .left
        accessory.fullScreenMinHeight = 0
        window.addTitlebarAccessoryViewController(accessory)
    }

    private func isSidebarToggle(_ item: NSToolbarItem) -> Bool {
        item.itemIdentifier == .toggleSidebar
            || item.label.localizedCaseInsensitiveContains("Sidebar")
            || item.paletteLabel.localizedCaseInsensitiveContains("Sidebar")
    }
}
