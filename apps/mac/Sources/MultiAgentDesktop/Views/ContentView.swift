import SwiftUI

struct ContentView: View {
    @Bindable var store: SessionStore

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            SessionDetailView(store: store)
        }
        .sheet(isPresented: $store.presentNewSession) {
            NewSessionView(store: store)
        }
    }
}
