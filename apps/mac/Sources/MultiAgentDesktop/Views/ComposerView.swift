import SwiftUI
import AppKit

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
                            PasteAwareComposerTextView(
                                text: $store.composerText,
                                onPasteImages: { store.pasteComposerImagesFromPasteboard() }
                            )
                                .frame(minHeight: 120, maxHeight: 220)
                                .accessibilityLabel("New session prompt")
                        } else {
                            PasteAwareComposerTextView(
                                text: $store.composerText,
                                onPasteImages: { store.pasteComposerImagesFromPasteboard() }
                            )
                                .frame(minHeight: 56)
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

private struct PasteAwareComposerTextView: NSViewRepresentable {
    @Binding var text: String
    let onPasteImages: () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> ComposerNSTextView {
        let textView = ComposerNSTextView()
        textView.delegate = context.coordinator
        textView.onPasteImages = onPasteImages
        textView.string = text
        textView.isEditable = true
        textView.isSelectable = true
        textView.font = NSFont.preferredFont(forTextStyle: .body)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        return textView
    }

    func updateNSView(_ textView: ComposerNSTextView, context: Context) {
        textView.delegate = context.coordinator
        textView.onPasteImages = onPasteImages
        if textView.string != text {
            textView.string = text
        }
        textView.font = NSFont.preferredFont(forTextStyle: .body)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }
    }
}

private final class ComposerNSTextView: NSTextView {
    var onPasteImages: (() -> Bool)?

    override func paste(_ sender: Any?) {
        if pasteComposerImageIfPresent() {
            return
        }
        super.paste(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command,
           event.charactersIgnoringModifiers?.lowercased() == "v",
           pasteComposerImageIfPresent() {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func pasteComposerImageIfPresent() -> Bool {
        if NSPasteboard.general.containsComposerImage,
           onPasteImages?() == true {
            return true
        }
        return false
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
