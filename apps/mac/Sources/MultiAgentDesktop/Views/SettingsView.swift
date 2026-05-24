import SwiftUI

struct SettingsView: View {
    @AppStorage("daemonPort") private var daemonPort = 3767

    var body: some View {
        Form {
            TextField("Daemon Port", value: $daemonPort, format: .number)
                .frame(width: 220)
        }
        .padding()
        .frame(width: 360)
    }
}
