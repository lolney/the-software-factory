import SwiftUI

struct ContentView: View {
    @Bindable var store: SessionStore

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            switch store.selectedSidebarItem {
            case "roles":
                RolesView(store: store)
            case "workflows":
                WorkflowsView(store: store)
            default:
                SessionDetailView(store: store)
            }
        }
        .sheet(isPresented: $store.presentNewSession) {
            NewSessionView(store: store)
        }
    }
}
