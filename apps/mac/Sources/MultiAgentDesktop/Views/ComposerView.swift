import SwiftUI

struct ComposerView: View {
    @Bindable var store: SessionStore

    var body: some View {
        VStack(spacing: 8) {
            Divider()
            if !store.daemon.isConnected {
                Text("Connect to the daemon before sending a nudge.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, 8)
            }
            HStack(alignment: .bottom, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $store.composerText)
                        .font(.body)
                        .frame(minHeight: 56, maxHeight: 120)
                        .scrollContentBackground(.hidden)
                    if store.composerText.isEmpty {
                        Text("Nudge the orchestrator...")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))

                Button {
                    store.sendComposerMessage()
                } label: {
                    Label("Send", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!store.canSendComposerMessage)
            }
            .padding()
        }
    }
}
