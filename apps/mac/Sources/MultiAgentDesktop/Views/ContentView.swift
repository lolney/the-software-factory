import SwiftUI

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
    }
}
