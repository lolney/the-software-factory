import SwiftUI

struct ComposerView: View {
    @Bindable var store: SessionStore
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            Divider()
            if !store.isConnectionHealthy {
                Text(store.isComposingNewSession ? "The daemon will be started before creating the session." : "Connect to the daemon before sending a nudge.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, 8)
            }
            if store.isComposingNewSession {
                NewSessionSetupView(store: store)
                    .padding(.horizontal)
                    .padding(.top, store.isConnectionHealthy ? 8 : 0)
            }
            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: 8) {
                    if !store.composerImageAttachments.isEmpty {
                        ComposerAttachmentStrip(store: store)
                    }
                    ZStack(alignment: .topLeading) {
                        if store.isComposingNewSession {
                            TextEditor(text: $store.composerText)
                                .font(.body)
                                .frame(minHeight: 120, maxHeight: 220)
                                .scrollContentBackground(.hidden)
                                .padding(4)
                                .focused($composerFocused)
                                .accessibilityLabel("New session prompt")
                        } else {
                            TextField("", text: $store.composerText, axis: .vertical)
                                .font(.body)
                                .textFieldStyle(.plain)
                                .lineLimit(3...8)
                                .padding(8)
                                .frame(minHeight: 56)
                                .focused($composerFocused)
                                .accessibilityLabel("Nudge the orchestrator")
                        }
                        if store.composerText.isEmpty {
                            Text(store.isComposingNewSession ? "Describe the new session goal..." : "Nudge the orchestrator...")
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }

                Button {
                    store.attachComposerImages()
                } label: {
                    Image(systemName: "photo.badge.plus")
                }
                .buttonStyle(.bordered)
                .help("Attach images")
                sendButton
            }
            .padding()
        }
        .onChange(of: store.isComposingNewSession) { _, isComposing in
            if isComposing {
                composerFocused = true
            }
        }
        .onAppear {
            if store.isComposingNewSession {
                composerFocused = true
            }
        }
    }

    @ViewBuilder
    private var sendButton: some View {
        if store.canSendComposerMessage {
            Button {
                store.sendComposerMessage()
            } label: {
                Label(store.isComposingNewSession ? "Create" : "Send", systemImage: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [.command])
        } else {
            Button {
                store.sendComposerMessage()
            } label: {
                Label(store.isComposingNewSession ? "Create" : "Send", systemImage: "paperplane.fill")
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(true)
        }
    }
}

private struct ComposerAttachmentStrip: View {
    @Bindable var store: SessionStore

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.composerImageAttachments) { attachment in
                    ComposerAttachmentChip(attachment: attachment) {
                        store.removeComposerImageAttachment(attachment.id)
                    }
                }
            }
            .padding(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ComposerAttachmentChip: View {
    let attachment: ImageAttachment
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            if let data = attachment.data, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                Image(systemName: "photo")
                    .frame(width: 34, height: 34)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            }
            Text(attachment.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .font(.caption)
                .frame(maxWidth: 160, alignment: .leading)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove image")
        }
        .padding(5)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary)
        }
    }
}

private struct NewSessionSetupView: View {
    @Bindable var store: SessionStore

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                modePicker
                authStatus
            }
            VStack(alignment: .leading, spacing: 8) {
                modePicker
                authStatus
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary)
        }
    }

    private var modePicker: some View {
        Picker("Mode", selection: $store.debugMode) {
            Text("Live").tag(false)
            Text("Debug").tag(true)
        }
        .pickerStyle(.segmented)
        .frame(width: 168)
        .disabled(store.isCreatingSession)
    }

    @ViewBuilder
    private var authStatus: some View {
        if store.debugMode {
            Label("Debug session", systemImage: "wrench.and.screwdriver")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if store.authStatus?.liveCredentialConfigured == true {
            Label("Live credentials ready", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Label("Live credentials needed in Settings", systemImage: "person.badge.key")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}
