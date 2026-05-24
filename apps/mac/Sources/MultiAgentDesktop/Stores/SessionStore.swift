import Foundation
import AppKit
import Observation

@MainActor
@Observable
final class SessionStore {
    var sessions: [SessionSummary] = []
    var selectedSessionId: String?
    var selectedSidebarItem: String?
    var graph = GraphState(sessionId: "", workflowId: "", nodes: [], edges: [])
    var transcript: [TranscriptItem] = []
    var roles: [RoleSpec] = []
    var workflows: [WorkflowSpec] = []
    var authStatus: AuthStatus?
    var currentWorkspaceRoot: String?
    var presentNewSession = false
    var composerText = ""
    var connectionStatus = "Disconnected"
    var debugMode = false
    var isCreatingSession = false
    var lastError: String?
    var selectedAgentId: String?
    var isLoadingSelection = false
    private var subscribedSessionIds = Set<String>()
    private var pendingCreatePrompt: String?

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
        daemon.isConnected && hasActiveSession && ![.paused, .cancelled, .failed, .completed].contains(orchestratorStatus) && !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var orchestratorStatus: AgentStatus {
        graph.nodes.first { $0.id == selectedControlAgentId }?.status ?? .idle
    }

    var selectedControlAgentId: String {
        selectedAgentId ?? "orchestrator"
    }

    var filteredTranscript: [TranscriptItem] {
        guard let selectedAgentId else { return transcript }
        return transcript.filter { item in
            item.agentId == selectedAgentId || item.sender == selectedAgentId || item.recipient == selectedAgentId
        }
    }

    var transcriptFilterLabel: String {
        guard let selectedAgentId else { return "All Agents" }
        return graph.nodes.first { $0.id == selectedAgentId }?.label ?? selectedAgentId
    }

