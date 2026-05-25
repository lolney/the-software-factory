import Foundation
import AppKit
import Observation

@MainActor
@Observable
final class SessionStore {
    static let newSessionDraftId = "new-session-draft"
    static let sessionDashboardId = "session-dashboard"

    var sessions: [SessionSummary] = []
    var archivedSessions: [SessionSummary] = []
    var selectedSessionId: String?
    var selectedSidebarItem: String?
    var selectedSidebarItems: Set<String> = []
    var dashboardSessionFilterIds: Set<String> = []
    var graph = GraphState(sessionId: "", workflowId: "", nodes: [], edges: [])
    var transcript: [TranscriptItem] = []
    var debugLogs: [DebugLogItem] = []
    var inspectorPanel: InspectorPanel = .graph
    var roles: [RoleSpec] = []
    var workflows: [WorkflowSpec] = []
    var personalRolesPath: String?
    var personalWorkflowsPath: String?
    var authStatus: AuthStatus?
    var integrations = IntegrationCatalog(mcpServers: [], skills: [])
    var currentWorkspaceRoot: String?
    var currentSessionDebugMode: Bool?
    var isComposingNewSession = false
    var composerText = ""
    var openAIApiKeyInput = ""
    var chatGPTAccountIdInput = ""
    var connectionStatus = "Disconnected"
    var debugMode = false
    var newSessionWorkspaceRoot = ""
    var newSessionModel = ""
    var newSessionReasoningEffort = "none"
    var isCreatingSession = false
    var lastError: String?
    var selectedAgentId: String?
    var controlAgentId: String?
    var transcriptSearchText = ""
    var isLoadingSelection = false
    private var subscribedSessionIds = Set<String>()
    private var subscribedDebugLogSessionIds = Set<String>()
    private var pendingCreatePrompt: String?
    private var pendingOpenAIOAuth = false
    private let localDaemonLauncher = LocalDaemonLauncher()
    @ObservationIgnored private var sessionRefreshTask: Task<Void, Never>?

