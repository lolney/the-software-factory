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
    var usesStaticMockupFixture = false
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
        let directMatches = visibleTranscript.filter { item in
            item.searchText.localizedCaseInsensitiveContains(query)
        }
        let matchedToolCallIds = Set(directMatches.compactMap { item in
            ["agent.tool_call", "agent.tool_result"].contains(item.type) ? item.payload["callId"]?.stringValue : nil
        })
        guard !matchedToolCallIds.isEmpty else { return directMatches }
        let directMatchIds = Set(directMatches.map(\.id))
        return visibleTranscript.filter { item in
            directMatchIds.contains(item.id)
                || (["agent.tool_call", "agent.tool_result"].contains(item.type)
                    && item.payload["callId"]?.stringValue.map { matchedToolCallIds.contains($0) } == true)
        }
    }

    var sessionErrorCount: Int {
        graph.nodes.reduce(0) { total, node in total + node.errorCount }
    }

    var statusBannerText: String? {
        if let lastError, !lastError.isEmpty {
            return sanitizedDisplayError(lastError)
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

    var recoveredSchedulerJobs: [RecoveredSchedulerJob] {
        var createdByJobId: [String: TranscriptItem] = [:]
        var retryRequests: [String: TranscriptItem] = [:]
        for item in transcript {
            guard let jobId = item.payload["jobId"]?.stringValue else { continue }
            if item.type == "scheduler.job.created" {
                createdByJobId[jobId] = item
            }
            if item.type == "scheduler.job.retry_requested" {
                retryRequests[jobId] = item
            }
        }
        return transcript.compactMap { item -> RecoveredSchedulerJob? in
            guard item.type == "scheduler.job.recovered",
                  let jobId = item.payload["jobId"]?.stringValue,
                  let created = createdByJobId[jobId] else { return nil }
            return RecoveredSchedulerJob(
                jobId: jobId,
                agentId: created.agentId ?? created.payload["agentId"]?.stringValue ?? item.agentId ?? "agent",
                kind: created.payload["kind"]?.stringValue ?? "job",
                prompt: created.payload["prompt"]?.stringValue ?? "",
                recoveredAt: item.timestamp,
                reason: item.payload["reason"]?.stringValue ?? "Recovered after daemon restart.",
                retried: retryRequests[jobId] != nil,
                retryReason: retryRequests[jobId]?.payload["reason"]?.stringValue
            )
        }
        .sorted { $0.recoveredAt > $1.recoveredAt }
    }

    var schedulerRuns: [SchedulerRunSummary] {
        var runs: [String: SchedulerRunSummary] = [:]
        for item in transcript {
            guard item.type.hasPrefix("scheduler.job."),
                  let jobId = item.payload["jobId"]?.stringValue else { continue }
            var run = runs[jobId] ?? SchedulerRunSummary(
                jobId: jobId,
                agentId: item.agentId ?? item.payload["agentId"]?.stringValue ?? "agent",
                kind: item.payload["kind"]?.stringValue ?? "job",
                status: "created",
                prompt: item.payload["prompt"]?.stringValue ?? "",
                createdAt: nil,
                startedAt: nil,
                finishedAt: nil,
                updatedAt: nil,
                workflowId: nil,
                workflowInstanceId: nil,
                message: nil,
                eventCount: nil
            )
            run.agentId = item.agentId ?? item.payload["agentId"]?.stringValue ?? run.agentId
            run.kind = item.payload["kind"]?.stringValue ?? run.kind
            run.workflowId = item.payload["workflowId"]?.stringValue ?? run.workflowId
            run.workflowInstanceId = item.payload["workflowInstanceId"]?.stringValue ?? run.workflowInstanceId
            if let prompt = item.payload["prompt"]?.stringValue, !prompt.isEmpty {
                run.prompt = prompt
            }
            switch item.type {
            case "scheduler.job.created":
                run.status = run.status == "created" ? "created" : run.status
                run.createdAt = run.createdAt ?? item.timestamp
            case "scheduler.job.started", "scheduler.job.heartbeat":
                if !["completed", "failed", "recovered", "retry requested"].contains(run.status) {
                    run.status = "running"
                }
                run.startedAt = run.startedAt ?? item.timestamp
            case "scheduler.job.completed":
                run.status = "completed"
                run.finishedAt = item.timestamp
            case "scheduler.job.failed":
                run.status = "failed"
                run.finishedAt = item.timestamp
            case "scheduler.job.recovered":
                run.status = "recovered"
                run.finishedAt = item.timestamp
            case "scheduler.job.retry_requested":
                run.status = "retry requested"
            default:
                break
            }
            run.message = item.payload["message"]?.stringValue ?? item.payload["reason"]?.stringValue ?? run.message
            run.eventCount = item.payload["eventCount"]?.numberValue.map(Int.init) ?? run.eventCount
            if run.updatedAt == nil || item.timestamp > (run.updatedAt ?? .distantPast) {
                run.updatedAt = item.timestamp
            }
            runs[jobId] = run
        }
        return runs.values.sorted { left, right in
            (left.updatedAt ?? .distantPast) > (right.updatedAt ?? .distantPast)
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

    static func bootstrap() -> SessionStore {
        let process = ProcessInfo.processInfo
        let usesFixture = process.arguments.contains("--software-factory-mockup-fixture")
            || process.environment["SOFTWARE_FACTORY_MOCKUP_FIXTURE"] == "1"
        return SessionStore(mockupFixture: usesFixture)
    }

    init(mockupFixture: Bool = false, referenceNow: Date = Date()) {
        usesStaticMockupFixture = mockupFixture
        sessions = []
        selectedSessionId = nil
        selectedSidebarItem = nil
        selectedAgentId = nil
        if mockupFixture {
            applyMockupFixture(referenceNow: referenceNow)
        } else {
            resetPreview()
        }
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
                self?.resetSubscriptions()
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
        guard !usesStaticMockupFixture else { return }
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
        guard !usesStaticMockupFixture else { return }
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
            lastError = "Could not start the local daemon. Check ~/Library/Application Support/The Software Factory/logs/app-daemon.log for details."
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
        if let selectedSessionId {
            subscribe(to: selectedSessionId)
            subscribeDebugLogs(to: selectedSessionId)
        }
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
        if usesStaticMockupFixture {
            selectStaticMockupSession(sessionId)
            return
        }
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

    func retryRecoveredJob(_ job: RecoveredSchedulerJob) {
        guard let selectedSessionId else { return }
        daemon.sendRequest(method: "retryRecoveredJob", params: ["sessionId": selectedSessionId, "jobId": job.jobId])
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

    func renameSession(_ sessionId: String, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionId.isEmpty, !trimmed.isEmpty else { return }
        daemon.sendRequest(method: "renameSession", params: ["sessionId": sessionId, "title": trimmed])
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
            .filter(workspaceDiffHasContent)
            .compactMap { $0.payload["diff"]?.stringValue }
        guard !diffs.isEmpty else {
            lastError = "No recorded diff for \(relativePath)."
            return
        }
        copyText(diffs.joined(separator: "\n\n"))
    }

    func copyTranscript() {
        guard !transcriptExportText.isEmpty else {
            lastError = "No transcript events have been recorded for this session."
            return
        }
        copyText(transcriptExportText)
    }

    func copySessionEventLog() {
        guard !eventLogExportText.isEmpty else {
            lastError = "No session events have been recorded for this session."
            return
        }
        copyText(eventLogExportText)
    }

    func copyDebugLog() {
        guard !debugLogExportText.isEmpty else {
            lastError = "No debug log entries have been recorded for this session."
            return
        }
        copyText(debugLogExportText)
    }

    func exportTranscript() {
        exportText(transcriptExportText, defaultFileName: exportFileName(suffix: "transcript", fileExtension: "txt"), emptyMessage: "No transcript events have been recorded for this session.")
    }

    func exportSessionEventLog() {
        exportText(eventLogExportText, defaultFileName: exportFileName(suffix: "events", fileExtension: "jsonl"), emptyMessage: "No session events have been recorded for this session.")
    }

    func exportDebugLog() {
        exportText(debugLogExportText, defaultFileName: exportFileName(suffix: "debug", fileExtension: "jsonl"), emptyMessage: "No debug log entries have been recorded for this session.")
    }

    var transcriptExportText: String {
        transcript.map(transcriptLine).joined(separator: "\n\n")
    }

    var hasTranscriptExport: Bool {
        !transcript.isEmpty
    }

    var eventLogExportText: String {
        transcript.map(eventLogLine).joined(separator: "\n")
    }

    var hasEventLogExport: Bool {
        !transcript.isEmpty
    }

    var debugLogExportText: String {
        debugLogs.map(debugLogLine).joined(separator: "\n")
    }

    var hasDebugLogExport: Bool {
        !debugLogs.isEmpty
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
                sessionId: nil,
                agentId: "orchestrator",
                sender: "orchestrator",
                recipient: nil,
                type: "message",
                text: "Write the initial prompt below. It will be sent as the first message to the orchestrator when the session is created.",
                timestamp: Date(),
                rawTimestamp: nil,
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
                lastError = sanitizedDisplayError(message)
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
        if let selectedSessionId,
           selectedSessionId != snapshot.sessionId,
           !isCreatingSession {
            return
        }
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
            } else if event.type == "session.renamed",
                      let title = event.payload["title"]?.stringValue {
                updateSessionTitle(sessionId: event.sessionId, title: title, updatedAt: event.timestamp)
            }
            return
        }
        guard !transcript.contains(where: { $0.id == event.eventId }) else { return }
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
        case "session.renamed":
            if let title = event.payload["title"]?.stringValue {
                updateSessionTitle(sessionId: event.sessionId, title: title, updatedAt: event.timestamp)
            }
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
        refreshSessionSummaryStatuses()
    }

    private func transcriptItem(_ event: SessionEvent) -> TranscriptItem {
        let sender = event.payload["from"]?.stringValue ?? event.agentId ?? "system"
        let recipient = event.payload["to"]?.stringValue
        return TranscriptItem(
            id: event.eventId,
            sessionId: event.sessionId,
            agentId: event.agentId,
            sender: sender,
            recipient: recipient,
            type: event.type,
            text: displayText(for: event),
            timestamp: parseTimestamp(event.timestamp),
            rawTimestamp: event.timestamp,
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
        lastError = nil
    }

    private func exportText(_ text: String, defaultFileName: String, emptyMessage: String) {
        guard !text.isEmpty else {
            lastError = emptyMessage
            return
        }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultFileName
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                Task { @MainActor in self?.lastError = nil }
            } catch {
                Task { @MainActor in
                    self?.lastError = "Could not export \(defaultFileName): \(error.localizedDescription)"
                }
            }
        }
    }

    private func exportFileName(suffix: String, fileExtension: String) -> String {
        "\(selectedSessionId ?? "session")-\(suffix).\(fileExtension)"
    }

    private func transcriptLine(_ item: TranscriptItem) -> String {
        [
            "[\(eventTimestamp(item))] \(item.sender)\(item.recipient.map { " -> \($0)" } ?? "") \(item.type)",
            item.text
        ].joined(separator: "\n")
    }

    private func eventLogLine(_ item: TranscriptItem) -> String {
        var fields: [String: JSONValue] = [
            "eventId": .string(item.id),
            "sessionId": .string(item.sessionId ?? selectedSessionId ?? ""),
            "timestamp": .string(eventTimestamp(item)),
            "type": .string(item.type),
            "payload": .object(item.payload)
        ]
        if let agentId = item.agentId { fields["agentId"] = .string(agentId) }
        if let causationId = item.causationId { fields["causationId"] = .string(causationId) }
        if let correlationId = item.correlationId { fields["correlationId"] = .string(correlationId) }
        return encodeJSONLine(.object(fields))
    }

    private func debugLogLine(_ item: DebugLogItem) -> String {
        var fields: [String: JSONValue] = [
            "logId": .string(item.logId),
            "sessionId": .string(item.sessionId),
            "timestamp": .string(item.timestamp),
            "level": .string(item.level.rawValue),
            "source": .string(item.source),
            "message": .string(item.message),
            "payload": .object(item.payload)
        ]
        if let agentId = item.agentId { fields["agentId"] = .string(agentId) }
        if let causationId = item.causationId { fields["causationId"] = .string(causationId) }
        if let correlationId = item.correlationId { fields["correlationId"] = .string(correlationId) }
        return encodeJSONLine(.object(fields))
    }

    private func encodeJSONLine(_ value: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let line = String(data: data, encoding: .utf8) else {
            return value.searchText
        }
        return line
    }

    private func formatDate(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func eventTimestamp(_ item: TranscriptItem) -> String {
        item.rawTimestamp ?? formatDate(item.timestamp)
    }

    private func applyMockupFixture(referenceNow now: Date) {
        let selectedId = "mockup-debug-temperature"
        func iso(_ offset: TimeInterval) -> String {
            ISO8601DateFormatter().string(from: now.addingTimeInterval(offset))
        }
        func transcriptItem(
            _ id: String,
            agentId: String?,
            sender: String? = nil,
            recipient: String? = nil,
            type: String,
            text: String,
            offset: TimeInterval,
            payload: [String: JSONValue] = [:]
        ) -> TranscriptItem {
            let timestamp = now.addingTimeInterval(offset)
            return TranscriptItem(
                id: id,
                sessionId: selectedId,
                agentId: agentId,
                sender: sender ?? agentId ?? "system",
                recipient: recipient,
                type: type,
                text: text,
                timestamp: timestamp,
                rawTimestamp: ISO8601DateFormatter().string(from: timestamp),
                payload: payload,
                causationId: nil,
                correlationId: nil
            )
        }

        sessions = [
            SessionSummary(id: selectedId, title: "Debug workflow: temperature converter", detail: "implementation-review-qa", createdAt: iso(-14 * 60), updatedAt: iso(-14 * 60), workspaceRoot: "/tmp/software-factory/mockup", debugMode: true, status: "completed", activeAgents: 0, failureCount: 0),
            SessionSummary(id: "mockup-refactor-auth", title: "Refactor auth module", detail: "implementation-review-qa", createdAt: iso(-2 * 60 * 60), updatedAt: iso(-2 * 60 * 60), workspaceRoot: "/tmp/software-factory/auth", status: "completed", activeAgents: 0, failureCount: 0),
            SessionSummary(id: "mockup-payment-flow", title: "Add payment flow", detail: "implementation-review-qa", createdAt: iso(-25 * 60 * 60), updatedAt: iso(-25 * 60 * 60), workspaceRoot: "/tmp/software-factory/payments", status: "completed", activeAgents: 0, failureCount: 0),
            SessionSummary(id: "mockup-data-pipeline", title: "Spike: data pipeline", detail: "implementation-review-qa", createdAt: iso(-2 * 24 * 60 * 60), updatedAt: iso(-2 * 24 * 60 * 60), workspaceRoot: "/tmp/software-factory/data", status: "completed", activeAgents: 0, failureCount: 0),
            SessionSummary(id: "mockup-api-error", title: "API error investigation", detail: "implementation-review-qa", createdAt: iso(-3 * 24 * 60 * 60), updatedAt: iso(-3 * 24 * 60 * 60), workspaceRoot: "/tmp/software-factory/api", status: "completed", activeAgents: 0, failureCount: 0)
        ]
        archivedSessions = []
        selectedSessionId = selectedId
        selectedSidebarItem = selectedId
        selectedSidebarItems = [selectedId]
        currentWorkspaceRoot = "/tmp/software-factory/mockup"
        currentSessionDebugMode = true
        connectionStatus = "Connected"
        inspectorPanel = .graph
        selectedAgentId = nil
        controlAgentId = nil
        transcriptSearchText = ""
        isComposingNewSession = false
        isCreatingSession = false
        lastError = nil

        graph = GraphState(
            sessionId: selectedId,
            workflowId: "implementation-review-qa",
            nodes: [
                AgentNode(id: "orchestrator", roleId: "orchestrator", label: "Orchestrator", status: .idle, colorHex: "#8e63bf", unreadCount: 3, errorCount: 0),
                AgentNode(id: "planner", roleId: "planner", label: "Planner", status: .idle, colorHex: "#5b8fdc", unreadCount: 1, errorCount: 0),
                AgentNode(id: "implementor", roleId: "implementor", label: "Implementor", status: .completed, colorHex: "#60bf71", unreadCount: 0, errorCount: 0),
                AgentNode(id: "reviewer", roleId: "reviewer", label: "Reviewer", status: .completed, colorHex: "#f19a3e", unreadCount: 1, errorCount: 0),
                AgentNode(id: "qa", roleId: "qa", label: "QA", status: .completed, colorHex: "#f45d4f", unreadCount: 2, errorCount: 0)
            ],
            edges: [
                AgentEdge(id: "orchestrator-planner", from: "orchestrator", to: "planner", kind: .handoff, active: false),
                AgentEdge(id: "planner-implementor", from: "planner", to: "implementor", kind: .handoff, active: false),
                AgentEdge(id: "implementor-reviewer", from: "implementor", to: "reviewer", kind: .message, active: false),
                AgentEdge(id: "implementor-qa", from: "implementor", to: "qa", kind: .message, active: false)
            ]
        )

        transcript = [
            transcriptItem("mockup-user-prompt", agentId: "user", sender: "user", recipient: "orchestrator", type: "agent.message", text: "Audit a small debug workflow and produce visible transcript events.", offset: -770),
            transcriptItem("mockup-orchestrator-goal", agentId: "orchestrator", type: "agent.message", text: "Debug orchestrator: Goal received. Planning and delegating to Implementor.", offset: -720),
            transcriptItem("mockup-planner-plan", agentId: "planner", type: "agent.message", text: "Debug planner: Selected the workflow graph, confirmed responsibilities, and handed the plan back to Orchestrator.", offset: -690),
            transcriptItem(
                "mockup-plan-created",
                agentId: "planner",
                type: "plan.created",
                text: "Build, review, and QA the requested CLI",
                offset: -650,
                payload: ["planId": .string("temperature-converter-plan")]
            ),
            transcriptItem(
                "mockup-implementation-file",
                agentId: "implementor",
                type: "workspace.file_touched",
                text: "temperature_converter.py",
                offset: -570,
                payload: [
                    "path": .string("temperature_converter.py"),
                    "diffStats": .object(["additions": .number(25), "deletions": .number(0)])
                ]
            ),
            transcriptItem(
                "mockup-test-file",
                agentId: "implementor",
                type: "workspace.file_touched",
                text: "test_temperature_converter.py",
                offset: -560,
                payload: [
                    "path": .string("test_temperature_converter.py"),
                    "diffStats": .object(["additions": .number(28), "deletions": .number(0)])
                ]
            ),
            transcriptItem("mockup-implementor-message", agentId: "implementor", type: "agent.message", text: "Implemented temperature_converter.py with celsius/fahrenheit conversion helpers, a CLI, and unittest coverage.", offset: -500),
            transcriptItem(
                "mockup-test-run",
                agentId: "qa",
                type: "agent.tool_result",
                text: "python3 -m unittest test_temperature_converter.py completed successfully.",
                offset: -430,
                payload: ["callId": .string("test-run"), "toolName": .string("test run"), "status": .string("done")]
            ),
            transcriptItem("mockup-qa-message", agentId: "qa", type: "agent.message", text: "QA acceptance passed: python3 -m unittest test_temperature_converter.py completed successfully.", offset: -310),
            transcriptItem("mockup-reviewer-message", agentId: "reviewer", type: "agent.message", text: "Debug reviewer: Reviewed implementation and sent one follow-up to Implementor.", offset: -260),
            transcriptItem("mockup-complete", agentId: "orchestrator", type: "workflow.completed", text: "All acceptance checks passed. Workflow complete.", offset: -2)
        ]
        debugLogs = []
    }

    private func selectStaticMockupSession(_ sessionId: String) {
        selectedSessionId = sessionId
        selectedSidebarItem = sessionId
        selectedSidebarItems = [sessionId]
        isComposingNewSession = false
        isCreatingSession = false
        isLoadingSelection = false
        lastError = nil
        guard let summary = (sessions + archivedSessions).first(where: { $0.id == sessionId }) else {
            return
        }
        currentWorkspaceRoot = summary.workspaceRoot
        currentSessionDebugMode = summary.debugMode
        if transcript.first?.sessionId != sessionId {
            resetStaticMockupSessionDetail(for: summary)
        }
    }

    private func resetStaticMockupSessionDetail(for summary: SessionSummary) {
        graph = GraphState(sessionId: summary.id, workflowId: summary.detail, nodes: [], edges: [])
        transcript = [
            TranscriptItem(
                id: "\(summary.id)-summary",
                sessionId: summary.id,
                agentId: "orchestrator",
                sender: "orchestrator",
                recipient: nil,
                type: "message",
                text: "Static mockup session summary. Detailed transcript data is only bundled for the selected fixture session.",
                timestamp: parseTimestamp(summary.updatedAt ?? summary.createdAt ?? ISO8601DateFormatter().string(from: Date())),
                rawTimestamp: summary.updatedAt ?? summary.createdAt,
                payload: [:],
                causationId: nil,
                correlationId: nil
            )
        ]
        debugLogs = []
        selectedAgentId = nil
        controlAgentId = nil
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

    private func resetSubscriptions() {
        subscribedSessionIds.removeAll()
        subscribedDebugLogSessionIds.removeAll()
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
                sessionId: nil,
                agentId: "orchestrator",
                sender: "orchestrator",
                recipient: nil,
                type: "message",
                text: "Create a new session to connect to the daemon and launch a workflow.",
                timestamp: Date(),
                rawTimestamp: nil,
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
        refreshSessionSummaryStatuses()
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

    private func updateSessionTitle(sessionId: String, title: String, updatedAt: String) {
        let allSessions = sessions + archivedSessions
        guard var summary = allSessions.first(where: { $0.id == sessionId }) else { return }
        summary.title = title
        summary.updatedAt = updatedAt
        upsertSessionSummary(summary)
    }

    private func refreshSessionSummaryStatuses() {
        guard let selectedSessionId,
              let selectedIndex = sessions.firstIndex(where: { $0.id == selectedSessionId }) else { return }
        let projection = deriveSessionSummaryStatus(graph: graph, transcript: transcript)
        sessions[selectedIndex].activeAgents = projection.activeAgents
        sessions[selectedIndex].failureCount = projection.failureCount
        sessions[selectedIndex].status = projection.status
    }

    private func selectedWorkflowId(for prompt: String) -> String {
        return "planner-orchestrator"
    }

    private func parseTimestamp(_ timestamp: String) -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: timestamp) {
            return date
        }
        return ISO8601DateFormatter().date(from: timestamp) ?? Date()
    }

    private func displayText(for event: SessionEvent) -> String {
        if event.type == "message.skipped" {
            let target = event.payload["to"]?.stringValue ?? "agent"
            let reason = event.payload["reason"]?.stringValue ?? "target unavailable"
            return "Message to \(target) skipped: \(reason)"
        }
        if event.type == "session.renamed" {
            return "Session renamed to \(event.payload["title"]?.stringValue ?? event.sessionId)"
        }
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

func sanitizedDisplayError(_ message: String) -> String {
    var redacted = message
    let patterns = [
        #"(?i)(access[_-]?token["']?\s*[:=]\s*["']?)[^"',\s}]+()"#,
        #"(?i)(refresh[_-]?token["']?\s*[:=]\s*["']?)[^"',\s}]+()"#,
        #"(?i)(api[_-]?key["']?\s*[:=]\s*["']?)[^"',\s}]+()"#,
        #"(-w\s+)(\S+)()"#
    ]
    for pattern in patterns {
        redacted = redacted.replacingOccurrences(
            of: pattern,
            with: "$1[redacted]$2",
            options: .regularExpression
        )
    }
    if redacted.localizedCaseInsensitiveContains("security add-generic-password") {
        return "Could not store credentials in macOS Keychain. Open Settings and try reconnecting."
    }
    return redacted
}

func workspaceDiffHasContent(_ item: TranscriptItem) -> Bool {
    guard let diff = item.payload["diff"]?.stringValue, !diff.isEmpty else {
        return false
    }
    if let stats = item.payload["diffStats"]?.objectValue {
        let additions = Int(stats["additions"]?.numberValue ?? 0)
        let deletions = Int(stats["deletions"]?.numberValue ?? 0)
        if additions > 0 || deletions > 0 {
            return true
        }
    }
    return diff.split(separator: "\n").contains { line in
        (line.hasPrefix("+") && !line.hasPrefix("+++"))
            || (line.hasPrefix("-") && !line.hasPrefix("---"))
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
