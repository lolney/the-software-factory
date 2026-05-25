import SwiftUI

struct ComposerView: View {
    @Bindable var store: SessionStore
    @FocusState private var composerFocused: Bool

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
                NewSessionSetupView(store: store)
                    .padding(.horizontal)
                    .padding(.top, store.daemon.isConnected ? 8 : 0)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Picker("Mode", selection: $store.debugMode) {
                    Text("Live").tag(false)
                    Text("Debug").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .disabled(store.isCreatingSession)

                Picker("Model", selection: $store.newSessionModel) {
                    ForEach(modelOptions, id: \.self) { model in
                        Text(model.isEmpty ? "Role default" : model).tag(model)
                    }
                }
                .frame(width: 190)
                .disabled(store.isCreatingSession || store.debugMode)

                TextField("Override model", text: $store.newSessionModel)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)
                    .disabled(store.isCreatingSession || store.debugMode)

                Picker("Effort", selection: $store.newSessionReasoningEffort) {
                    ForEach(effortOptions, id: \.self) { effort in
                        Text(effort == "none" ? "Model default" : effort.capitalized).tag(effort)
                    }
                }
                .frame(width: 170)
                .disabled(store.isCreatingSession || store.debugMode)

                Spacer()
            }

            HStack(spacing: 8) {
                Label(workspaceLabel, systemImage: store.newSessionWorkspaceRoot.isEmpty ? "folder.badge.plus" : "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    store.useBlankWorkspace()
                } label: {
                    Label("Quick Setup", systemImage: "sparkles")
                }
                .disabled(store.isCreatingSession)
                Button {
                    store.chooseNewSessionWorkspace()
                } label: {
                    Label("Choose Parent Folder…", systemImage: "folder")
                }
                .disabled(store.isCreatingSession)
            }

            if !store.debugMode && store.authStatus == nil {
                HStack(spacing: 8) {
                    Label("Checking OpenAI credential status…", systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        store.beginOpenAIOAuth()
                    } label: {
                        Label("Set Up OpenAI…", systemImage: "person.badge.key")
                    }
                    Button {
                        store.refreshAuthStatus()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
            } else if !store.debugMode && store.authStatus?.liveCredentialConfigured != true {
                HStack(spacing: 8) {
                    Label("Live mode needs OpenAI OAuth or an API key before the session can start.", systemImage: "person.badge.key")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button {
                        store.beginOpenAIOAuth()
                    } label: {
                        Label("Set Up OpenAI…", systemImage: "person.badge.key")
                    }
                    Button {
                        store.refreshAuthStatus()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
    }

    private var workspaceLabel: String {
        store.newSessionWorkspaceRoot.isEmpty
            ? "Quick setup: create a blank workspace in Application Support"
            : "Parent folder: \(store.newSessionWorkspaceRoot)"
    }
}