    var daemonPort: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: "daemonPort")
            return stored == 0 ? 3767 : stored
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "daemonPort")
        }
    }

    let daemon = DaemonClient()

    var hasActiveSession: Bool {
        selectedSessionId != nil
    }

    var visibleSessions: [SessionSummary] {
        sessions.filter { $0.archived != true }
    }

    var selectedSessionArchived: Bool {
        guard let selectedSessionId else { return false }
        return archivedSessions.contains { $0.id == selectedSessionId }
    }

    var selectedArchivedSession: SessionSummary? {
        guard let selectedSessionId else { return nil }
        return archivedSessions.first { $0.id == selectedSessionId }
    }

    var selectedSessionIdsForActions: [String] {
        let sessionIds = Set((sessions + archivedSessions).map(\.id))
        let selected = selectedSidebarItems.filter { sessionIds.contains($0) }
        if !selected.isEmpty {
            return Array(selected)
        }
        return selectedSessionId.map { [$0] } ?? []
    }

    var canSendComposerMessage: Bool {
        let hasText = !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isComposingNewSession {
            return hasText && !isCreatingSession && (debugMode || authStatus?.liveCredentialConfigured == true)
        }
        return daemon.isConnected && hasActiveSession && !selectedSessionArchived && ![.paused, .cancelled, .failed, .completed].contains(orchestratorStatus) && hasText
    }

    var orchestratorStatus: AgentStatus {
        graph.nodes.first { $0.id == selectedControlAgentId }?.status ?? .idle
    }

    var selectedControlAgentId: String {
        if let controlAgentId,
           graph.nodes.contains(where: { $0.id == controlAgentId }) {
            return controlAgentId
        }
        if graph.nodes.contains(where: { $0.id == "orchestrator" }) {
            return "orchestrator"
        }
        return graph.nodes.first?.id ?? "orchestrator"
    }

    var selectedControlAgentLabel: String {
        graph.nodes.first { $0.id == selectedControlAgentId }?.label ?? selectedControlAgentId
    }

    var filteredTranscript: [TranscriptItem] {
        let visibleTranscript: [TranscriptItem]
        if let selectedAgentId {
            visibleTranscript = transcript.filter { item in
                item.agentId == selectedAgentId || item.sender == selectedAgentId || item.recipient == selectedAgentId
            }
        } else {
            visibleTranscript = transcript
        }

        let query = transcriptSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return visibleTranscript }
        return visibleTranscript.filter { item in
            item.searchText.localizedCaseInsensitiveContains(query)
        }
    }

    var sessionErrorCount: Int {
        graph.nodes.reduce(0) { total, node in total + node.errorCount }
    }

    var statusBannerText: String? {
        if let lastError, !lastError.isEmpty {
            return lastError
        }
        if sessionErrorCount > 0 {
            let suffix = sessionErrorCount == 1 ? "" : "s"
            return "\(sessionErrorCount) agent error\(suffix) in this session. Open Debug for details."
        }
        return nil
    }

    var touchedWorkspaceFiles: [WorkspaceFileSummary] {
        var summaries: [String: WorkspaceFileSummary] = [:]
        for item in transcript where item.type == "workspace.file_touched" || item.type == "workspace.conflict_detected" {
            guard let path = item.payload["path"]?.stringValue ?? item.text.nilIfEmpty else { continue }
            var summary = summaries[path] ?? WorkspaceFileSummary(
                path: path,
                lastAgentId: item.agentId,
                lastEventType: item.type,
                lastTimestamp: item.timestamp,
                additions: 0,
                deletions: 0,
                conflictCount: 0
            )
            summary.lastAgentId = item.agentId ?? summary.lastAgentId
            summary.lastEventType = item.type
            summary.lastTimestamp = item.timestamp
            if item.type == "workspace.conflict_detected" {
                summary.conflictCount += 1
            }
            if let stats = item.payload["diffStats"]?.objectValue {
                summary.additions += Int(stats["additions"]?.numberValue ?? 0)
                summary.deletions += Int(stats["deletions"]?.numberValue ?? 0)
            }
            summaries[path] = summary
        }
        return summaries.values.sorted { left, right in
            left.lastTimestamp > right.lastTimestamp
        }
    }

    var isTranscriptFiltered: Bool {
        selectedAgentId != nil || !transcriptSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var transcriptFilterLabel: String {
        guard let selectedAgentId else { return "All Agents" }
        return graph.nodes.first { $0.id == selectedAgentId }?.label ?? selectedAgentId
    }

    var canPauseOrchestrator: Bool {
        daemon.isConnected && hasActiveSession && !selectedSessionArchived && [.idle, .working, .waiting].contains(orchestratorStatus)
    }

    var canResumeOrchestrator: Bool {
        daemon.isConnected && hasActiveSession && !selectedSessionArchived && orchestratorStatus == .paused
    }

    var canCancelOrchestrator: Bool {
        daemon.isConnected && hasActiveSession && !selectedSessionArchived && ![.cancelled, .completed].contains(orchestratorStatus)
    }

    init() {
        sessions = []
        selectedSessionId = nil
        selectedSidebarItem = nil
        selectedAgentId = nil
        resetPreview()
        daemon.onMessage = { [weak self] data in
            Task { @MainActor in
                self?.handleDaemonMessage(data)
            }
        }
        daemon.onDisconnect = { [weak self] reason in
            Task { @MainActor in
                self?.connectionStatus = "Disconnected"
                self?.lastError = reason
                self?.isCreatingSession = false
                self?.pendingCreatePrompt = nil
                self?.pendingOpenAIOAuth = false
                self?.stopSessionRefreshLoop()
            }
        }
        daemon.onSendError = { [weak self] reason in
            Task { @MainActor in
                self?.lastError = reason
                self?.isCreatingSession = false
                self?.pendingCreatePrompt = nil
                self?.pendingOpenAIOAuth = false
            }
        }
    }

    func connectAndRefresh() {
        Task { @MainActor in
            await connectAndRefreshAsync()
        }
    }

    func shutdownLocalDaemon() {
        stopSessionRefreshLoop()
        daemon.disconnect()
        localDaemonLauncher.stop()
    }

    func refreshSessions() {
        daemon.sendRequest(method: "listSessions", params: ["includeArchived": true])
    }

    func refreshForAppActivation() {
        if daemon.isConnected {
            refreshSessions()
            refreshCatalogs()
        } else {
            connectAndRefresh()
        }
    }

    private func connectAndRefreshAsync() async {
        connectionStatus = daemon.isConnected ? "Connected" : "Connecting"
        lastError = nil
        let daemonStarted = await localDaemonLauncher.ensureStarted(port: daemonPort)
        guard daemonStarted else {
            connectionStatus = "Disconnected"
            lastError = "Could not start the local daemon. Check ~/Library/Application Support/MultiAgentDesktop/logs/app-daemon.log for details."
            return
        }
        daemon.connect(port: daemonPort)
        try? await Task.sleep(for: .milliseconds(250))
        if let prompt = pendingCreatePrompt {
            pendingCreatePrompt = nil
            sendCreateSession(prompt: prompt)
            return
        }
        refreshSessions()
        refreshCatalogs()
        startSessionRefreshLoop()
    }

    func refreshCatalogs() {
        daemon.sendRequest(method: "listRoles", params: [:])
        daemon.sendRequest(method: "listWorkflows", params: [:])
        daemon.sendRequest(method: "getAuthStatus", params: [:])
        daemon.sendRequest(method: "listIntegrations", params: [:])
    }

    private func startSessionRefreshLoop() {
        sessionRefreshTask?.cancel()
        sessionRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { break }
                self?.refreshSessions()
            }
        }
    }

    private func stopSessionRefreshLoop() {
        sessionRefreshTask?.cancel()
        sessionRefreshTask = nil
    }

    func createSession(prompt: String) {
        guard daemon.isConnected else {
            pendingCreatePrompt = prompt
            isCreatingSession = true
            connectAndRefresh()
            lastError = "Connecting to daemon. The session will be created automatically."
            return
        }
        sendCreateSession(prompt: prompt)
    }

    func cancelNewSession() {
        pendingCreatePrompt = nil
        isCreatingSession = false
        isComposingNewSession = false
        if selectedSidebarItem == Self.newSessionDraftId {
            if let selectedSessionId {
                selectSession(selectedSessionId)
            } else if let first = sessions.first {
                selectSession(first.id)
            } else {
                selectedSessionId = nil
                selectedSidebarItem = nil
                resetPreview()
            }
        }
    }

    private func sendCreateSession(prompt: String) {
        isCreatingSession = true
        lastError = nil
        let workflowId = selectedWorkflowId(for: prompt)
        var params: [String: Any] = [
            "prompt": prompt,
            "workflowId": workflowId,
            "debugMode": debugMode
        ]
        let model = newSessionModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty {
            params["model"] = model
        }
        if newSessionReasoningEffort != "none" {
            params["reasoningEffort"] = newSessionReasoningEffort
        }
        let workspaceRoot = newSessionWorkspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        if !workspaceRoot.isEmpty {
            params["workspaceRoot"] = workspaceRoot
        }
        daemon.sendRequest(method: "createSession", params: params)
    }

    func selectSidebarItem(_ item: String?) {
        selectedSidebarItem = item
        selectedSidebarItems = item.map { [$0] } ?? []
        guard let item else { return }
        if item == "roles" || item == "workflows" || item == "archived" || item == Self.sessionDashboardId {
            return
        }
        if item == Self.newSessionDraftId {
            beginNewSession()
            return
        }
        selectSession(item)
    }

    func selectSidebarItems(_ items: Set<String>) {
        selectedSidebarItems = items
        guard !items.isEmpty else {
            selectedSidebarItem = nil
            return
        }
        if items.contains("roles") {
            selectSidebarItem("roles")
            return
        }
        if items.contains("workflows") {
            selectSidebarItem("workflows")
            return
        }
        if items.contains("archived") {
            selectSidebarItem("archived")
            return
        }
        if items.contains(Self.sessionDashboardId) {
            selectSidebarItem(Self.sessionDashboardId)
            return
        }
        if items.contains(Self.newSessionDraftId) {
            selectSidebarItem(Self.newSessionDraftId)
            return
        }
        let sessionIds = Set((sessions + archivedSessions).map(\.id))
        let selectedSessionRows = items.filter { sessionIds.contains($0) }
        if selectedSessionRows.count > 1 {
            dashboardSessionFilterIds = selectedSessionRows
            selectedSidebarItem = Self.sessionDashboardId
            return
        }
        if let current = selectedSessionId, items.contains(current) {
            selectedSidebarItem = current
            return
        }
        let orderedSessions = (sessions + archivedSessions).map(\.id)
        if let sessionId = orderedSessions.first(where: { items.contains($0) }) {
            selectSession(sessionId)
        }
    }

    func selectSession(_ sessionId: String?) {
        guard let sessionId else { return }
        isComposingNewSession = false
        selectedSessionId = sessionId
        selectedSidebarItem = sessionId
        selectedSidebarItems = [sessionId]
        isLoadingSelection = true
        currentWorkspaceRoot = (sessions + archivedSessions).first { $0.id == sessionId }?.workspaceRoot
        currentSessionDebugMode = nil
        graph = GraphState(sessionId: sessionId, workflowId: "", nodes: [], edges: [])
        transcript = []
        debugLogs = []
        daemon.sendRequest(method: "getSnapshot", params: ["sessionId": sessionId])
        subscribe(to: sessionId)
        subscribeDebugLogs(to: sessionId)
    }

    func selectAgent(_ agentId: String?) {
        selectedAgentId = agentId
        guard let agentId,
              let index = graph.nodes.firstIndex(where: { $0.id == agentId }) else { return }
        graph.nodes[index].unreadCount = 0
        if let last = transcript.reversed().first(where: { item in
            item.agentId == agentId || item.sender == agentId || item.recipient == agentId
        }) {
            daemon.sendRequest(method: "ackClientEvent", params: ["sessionId": graph.sessionId, "eventId": last.id])
        }
    }

    func setControlAgent(_ agentId: String?) {
        controlAgentId = agentId
    }

    func clearLastError() {
        lastError = nil
    }

    func sendComposerMessage() {
        let trimmed = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if isComposingNewSession {
            createSession(prompt: trimmed)
            return
        }
        guard let selectedSessionId, daemon.isConnected else { return }
        daemon.sendRequest(method: "sendMessage", params: [
            "sessionId": selectedSessionId,
            "text": trimmed
        ])
        composerText = ""
    }

    func pauseOrchestrator() {
        guard let selectedSessionId else { return }
        daemon.sendRequest(method: "pauseAgent", params: ["sessionId": selectedSessionId, "agentId": selectedControlAgentId])
    }

    func resumeOrchestrator() {
        guard let selectedSessionId else { return }
        daemon.sendRequest(method: "resumeAgent", params: ["sessionId": selectedSessionId, "agentId": selectedControlAgentId])
    }

    func cancelOrchestrator() {
        guard let selectedSessionId else { return }
        daemon.sendRequest(method: "cancelAgent", params: ["sessionId": selectedSessionId, "agentId": selectedControlAgentId])
    }

    func archiveSessions(_ sessionIds: [String], archived: Bool = true) {
        let ids = Array(Set(sessionIds)).filter { !$0.isEmpty }
        guard !ids.isEmpty else { return }
        daemon.sendRequest(method: "archiveSessions", params: ["sessionIds": ids, "archived": archived])
    }

    func archiveSelectedSessions() {
        archiveSessions(selectedSessionIdsForActions, archived: true)
    }

    func restoreSessions(_ sessionIds: [String]) {
        archiveSessions(sessionIds, archived: false)
    }

    func viewSelectedSessions() {
        let ids = selectedSessionIdsForActions
        dashboardSessionFilterIds = Set(ids)
        selectedSidebarItem = Self.sessionDashboardId
        selectedSidebarItems = [Self.sessionDashboardId]
    }

    func viewAllSessions() {
        dashboardSessionFilterIds = []
        selectedSidebarItem = Self.sessionDashboardId
        selectedSidebarItems = [Self.sessionDashboardId]
    }

    func chooseNewSessionWorkspace() {
        let panel = NSOpenPanel()
        panel.title = "Choose Session Parent Folder"
        panel.message = "Agents will work inside <selected folder>/<session id>/workspace."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            newSessionWorkspaceRoot = url.path
        }
    }

    func useBlankWorkspace() {
        newSessionWorkspaceRoot = ""
    }

    func saveRole(_ role: RoleSpec) {
        guard let payload = jsonObject(role) else { return }
        daemon.sendRequest(method: "upsertRole", params: ["role": payload])
    }

    func deleteRole(_ role: RoleSpec) {
        guard canDeleteRole(role) else {
            lastError = "Built-in roles cannot be deleted."
            return
        }
        lastError = nil
        daemon.sendRequest(method: "deleteRole", params: ["roleId": role.id])
    }

    func canDeleteRole(_ role: RoleSpec) -> Bool {
        !Self.builtInRoleIds.contains(role.id)
    }

    func addRole() {
        lastError = nil
        daemon.sendRequest(method: "createRoleFile", params: [:])
    }

    func addWorkflowFile() {
        lastError = nil
        daemon.sendRequest(method: "createWorkflowFile", params: [:])
    }

    func copyPersonalRolesPath() {
        copyPath(personalRolesPath, fallback: "Roles directory has not been reported by the daemon yet.")
    }

    func copyPersonalWorkflowsPath() {
        copyPath(personalWorkflowsPath, fallback: "Workflows directory has not been reported by the daemon yet.")
    }

    func copyCurrentWorkspacePath() {
        copyPath(currentWorkspaceRoot, fallback: "This session does not have a workspace yet.")
    }

    func copyWorkspaceFilePath(_ relativePath: String) {
        guard !relativePath.isEmpty else {
            lastError = "No file path was recorded for this workspace event."
            return
        }
        let path: String
        if relativePath.hasPrefix("/") {
            path = relativePath
        } else if let currentWorkspaceRoot {
            path = URL(fileURLWithPath: currentWorkspaceRoot).appendingPathComponent(relativePath).path
        } else {
            lastError = "This session does not have a workspace yet."
            return
        }
        copyText(path)
    }

    func copyWorkspaceDiff(for relativePath: String) {
        let diffs = transcript
            .filter { $0.type == "workspace.file_touched" && $0.payload["path"]?.stringValue == relativePath }
            .compactMap { $0.payload["diff"]?.stringValue }
            .filter { !$0.isEmpty }
        guard !diffs.isEmpty else {
            lastError = "No recorded diff for \(relativePath)."
            return
        }
        copyText(diffs.joined(separator: "\n\n"))
    }

    func instantiateWorkflow(_ workflowId: String) {
        guard let selectedSessionId else {
            lastError = "Select a session before instantiating a workflow."
            return
        }
        daemon.sendRequest(method: "instantiateWorkflow", params: ["sessionId": selectedSessionId, "workflowId": workflowId])
    }

    func beginOpenAIOAuth() {
        guard daemon.isConnected else {
            pendingOpenAIOAuth = true
            connectAndRefresh()
            lastError = "Connecting to daemon. OpenAI setup will continue automatically."
            return
        }
        sendBeginOpenAIOAuth()
    }

    private func sendBeginOpenAIOAuth() {
        lastError = nil
        daemon.sendRequest(method: "beginOpenAIOAuth", params: ["port": daemonPort])
        Task { @MainActor in
            for _ in 0..<10 {
                try? await Task.sleep(for: .seconds(3))
                refreshAuthStatus()
            }
        }
    }

    func refreshAuthStatus() {
        daemon.sendRequest(method: "getAuthStatus", params: [:])
    }

    func disconnectOpenAIOAuth() {
        daemon.sendRequest(method: "disconnectOpenAIOAuth", params: [:])
    }

    func saveChatGPTAccountId() {
        let trimmed = chatGPTAccountIdInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = "Paste a ChatGPT account id before saving."
            return
        }
        lastError = nil
        daemon.sendRequest(method: "setChatGPTAccountId", params: ["accountId": trimmed])
        chatGPTAccountIdInput = ""
    }

    func disconnectChatGPTAccountId() {
        daemon.sendRequest(method: "disconnectChatGPTAccountId", params: [:])
    }

    func saveOpenAIAPIKey() {
        let trimmed = openAIApiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = "Paste an OpenAI API key before saving."
            return
        }
        lastError = nil
        daemon.sendRequest(method: "setOpenAIAPIKey", params: ["apiKey": trimmed])
        openAIApiKeyInput = ""
    }

    func disconnectOpenAIAPIKey() {
        daemon.sendRequest(method: "disconnectOpenAIAPIKey", params: [:])
    }

    func refreshIntegrations() {
        daemon.sendRequest(method: "listIntegrations", params: [:])
    }

    func reconnectMCPServers(serverId: String? = nil) {
        lastError = nil
        var params: [String: Any] = [:]
        if let serverId {
            params["serverId"] = serverId
        }
        daemon.sendRequest(method: "reconnectMCPServers", params: params)
    }

    func beginMCPAuth(serverId: String) {
        lastError = nil
        daemon.sendRequest(method: "beginMCPAuth", params: ["serverId": serverId])
    }

    func openWorkspace(tool: WorkspaceOpenTool = .vsCode) {
        guard let currentWorkspaceRoot else {
            lastError = "This session does not have a workspace yet."
            return
        }
        let url = URL(fileURLWithPath: currentWorkspaceRoot)
        switch tool {
        case .finder:
            NSWorkspace.shared.open(url)
        case .vsCode:
            if !openVSCode(path: currentWorkspaceRoot) {
                lastError = "Could not open VS Code. Install Visual Studio Code or the 'code' command-line tool."
            }
        case .iTerm:
            if !openBundleIdentifier("com.googlecode.iterm2", path: currentWorkspaceRoot) && !openApplication("iTerm", path: currentWorkspaceRoot) {
                lastError = "Could not open iTerm."
            }
        }
    }

    func beginNewSession() {
        isComposingNewSession = true
        isCreatingSession = false
        pendingCreatePrompt = nil
        composerText = ""
        newSessionWorkspaceRoot = ""
        newSessionModel = ""
        newSessionReasoningEffort = "none"
        selectedSessionId = nil
        selectedSidebarItem = Self.newSessionDraftId
        selectedSidebarItems = [Self.newSessionDraftId]
        selectedAgentId = nil
        controlAgentId = nil
        currentWorkspaceRoot = nil
        currentSessionDebugMode = nil
        isLoadingSelection = false
        graph = GraphState(sessionId: Self.newSessionDraftId, workflowId: "planner-orchestrator", nodes: [], edges: [])
        transcript = [
            TranscriptItem(
                id: UUID().uuidString,
                agentId: "orchestrator",
                sender: "orchestrator",
                recipient: nil,
                type: "message",
                text: "Write the initial prompt below. It will be sent as the first message to the orchestrator when the session is created.",
                timestamp: Date(),
                payload: [:],
                causationId: nil,
                correlationId: nil
            )
        ]
        debugLogs = []
        if daemon.isConnected {
            refreshAuthStatus()
        } else {
            connectAndRefresh()
        }
    }

    private func handleDaemonMessage(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        connectionStatus = "Connected"
        if pendingOpenAIOAuth, object["method"] == nil {
            pendingOpenAIOAuth = false
            sendBeginOpenAIOAuth()
        }
        if object["method"] as? String == "event",
           let params = object["params"],
           let eventData = try? JSONSerialization.data(withJSONObject: params),
           let event = try? JSONDecoder().decode(SessionEvent.self, from: eventData) {
            apply(event: event)
            return
        }
        if object["method"] as? String == "debugLog",
           let params = object["params"],
           let entryData = try? JSONSerialization.data(withJSONObject: params),
           let entry = try? JSONDecoder().decode(DebugLogItem.self, from: entryData) {
            apply(debugLog: entry)
            return
        }

        if object["ok"] as? Bool == false {
            if let error = object["error"] as? [String: Any],
               let message = error["message"] as? String {
                lastError = message
            }
            isCreatingSession = false
            isLoadingSelection = false
            return
        }
        guard object["ok"] as? Bool == true, let result = object["result"] else { return }
        if let resultData = try? JSONSerialization.data(withJSONObject: result),
           let snapshot = try? JSONDecoder().decode(SessionSnapshot.self, from: resultData) {
            apply(snapshot: snapshot)
            return
        }

        if let resultDict = result as? [String: Any],
           let authURL = resultDict["authorizationUrl"] as? String,
           let url = URL(string: authURL) {
            NSWorkspace.shared.open(url)
            decodeIntegrations(from: resultDict)
            return
        }

        if let resultDict = result as? [String: Any],
           let clientId = resultDict["clientId"] as? String,
           let authData = try? JSONSerialization.data(withJSONObject: resultDict),
           let decoded = try? JSONDecoder().decode(AuthStatus.self, from: authData) {
            authStatus = decoded
            if clientId.isEmpty { authStatus = nil }
            return
        }

        if let resultDict = result as? [String: Any],
           let sessionsValue = resultDict["sessions"],
           let sessionsData = try? JSONSerialization.data(withJSONObject: sessionsValue),
           let summaries = try? JSONDecoder().decode([SessionSummary].self, from: sessionsData) {
            sessions = summaries.filter { $0.archived != true }
            archivedSessions = summaries.filter { $0.archived == true }
            if !isComposingNewSession,
               let first = sessions.first,
               selectedSessionId == nil || (sessions + archivedSessions).allSatisfy({ $0.id != selectedSessionId }) {
                selectSession(first.id)
            }
            if let workflowsValue = resultDict["workflows"],
               let workflowsData = try? JSONSerialization.data(withJSONObject: workflowsValue),
               let decodedWorkflows = try? JSONDecoder().decode([WorkflowSpec].self, from: workflowsData) {
                workflows = decodedWorkflows
            }
            if let rolesValue = resultDict["roles"],
               let rolesData = try? JSONSerialization.data(withJSONObject: rolesValue),
               let decodedRoles = try? JSONDecoder().decode([RoleSpec].self, from: rolesData) {
                roles = decodedRoles
            }
            if let authValue = resultDict["codexOAuth"],
               let authData = try? JSONSerialization.data(withJSONObject: authValue),
               let decodedAuth = try? JSONDecoder().decode(AuthStatus.self, from: authData) {
                authStatus = decodedAuth
            }
            decodeCatalogPaths(from: resultDict)
            decodeIntegrations(from: resultDict)
            return
        }

        if let resultDict = result as? [String: Any],
           let rolesValue = resultDict["roles"],
           let rolesData = try? JSONSerialization.data(withJSONObject: rolesValue),
           let decodedRoles = try? JSONDecoder().decode([RoleSpec].self, from: rolesData) {
            roles = decodedRoles
            decodeCatalogPaths(from: resultDict)
            if let path = resultDict["path"] as? String {
                copyPath(path, fallback: "")
                lastError = "Created role JSON and copied its path: \(path)"
            }
            decodeIntegrations(from: resultDict)
            return
        }

        if let resultDict = result as? [String: Any],
           let integrationsValue = resultDict["integrations"],
           let integrationsData = try? JSONSerialization.data(withJSONObject: integrationsValue),
           let decodedIntegrations = try? JSONDecoder().decode(IntegrationCatalog.self, from: integrationsData) {
            integrations = decodedIntegrations
            return
        }

        if let resultDict = result as? [String: Any],
           resultDict["mcpServers"] != nil,
           resultDict["skills"] != nil,
           let integrationsData = try? JSONSerialization.data(withJSONObject: resultDict),
           let decodedIntegrations = try? JSONDecoder().decode(IntegrationCatalog.self, from: integrationsData) {
            integrations = decodedIntegrations
            return
        }

        if let resultDict = result as? [String: Any],
           let workflowsValue = resultDict["workflows"],
           let workflowsData = try? JSONSerialization.data(withJSONObject: workflowsValue),
           let decodedWorkflows = try? JSONDecoder().decode([WorkflowSpec].self, from: workflowsData) {
            workflows = decodedWorkflows
            decodeCatalogPaths(from: resultDict)
            if let path = resultDict["path"] as? String {
                copyPath(path, fallback: "")
                lastError = "Created workflow JSON and copied its path: \(path)"
            }
            if let rolesValue = resultDict["roles"],
               let rolesData = try? JSONSerialization.data(withJSONObject: rolesValue),
               let decodedRoles = try? JSONDecoder().decode([RoleSpec].self, from: rolesData) {
                roles = decodedRoles
            }
            if let authValue = resultDict["codexOAuth"],
               let authData = try? JSONSerialization.data(withJSONObject: authValue),
               let decodedAuth = try? JSONDecoder().decode(AuthStatus.self, from: authData) {
                authStatus = decodedAuth
            }
            decodeIntegrations(from: resultDict)
        }

        if let resultDict = result as? [String: Any],
           let logsValue = resultDict["logs"],
           let logsData = try? JSONSerialization.data(withJSONObject: logsValue),
           let decodedLogs = try? JSONDecoder().decode([DebugLogItem].self, from: logsData) {
            debugLogs = decodedLogs
            return
        }

    }

    private func apply(snapshot: SessionSnapshot) {
        selectedSessionId = snapshot.sessionId
        selectedSidebarItem = snapshot.sessionId
        selectedSidebarItems = [snapshot.sessionId]
        subscribe(to: snapshot.sessionId)
        graph = snapshot.graph
        transcript = snapshot.transcript.map(transcriptItem)
        subscribeDebugLogs(to: snapshot.sessionId)
        if let selectedAgentId, graph.nodes.allSatisfy({ $0.id != selectedAgentId }) {
            self.selectedAgentId = nil
        }
        if let controlAgentId, graph.nodes.allSatisfy({ $0.id != controlAgentId }) {
            self.controlAgentId = nil
        }
        currentWorkspaceRoot = snapshot.workspaceRoot
        currentSessionDebugMode = snapshot.debugMode ?? false
        let summary = SessionSummary(id: snapshot.sessionId, title: snapshot.title, detail: snapshot.workflowId, createdAt: snapshot.createdAt, updatedAt: snapshot.updatedAt, workspaceRoot: snapshot.workspaceRoot, archived: snapshot.archived, debugMode: snapshot.debugMode, model: snapshot.model, reasoningEffort: snapshot.reasoningEffort)
        upsertSessionSummary(summary)
        connectionStatus = "Connected"
        isCreatingSession = false
        isLoadingSelection = false
        isComposingNewSession = false
        composerText = ""
    }

    private func apply(event: SessionEvent) {
        guard event.sessionId == selectedSessionId else {
            if event.type == "session.created" {
                let title = event.payload["title"]?.stringValue ?? event.sessionId
                let workflowId = event.payload["workflowId"]?.stringValue ?? ""
                let workspaceRoot = event.payload["workspaceRoot"]?.stringValue
                upsertSessionSummary(SessionSummary(id: event.sessionId, title: title, detail: workflowId, createdAt: event.timestamp, updatedAt: event.timestamp, workspaceRoot: workspaceRoot, debugMode: event.payload["debugMode"]?.boolValue, model: event.payload["model"]?.stringValue, reasoningEffort: event.payload["reasoningEffort"]?.stringValue))
                if isCreatingSession {
                    selectedSessionId = event.sessionId
                    selectedSidebarItem = event.sessionId
                    selectedSidebarItems = [event.sessionId]
                    currentWorkspaceRoot = workspaceRoot
                    currentSessionDebugMode = event.payload["debugMode"]?.boolValue
                    transcript = []
                    debugLogs = []
                    selectedAgentId = nil
                    controlAgentId = nil
                    if let graphValue = event.payload["graph"],
                       let data = try? JSONEncoder().encode(graphValue),
                       let decoded = try? JSONDecoder().decode(GraphState.self, from: data) {
                        graph = decoded
                    }
                    subscribe(to: event.sessionId)
                    subscribeDebugLogs(to: event.sessionId)
                    isCreatingSession = false
                    isComposingNewSession = false
                    composerText = ""
                }
            }
            return
        }
        transcript.append(transcriptItem(event))
        switch event.type {
        case "session.created":
            if let graphValue = event.payload["graph"],
               let data = try? JSONEncoder().encode(graphValue),
               let decoded = try? JSONDecoder().decode(GraphState.self, from: data) {
                graph = decoded
            }
            let title = event.payload["title"]?.stringValue ?? event.sessionId
            let workflowId = event.payload["workflowId"]?.stringValue ?? graph.workflowId
            currentWorkspaceRoot = event.payload["workspaceRoot"]?.stringValue
            currentSessionDebugMode = event.payload["debugMode"]?.boolValue
            upsertSessionSummary(SessionSummary(id: event.sessionId, title: title, detail: workflowId, createdAt: event.timestamp, updatedAt: event.timestamp, workspaceRoot: currentWorkspaceRoot, debugMode: event.payload["debugMode"]?.boolValue, model: event.payload["model"]?.stringValue, reasoningEffort: event.payload["reasoningEffort"]?.stringValue))
            selectedSessionId = event.sessionId
            selectedSidebarItem = event.sessionId
            selectedSidebarItems = [event.sessionId]
            subscribe(to: event.sessionId)
            subscribeDebugLogs(to: event.sessionId)
            selectedAgentId = nil
            controlAgentId = nil
            isCreatingSession = false
            isLoadingSelection = false
            isComposingNewSession = false
            composerText = ""
        case "session.archived":
            updateSessionArchiveState(sessionId: event.sessionId, archived: true)
        case "session.restored":
            updateSessionArchiveState(sessionId: event.sessionId, archived: false)
        case "graph.updated":
            if let graphValue = event.payload["graph"],
               let data = try? JSONEncoder().encode(graphValue),
               let decoded = try? JSONDecoder().decode(GraphState.self, from: data) {
                graph = decoded
                if let controlAgentId, graph.nodes.allSatisfy({ $0.id != controlAgentId }) {
                    self.controlAgentId = nil
                }
            }
        case "agent.status":
            guard let agentId = event.agentId,
                  let statusText = event.payload["status"]?.stringValue,
                  let status = AgentStatus(rawValue: statusText),
                  let index = graph.nodes.firstIndex(where: { $0.id == agentId }) else { return }
            graph.nodes[index].status = status
        case "handoff.created", "message.sent":
            guard let from = event.payload["from"]?.stringValue,
                  let to = event.payload["to"]?.stringValue else { return }
            for index in graph.edges.indices where graph.edges[index].from == from && graph.edges[index].to == to {
                graph.edges[index].active = true
            }
        case "agent.message":
            if let agentId = event.agentId,
               let index = graph.nodes.firstIndex(where: { $0.id == agentId }) {
                if selectedAgentId != agentId {
                    graph.nodes[index].unreadCount += 1
                }
            }
        case "error":
            if let agentId = event.agentId,
               let index = graph.nodes.firstIndex(where: { $0.id == agentId }) {
                graph.nodes[index].errorCount += 1
            }
        default:
            break
        }
    }

    private func transcriptItem(_ event: SessionEvent) -> TranscriptItem {
        let sender = event.payload["from"]?.stringValue ?? event.agentId ?? "system"
        let recipient = event.payload["to"]?.stringValue
        return TranscriptItem(
            id: event.eventId,
            agentId: event.agentId,
            sender: sender,
            recipient: recipient,
            type: event.type,
            text: displayText(for: event),
            timestamp: parseTimestamp(event.timestamp),
            payload: event.payload,
            causationId: event.causationId,
            correlationId: event.correlationId
        )
    }

    private func decodeIntegrations(from resultDict: [String: Any]) {
        guard let integrationsValue = resultDict["integrations"],
              let integrationsData = try? JSONSerialization.data(withJSONObject: integrationsValue),
              let decodedIntegrations = try? JSONDecoder().decode(IntegrationCatalog.self, from: integrationsData) else { return }
        integrations = decodedIntegrations
    }

    private func decodeCatalogPaths(from resultDict: [String: Any]) {
        if let path = resultDict["personalRolesPath"] as? String {
            personalRolesPath = path
        }
        if let path = resultDict["personalWorkflowsPath"] as? String {
            personalWorkflowsPath = path
        }
    }

    private func copyPath(_ path: String?, fallback: String) {
        guard let path, !path.isEmpty else {
            if !fallback.isEmpty {
                lastError = fallback
            }
            return
        }
        copyText(path)
    }

    private func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func apply(debugLog entry: DebugLogItem) {
        guard entry.sessionId == selectedSessionId else { return }
        if !debugLogs.contains(where: { $0.logId == entry.logId }) {
            debugLogs.append(entry)
        }
    }

    private func subscribe(to sessionId: String) {
        guard !subscribedSessionIds.contains(sessionId) else { return }
        subscribedSessionIds.insert(sessionId)
        daemon.sendRequest(method: "subscribeEvents", params: ["sessionId": sessionId])
    }

    private func subscribeDebugLogs(to sessionId: String) {
        guard !subscribedDebugLogSessionIds.contains(sessionId) else { return }
        subscribedDebugLogSessionIds.insert(sessionId)
        daemon.sendRequest(method: "subscribeDebugLogs", params: ["sessionId": sessionId])
    }

    private func resetPreview() {
        selectedAgentId = nil
        controlAgentId = nil
        currentWorkspaceRoot = nil
        currentSessionDebugMode = nil
        isLoadingSelection = false
        graph = GraphState(sessionId: "", workflowId: "", nodes: [], edges: [])
        transcript = [
            TranscriptItem(
                id: UUID().uuidString,
                agentId: "orchestrator",
                sender: "orchestrator",
                recipient: nil,
                type: "message",
                text: "Create a new session to connect to the daemon and launch a workflow.",
                timestamp: Date(),
                payload: [:],
                causationId: nil,
                correlationId: nil
            )
        ]
        debugLogs = []
    }

    private func upsertSessionSummary(_ summary: SessionSummary) {
        sessions.removeAll { $0.id == summary.id }
        archivedSessions.removeAll { $0.id == summary.id }
        if summary.archived == true {
            archivedSessions.append(summary)
        } else {
            sessions.append(summary)
        }
        sessions.sort { left, right in
            (left.createdAt ?? "") > (right.createdAt ?? "")
        }
        archivedSessions.sort { left, right in
            (left.createdAt ?? "") > (right.createdAt ?? "")
        }
    }

    private func updateSessionArchiveState(sessionId: String, archived: Bool) {
        let allSessions = sessions + archivedSessions
        guard var summary = allSessions.first(where: { $0.id == sessionId }) else { return }
        summary.archived = archived
        upsertSessionSummary(summary)
        if archived, selectedSessionId == sessionId {
            selectedSidebarItem = sessionId
            selectedSidebarItems = [sessionId]
        }
    }

    private func selectedWorkflowId(for prompt: String) -> String {
        return "planner-orchestrator"
    }

    private func parseTimestamp(_ timestamp: String) -> Date {
        ISO8601DateFormatter().date(from: timestamp) ?? Date()
    }

    private func displayText(for event: SessionEvent) -> String {
        if let text = event.payload["text"]?.stringValue { return text }
        if let message = event.payload["message"]?.stringValue { return message }
        if let summary = event.payload["summary"]?.stringValue { return summary }
        if let output = event.payload["output"]?.stringValue { return output }
        if let reason = event.payload["reason"]?.stringValue { return reason }
        switch event.type {
        case "plan.created":
            if let plan = event.payload["plan"]?.objectValue {
                return "Plan created: \(plan["name"]?.stringValue ?? "Untitled plan")"
            }
            return "Plan created"
        case "plan.instantiated":
            return "Plan instantiated: \(event.payload["planId"]?.stringValue ?? "unknown")"
        case "agent.tool_call":
            return "Tool call: \(event.payload["toolName"]?.stringValue ?? "unknown")"
        case "agent.tool_result":
            return "Tool result: \(event.payload["toolName"]?.stringValue ?? "unknown")"
        case "workspace.file_claimed", "workspace.file_touched", "workspace.conflict_detected":
            return event.payload["path"]?.stringValue ?? event.type
        case "agent.status":
            return "Status: \(event.payload["status"]?.stringValue ?? "unknown")"
        default:
            return event.type
        }
    }

    private static let builtInRoleIds: Set<String> = ["orchestrator", "planner", "implementor", "reviewer", "qa", "researcher"]
}

enum WorkspaceOpenTool {
    case vsCode
    case finder
    case iTerm
}

private func jsonObject<T: Encodable>(_ value: T) -> Any? {
    guard let data = try? JSONEncoder().encode(value) else { return nil }
    return try? JSONSerialization.jsonObject(with: data)
}

@discardableResult
private func openApplication(_ appName: String, path: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-a", appName, path]
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

@discardableResult
private func openBundleIdentifier(_ bundleIdentifier: String, path: String) -> Bool {
    runProcess("/usr/bin/open", ["-b", bundleIdentifier, path])
}

@discardableResult
private func openVSCode(path: String) -> Bool {
    if openBundleIdentifier("com.microsoft.VSCode", path: path) {
        return true
    }
    let candidates = [
        "/usr/local/bin/code",
        "/opt/homebrew/bin/code",
        "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
    ]
    for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
        if runProcess(candidate, ["-n", path]) {
            return true
        }
    }
    return openApplication("Visual Studio Code", path: path)
}

@discardableResult
private func runProcess(_ executable: String, _ arguments: [String]) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
