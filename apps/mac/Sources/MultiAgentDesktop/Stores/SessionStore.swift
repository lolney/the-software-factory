import Foundation
import AppKit
import Observation

@MainActor
@Observable
final class SessionStore {
    static let newSessionDraftId = "new-session-draft"

    var sessions: [SessionSummary] = []
    var selectedSessionId: String?
    var selectedSidebarItem: String?
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
    var connectionStatus = "Disconnected"
    var debugMode = false
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
        selectedSessionId != nil && selectedSessionId != "local-preview"
    }

    var canSendComposerMessage: Bool {
        let hasText = !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isComposingNewSession {
            return hasText && !isCreatingSession
        }
        return daemon.isConnected && hasActiveSession && ![.paused, .cancelled, .failed, .completed].contains(orchestratorStatus) && hasText
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
        daemon.isConnected && hasActiveSession && [.idle, .working, .waiting].contains(orchestratorStatus)
    }

    var canResumeOrchestrator: Bool {
        daemon.isConnected && hasActiveSession && orchestratorStatus == .paused
    }

    var canCancelOrchestrator: Bool {
        daemon.isConnected && hasActiveSession && ![.cancelled, .completed].contains(orchestratorStatus)
    }

    init() {
        sessions = [
            SessionSummary(id: "local-preview", title: "Local Preview", detail: "Daemon not connected")
        ]
        selectedSessionId = sessions.first?.id
        selectedSidebarItem = sessions.first?.id
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
        daemon.disconnect()
        localDaemonLauncher.stop()
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
        daemon.sendRequest(method: "listSessions", params: [:])
        refreshCatalogs()
    }

    func refreshCatalogs() {
        daemon.sendRequest(method: "listRoles", params: [:])
        daemon.sendRequest(method: "listWorkflows", params: [:])
        daemon.sendRequest(method: "getAuthStatus", params: [:])
        daemon.sendRequest(method: "listIntegrations", params: [:])
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
                selectedSessionId = "local-preview"
                selectedSidebarItem = "local-preview"
                resetPreview()
            }
        }
    }

    private func sendCreateSession(prompt: String) {
        isCreatingSession = true
        lastError = nil
        let workflowId = selectedWorkflowId(for: prompt)
        daemon.sendRequest(method: "createSession", params: [
            "prompt": prompt,
            "workflowId": workflowId,
            "debugMode": debugMode
        ])
    }

    func selectSidebarItem(_ item: String?) {
        selectedSidebarItem = item
        guard let item else { return }
        if item == "roles" || item == "workflows" {
            return
        }
        if item == Self.newSessionDraftId {
            beginNewSession()
            return
        }
        selectSession(item)
    }

    func selectSession(_ sessionId: String?) {
        guard let sessionId else { return }
        isComposingNewSession = false
        selectedSessionId = sessionId
        selectedSidebarItem = sessionId
        guard sessionId != "local-preview" else {
            resetPreview()
            return
        }
        isLoadingSelection = true
        currentWorkspaceRoot = sessions.first { $0.id == sessionId }?.workspaceRoot
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
            composerText = ""
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

    func instantiateWorkflow(_ workflowId: String) {
        guard let selectedSessionId, selectedSessionId != "local-preview" else {
            lastError = "Select a real session before instantiating a workflow."
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
        selectedSessionId = nil
        selectedSidebarItem = Self.newSessionDraftId
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
                payload: [:]
            )
        ]
        debugLogs = []
    }

    private func handleDaemonMessage(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        connectionStatus = "Connected"
        if let prompt = pendingCreatePrompt, object["method"] == nil {
            pendingCreatePrompt = nil
            sendCreateSession(prompt: prompt)
        }
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

        if let resultDict = result as? [String: Any],
           let sessionsValue = resultDict["sessions"],
           let sessionsData = try? JSONSerialization.data(withJSONObject: sessionsValue),
            let summaries = try? JSONDecoder().decode([SessionSummary].self, from: sessionsData) {
            sessions = summaries
            if isComposingNewSession {
                return
            }
            if let first = sessions.first, selectedSessionId == nil || sessions.allSatisfy({ $0.id != selectedSessionId }) {
                selectSession(first.id)
            }
        }
    }

    private func apply(snapshot: SessionSnapshot) {
        selectedSessionId = snapshot.sessionId
        selectedSidebarItem = snapshot.sessionId
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
        let summary = SessionSummary(id: snapshot.sessionId, title: snapshot.title, detail: snapshot.workflowId, createdAt: snapshot.createdAt, workspaceRoot: snapshot.workspaceRoot)
        upsertSessionSummary(summary)
        connectionStatus = "Connected"
        isCreatingSession = false
        isLoadingSelection = false
        isComposingNewSession = false
    }

    private func apply(event: SessionEvent) {
        guard event.sessionId == selectedSessionId else {
            if event.type == "session.created" {
                let title = event.payload["title"]?.stringValue ?? event.sessionId
                let workflowId = event.payload["workflowId"]?.stringValue ?? ""
                let workspaceRoot = event.payload["workspaceRoot"]?.stringValue
                upsertSessionSummary(SessionSummary(id: event.sessionId, title: title, detail: workflowId, createdAt: event.timestamp, workspaceRoot: workspaceRoot))
                if isCreatingSession {
                    selectedSessionId = event.sessionId
                    selectedSidebarItem = event.sessionId
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
            upsertSessionSummary(SessionSummary(id: event.sessionId, title: title, detail: workflowId, createdAt: event.timestamp, workspaceRoot: currentWorkspaceRoot))
            selectedSessionId = event.sessionId
            selectedSidebarItem = event.sessionId
            subscribe(to: event.sessionId)
            subscribeDebugLogs(to: event.sessionId)
            selectedAgentId = nil
            controlAgentId = nil
            isCreatingSession = false
            isLoadingSelection = false
            isComposingNewSession = false
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
        return TranscriptItem(id: event.eventId, agentId: event.agentId, sender: sender, recipient: recipient, type: event.type, text: displayText(for: event), timestamp: parseTimestamp(event.timestamp), payload: event.payload)
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
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
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
        graph = GraphState(
            sessionId: "local-preview",
            workflowId: "implementor-reviewer",
            nodes: [
                AgentNode(id: "orchestrator", roleId: "orchestrator", label: "Orchestrator", status: .idle, colorHex: "#4f7cff", unreadCount: 0, errorCount: 0),
                AgentNode(id: "implementor", roleId: "implementor", label: "Implementor", status: .waiting, colorHex: "#27ae60", unreadCount: 0, errorCount: 0),
                AgentNode(id: "reviewer", roleId: "reviewer", label: "Reviewer", status: .waiting, colorHex: "#f2994a", unreadCount: 1, errorCount: 0)
            ],
            edges: [
                AgentEdge(id: "handoff-orchestrator-implementor", from: "orchestrator", to: "implementor", kind: .handoff, active: false),
                AgentEdge(id: "message-reviewer-implementor", from: "reviewer", to: "implementor", kind: .message, active: true)
            ]
        )
        transcript = [
            TranscriptItem(id: UUID().uuidString, agentId: "orchestrator", sender: "orchestrator", recipient: nil, type: "message", text: "Create a new session to connect to the daemon and launch a workflow.", timestamp: Date(), payload: [:])
        ]
        debugLogs = []
    }

    private func upsertSessionSummary(_ summary: SessionSummary) {
        if let index = sessions.firstIndex(where: { $0.id == summary.id }) {
            sessions[index] = summary
        } else {
            sessions.append(summary)
        }
        sessions.sort { left, right in
            (left.createdAt ?? "") > (right.createdAt ?? "")
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