    var isTranscriptFiltered: Bool {
        selectedAgentId != nil
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
            }
        }
        daemon.onSendError = { [weak self] reason in
            Task { @MainActor in
                self?.lastError = reason
                self?.isCreatingSession = false
                self?.pendingCreatePrompt = nil
            }
        }
    }

    func connectAndRefresh() {
        daemon.connect(port: daemonPort)
        connectionStatus = daemon.isConnected ? "Connected" : "Connecting"
        lastError = nil
        daemon.sendRequest(method: "listSessions", params: [:])
        refreshCatalogs()
    }

    func refreshCatalogs() {
        daemon.sendRequest(method: "listRoles", params: [:])
        daemon.sendRequest(method: "listWorkflows", params: [:])
        daemon.sendRequest(method: "getAuthStatus", params: [:])
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
        selectSession(item)
    }

    func selectSession(_ sessionId: String?) {
        guard let sessionId else { return }
        selectedSessionId = sessionId
        selectedSidebarItem = sessionId
        guard sessionId != "local-preview" else {
            resetPreview()
            return
        }
        isLoadingSelection = true
        graph = GraphState(sessionId: sessionId, workflowId: "", nodes: [], edges: [])
        transcript = []
        daemon.sendRequest(method: "getSnapshot", params: ["sessionId": sessionId])
        subscribe(to: sessionId)
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

    func sendComposerMessage() {
        let trimmed = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let selectedSessionId, daemon.isConnected else { return }
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

    func addRole() {
        let role = RoleSpec(
            id: "custom_role_\(Int(Date().timeIntervalSince1970))",
            name: "New Role",
            color: "#7f8c8d",
            promptTemplate: "Describe this role's responsibilities.",
            model: "gpt-5.4",
            toolPolicy: ToolPolicy(canRead: true, canWrite: false, canRunCommands: false),
            workspace: RoleWorkspace(allowedRoots: ["."]),
            expectedOutputs: [],
            reviewResponsibilities: []
        )
        roles.append(role)
        saveRole(role)
    }

    func instantiateWorkflow(_ workflowId: String) {
        guard let selectedSessionId, selectedSessionId != "local-preview" else {
            lastError = "Select a real session before instantiating a workflow."
            return
        }
        daemon.sendRequest(method: "instantiateWorkflow", params: ["sessionId": selectedSessionId, "workflowId": workflowId])
    }

    func beginOpenAIOAuth() {
        daemon.sendRequest(method: "beginOpenAIOAuth", params: [:])
    }

    func refreshAuthStatus() {
        daemon.sendRequest(method: "getAuthStatus", params: [:])
    }

    func disconnectOpenAIOAuth() {
        daemon.sendRequest(method: "disconnectOpenAIOAuth", params: [:])
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
            openApplication("Visual Studio Code", path: currentWorkspaceRoot)
        case .iTerm:
            openApplication("iTerm", path: currentWorkspaceRoot)
        }
    }

    private func handleDaemonMessage(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        connectionStatus = "Connected"
        if let prompt = pendingCreatePrompt, object["method"] == nil {
            pendingCreatePrompt = nil
            sendCreateSession(prompt: prompt)
        }
        if object["method"] as? String == "event",
           let params = object["params"],
           let eventData = try? JSONSerialization.data(withJSONObject: params),
           let event = try? JSONDecoder().decode(SessionEvent.self, from: eventData) {
            apply(event: event)
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
            return
        }

        if let resultDict = result as? [String: Any],
           let workflowsValue = resultDict["workflows"],
           let workflowsData = try? JSONSerialization.data(withJSONObject: workflowsValue),
           let decodedWorkflows = try? JSONDecoder().decode([WorkflowSpec].self, from: workflowsData) {
            workflows = decodedWorkflows
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
        }

        if let resultDict = result as? [String: Any],
           let sessionsValue = resultDict["sessions"],
           let sessionsData = try? JSONSerialization.data(withJSONObject: sessionsValue),
            let summaries = try? JSONDecoder().decode([SessionSummary].self, from: sessionsData) {
            sessions = summaries
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
        if let selectedAgentId, graph.nodes.allSatisfy({ $0.id != selectedAgentId }) {
            self.selectedAgentId = nil
        }
        currentWorkspaceRoot = snapshot.workspaceRoot
        let summary = SessionSummary(id: snapshot.sessionId, title: snapshot.title, detail: snapshot.workflowId, createdAt: snapshot.createdAt, workspaceRoot: snapshot.workspaceRoot)
        upsertSessionSummary(summary)
        connectionStatus = "Connected"
        isCreatingSession = false
        isLoadingSelection = false
        presentNewSession = false
    }

    private func apply(event: SessionEvent) {
        guard event.sessionId == selectedSessionId else {
            if event.type == "session.created" {
                let title = event.payload["title"]?.stringValue ?? event.sessionId
                let workflowId = event.payload["workflowId"]?.stringValue ?? ""
                let workspaceRoot = event.payload["workspaceRoot"]?.stringValue
                upsertSessionSummary(SessionSummary(id: event.sessionId, title: title, detail: workflowId, createdAt: event.timestamp, workspaceRoot: workspaceRoot))
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
            upsertSessionSummary(SessionSummary(id: event.sessionId, title: title, detail: workflowId, createdAt: event.timestamp, workspaceRoot: currentWorkspaceRoot))
            selectedSessionId = event.sessionId
            selectedSidebarItem = event.sessionId
            subscribe(to: event.sessionId)
            selectedAgentId = nil
            isCreatingSession = false
            isLoadingSelection = false
            presentNewSession = false
        case "graph.updated":
            if let graphValue = event.payload["graph"],
               let data = try? JSONEncoder().encode(graphValue),
               let decoded = try? JSONDecoder().decode(GraphState.self, from: data) {
                graph = decoded
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
        return TranscriptItem(id: event.eventId, agentId: event.agentId, sender: sender, recipient: recipient, type: event.type, text: displayText(for: event), timestamp: parseTimestamp(event.timestamp))
    }

    private func subscribe(to sessionId: String) {
        guard !subscribedSessionIds.contains(sessionId) else { return }
        subscribedSessionIds.insert(sessionId)
        daemon.sendRequest(method: "subscribeEvents", params: ["sessionId": sessionId])
    }

    private func resetPreview() {
        selectedAgentId = nil
        currentWorkspaceRoot = nil
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
            TranscriptItem(id: UUID().uuidString, agentId: "orchestrator", sender: "orchestrator", recipient: nil, type: "message", text: "Create a new session to connect to the daemon and launch a workflow.", timestamp: Date())
        ]
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
        guard debugMode else { return "planner-orchestrator" }
        let lower = prompt.lowercased()
        if lower.contains("qa") || lower.contains("test") || lower.contains("acceptance") || lower.contains("check") {
            return "implementor-qa-loop"
        }
        return "implementor-reviewer"
    }

    private func parseTimestamp(_ timestamp: String) -> Date {
        ISO8601DateFormatter().date(from: timestamp) ?? Date()
    }

    private func displayText(for event: SessionEvent) -> String {
        if let text = event.payload["text"]?.stringValue { return text }
        if let summary = event.payload["summary"]?.stringValue { return summary }
        if let output = event.payload["output"]?.stringValue { return output }
        if let reason = event.payload["reason"]?.stringValue { return reason }
        switch event.type {
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

private func openApplication(_ appName: String, path: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-a", appName, path]
    try? process.run()
}
