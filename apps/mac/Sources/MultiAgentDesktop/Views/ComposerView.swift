import SwiftUI

struct ComposerView: View {
    @Bindable var store: SessionStore

    var body: some View {
        VStack(spacing: 8) {
            Divider()
            if !store.daemon.isConnected {
                Text(store.isComposingNewSession ? "The daemon will be started before creating the session." : "Connect to the daemon before sending a nudge.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, 8)
            }
            if store.isComposingNewSession {
                HStack(spacing: 12) {
                    Picker("Mode", selection: $store.debugMode) {
                        Text("Live").tag(false)
                        Text("Debug").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                    .disabled(store.isCreatingSession)

                    Text(store.debugMode ? "Debug uses deterministic pre-programmed agent I/O." : "Live uses OpenAI authentication from Settings or OPENAI_API_KEY.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, store.daemon.isConnected ? 8 : 0)

                if !store.debugMode && store.authStatus?.connected != true {
                    Label("Live mode needs OpenAI OAuth in Settings or OPENAI_API_KEY on the daemon.", systemImage: "person.badge.key")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $store.composerText)
                        .font(.body)
                        .frame(minHeight: 56, maxHeight: 120)
                        .scrollContentBackground(.hidden)
                    if store.composerText.isEmpty {
                        Text(store.isComposingNewSession ? "Describe the new session goal..." : "Nudge the orchestrator...")
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
                    Label(store.isComposingNewSession ? "Create" : "Send", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!store.canSendComposerMessage)
            }
            .padding()
        }
    }
}
