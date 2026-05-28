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
}

private struct NewSessionSetupView: View {
    @Bindable var store: SessionStore

    private let modelOptions = ["", "gpt-5.4", "gpt-5.4-mini", "gpt-5.3-codex", "gpt-5.3-codex-spark"]
    private let effortOptions = ["none", "minimal", "low", "medium", "high", "xhigh"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            runtimeRow
            Divider()
            workspaceRow
            authRow
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary)
        }
    }

    private var workspaceLabel: String {
        store.newSessionWorkspaceRoot.isEmpty
            ? "Quick setup: create a blank workspace in Application Support"
            : "Parent folder: \(store.newSessionWorkspaceRoot)"
    }

    private var runtimeRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Runtime")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    modePicker
                    modelPicker
                    modelOverrideField
                    effortPicker
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        modePicker
                        effortPicker
                    }
                    HStack(spacing: 12) {
                        modelPicker
                        modelOverrideField
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    modePicker
                    modelPicker
                    modelOverrideField
                    effortPicker
                }
            }
        }
    }

    private var modePicker: some View {
        Picker("Mode", selection: $store.debugMode) {
            Text("Live").tag(false)
            Text("Debug").tag(true)
        }
        .pickerStyle(.segmented)
        .frame(width: 180)
        .disabled(store.isCreatingSession)
    }

    private var modelPicker: some View {
        Picker("Model", selection: $store.newSessionModel) {
            ForEach(modelOptions, id: \.self) { model in
                Text(model.isEmpty ? "Role default" : model).tag(model)
            }
        }
        .frame(width: 190)
        .disabled(store.isCreatingSession || store.debugMode)
    }

    private var modelOverrideField: some View {
        TextField("Override model", text: $store.newSessionModel)
            .textFieldStyle(.roundedBorder)
            .frame(width: 170)
            .disabled(store.isCreatingSession || store.debugMode)
    }

    private var effortPicker: some View {
        Picker("Effort", selection: $store.newSessionReasoningEffort) {
            ForEach(effortOptions, id: \.self) { effort in
                Text(effort == "none" ? "Model default" : effort.capitalized).tag(effort)
            }
        }
        .frame(width: 170)
        .disabled(store.isCreatingSession || store.debugMode)
    }

    private var workspaceRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Workspace")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    workspaceStatus
                        .frame(minWidth: 260, alignment: .leading)
                    workspaceActions(labelStyle: .titleAndIcon)
                }
                VStack(alignment: .leading, spacing: 8) {
                    workspaceStatus
                    workspaceActions(labelStyle: .iconOnly)
                }
                VStack(alignment: .leading, spacing: 8) {
                    workspaceStatus
                    workspaceActions(labelStyle: .titleAndIcon)
                }
            }
        }
    }

    private var workspaceStatus: some View {
        Label(workspaceLabel, systemImage: store.newSessionWorkspaceRoot.isEmpty ? "folder.badge.plus" : "folder")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .truncationMode(.middle)
    }

    private func workspaceActions(labelStyle: NewSessionSetupActionLabelStyle) -> some View {
        HStack(spacing: 8) {
            Button {
                store.useBlankWorkspace()
            } label: {
                Label("Blank Workspace", systemImage: "sparkles")
                    .newSessionSetupLabelStyle(labelStyle)
            }
            .disabled(store.isCreatingSession)
            .help("Create a blank workspace")
            .accessibilityLabel("Create a blank workspace")
            Button {
                store.chooseNewSessionWorkspace()
            } label: {
                Label("Choose Folder…", systemImage: "folder")
                    .newSessionSetupLabelStyle(labelStyle)
            }
            .disabled(store.isCreatingSession)
            .help("Choose parent folder")
            .accessibilityLabel("Choose parent folder")
        }
    }

    @ViewBuilder
    private var authRow: some View {
        if !store.debugMode && store.authStatus == nil {
            authStatusRow(
                title: "Checking OpenAI credential status…",
                color: .secondary
            )
        } else if !store.debugMode && store.authStatus?.liveCredentialConfigured != true {
            authStatusRow(
                title: "Live mode needs OpenAI OAuth or an API key before the session can start.",
                color: .orange
            )
        }
    }

    private func authStatusRow(title: String, color: Color) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                authStatusLabel(title: title, color: color)
                    .frame(minWidth: 260, alignment: .leading)
                authActions(labelStyle: .titleAndIcon)
            }
            VStack(alignment: .leading, spacing: 8) {
                authStatusLabel(title: title, color: color)
                authActions(labelStyle: .iconOnly)
            }
            VStack(alignment: .leading, spacing: 8) {
                authStatusLabel(title: title, color: color)
                authActions(labelStyle: .titleAndIcon)
            }
        }
    }

    private func authStatusLabel(title: String, color: Color) -> some View {
        Label(title, systemImage: "person.badge.key")
            .font(.caption)
            .foregroundStyle(color)
            .lineLimit(2)
    }

    private func authActions(labelStyle: NewSessionSetupActionLabelStyle) -> some View {
        HStack(spacing: 8) {
            Button {
                store.beginOpenAIOAuth()
            } label: {
                Label("Set Up OpenAI…", systemImage: "person.badge.key")
                    .newSessionSetupLabelStyle(labelStyle)
            }
            .help("Set up OpenAI credentials")
            .accessibilityLabel("Set up OpenAI credentials")
            Button {
                store.refreshAuthStatus()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .newSessionSetupLabelStyle(labelStyle)
            }
            .help("Refresh credential status")
            .accessibilityLabel("Refresh credential status")
        }
    }
}

private enum NewSessionSetupActionLabelStyle {
    case titleAndIcon
    case iconOnly
}

private extension View {
    @ViewBuilder
    func newSessionSetupLabelStyle(_ style: NewSessionSetupActionLabelStyle) -> some View {
        switch style {
        case .titleAndIcon:
            self.labelStyle(.titleAndIcon)
        case .iconOnly:
            self.labelStyle(.iconOnly)
        }
    }
}
