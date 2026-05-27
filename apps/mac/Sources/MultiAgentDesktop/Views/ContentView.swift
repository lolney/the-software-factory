import SwiftUI
import AppKit

struct ContentView: View {
    @Bindable var store: SessionStore

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(274)
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
        .background(WindowToolbarConfigurator(usesReferenceFrame: store.usesStaticMockupFixture))
    }
}

private struct WindowToolbarConfigurator: NSViewRepresentable {
    let usesReferenceFrame: Bool

    func makeNSView(context: Context) -> ToolbarConfigurationView {
        ToolbarConfigurationView(usesReferenceFrame: usesReferenceFrame)
    }

    func updateNSView(_ nsView: ToolbarConfigurationView, context: Context) {
        nsView.usesReferenceFrame = usesReferenceFrame
        nsView.configureSoon()
    }
}

private final class ToolbarConfigurationView: NSView {
    var usesReferenceFrame: Bool
    private var referenceFrameApplications = 0

    init(usesReferenceFrame: Bool) {
        self.usesReferenceFrame = usesReferenceFrame
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureSoon()
    }

    func configureSoon() {
        DispatchQueue.main.async { [weak self] in
            self?.configureWindowToolbar()
        }
        guard usesReferenceFrame else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.configureWindowToolbar()
        }
    }

    private func configureWindowToolbar() {
        guard let window, let toolbar = window.toolbar else { return }
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        applyReferenceFrameIfNeeded(to: window)
        ensureTitleAccessory(on: window)

        for index in toolbar.items.indices.reversed()
        where isSidebarToggle(toolbar.items[index]) {
            toolbar.removeItem(at: index)
        }
    }

    private func applyReferenceFrameIfNeeded(to window: NSWindow) {
        guard usesReferenceFrame, referenceFrameApplications < 2 else { return }
        referenceFrameApplications += 1
        let targetSize = NSSize(width: 1586, height: 992)
        let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        let origin = NSPoint(
            x: visibleFrame.minX,
            y: max(visibleFrame.minY, visibleFrame.maxY - targetSize.height)
        )
        window.setFrame(NSRect(origin: origin, size: targetSize), display: true)
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
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 54),
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
