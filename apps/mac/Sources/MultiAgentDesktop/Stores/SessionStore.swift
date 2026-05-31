import Foundation
import AppKit
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class SessionStore {
    static let newSessionDraftId = "new-session-draft"
    static let sessionDashboardId = "session-dashboard"
    static let richMockupSessionId = "mockup-debug-temperature"

    var sessions: [SessionSummary] = []
    var archivedSessions: [SessionSummary] = []
    var selectedSessionId: String?
    var selectedSidebarItem: String?
    var selectedSidebarItems: Set<String> = []
    var dashboardSessionFilterIds: Set<String> = []
    var graph = GraphState(sessionId: "", workflowId: "", nodes: [], edges: [])
    var transcript: [TranscriptItem] = []
    var debugLogs: [DebugLogItem] = []
    var inspectorPanel: InspectorPanel = .graph {
        didSet {
            if inspectorPanel != oldValue {
                selectedTimelineEventId = nil
            }
        }
    }
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
    var composerImageAttachments: [ImageAttachment] = []
    var openAIApiKeyInput = ""
    var chatGPTAccountIdInput = ""
    var connectionStatus = "Disconnected"
    var debugMode = false
    var newSessionWorkspaceRoot = ""
    var newSessionModel = ""
    var newSessionReasoningEffort = "none"
    var isCreatingSession = false
    var lastError: String?
    var pendingOpenAIReauthURL: URL?
    var usesStaticMockupFixture = false
    var selectedAgentId: String?
    var controlAgentId: String?
    var selectedTimelineEventId: String?
    var isInspectorVisible = true
    var focusTranscriptSearchSignal = 0
    var graphCommandRequest: GraphViewCommandRequest?
    var transcriptSearchText = "" {
        didSet {
            if transcriptSearchText != oldValue {
                selectedTimelineEventId = nil
            }
        }
    }
    var isLoadingSelection = false
    private var subscribedSessionIds = Set<String>()
    private var subscribedDebugLogSessionIds = Set<String>()
    private var pendingCreatePrompt: String?
    private var pendingCreateImageAttachments: [ImageAttachment] = []
    private var pendingCreateRequestId: String?
    private var pendingCreateRequestSent = false
    private var pendingOpenAIOAuth = false
    private var pendingOpenAIOAuthRequestId: String?
    private var pendingOpenAIOAuthRequestSent = false
    private let localDaemonLauncher = LocalDaemonLauncher()
    @ObservationIgnored private var sessionRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var isConnectAndRefreshInFlight = false

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

    var isSessionDetailSurfaceSelected: Bool {
        let libraryRoutes: Set<String> = ["roles", "workflows", "archived", Self.sessionDashboardId]
        guard let selectedSidebarItem else { return selectedSessionId != nil }
        return !libraryRoutes.contains(selectedSidebarItem)
    }

    var canUseSessionViewCommands: Bool {
        isSessionDetailSurfaceSelected && !isComposingNewSession
    }

    var canSendComposerMessage: Bool {
        let hasText = !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasImages = !composerImageAttachments.isEmpty
        if isComposingNewSession {
            return (hasText || hasImages) && !isCreatingSession && (debugMode || authStatus?.liveCredentialConfigured == true)
        }
        return daemon.isConnected && hasActiveSession && !selectedSessionArchived && ![.paused, .cancelled, .failed, .completed].contains(orchestratorStatus) && (hasText || hasImages)
    }

    var orchestratorStatus: AgentStatus {
        graph.nodes.first { $0.id == orchestratorAgentId }?.status ?? .idle
    }

    var orchestratorAgentId: String {
        if graph.nodes.contains(where: { $0.id == "orchestrator" }) {
            return "orchestrator"
        }
        return graph.nodes.first?.id ?? "orchestrator"
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

    var selectedTimelineEvent: TranscriptItem? {
        guard let selectedTimelineEventId else { return nil }
        return filteredTranscript.first { $0.id == selectedTimelineEventId }
    }

    var sessionErrorCount: Int {
        graph.nodes.reduce(0) { total, node in total + node.errorCount }
    }

    var statusBannerText: String? {
        if let lastError, !lastError.isEmpty {
            if isConnectionHealthy && isDaemonDisconnectedMessage(lastError) {
                return nil
            }
            return sanitizedDisplayError(lastError)
        }
        if !isConnectionHealthy && connectionStatus == "Connecting" {
            return "Connecting to the local daemon..."
        }
        if !isConnectionHealthy && hasActiveSession && !isComposingNewSession {
            return "Daemon is disconnected. Reconnect before controlling this session."
        }
        if sessionErrorCount > 0 {
            let suffix = sessionErrorCount == 1 ? "" : "s"
            return "\(sessionErrorCount) agent error\(suffix) in this session. Open Debug for details."
        }
        return nil
    }

    var isConnectionHealthy: Bool {
        usesStaticMockupFixture || daemon.isConnected
    }

    var touchedWorkspaceFiles: [WorkspaceFileSummary] {
        var summaries: [String: WorkspaceFileSummary] = [:]
        for item in transcript where item.type == "workspace.file_touched" || item.type == "workspace.conflict_detected" {
            guard let path = workspaceEventPath(item) else { continue }
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
        return transcriptAgentOptions.first { $0.id == selectedAgentId }?.label ?? selectedAgentId
    }

    var transcriptAgentOptions: [AgentFilterOption] {
        var seen = Set<String>()
        var options: [AgentFilterOption] = []

        for node in graph.nodes where seen.insert(node.id).inserted {
            options.append(AgentFilterOption(
                id: node.id,
                label: node.label,
                colorHex: node.colorHex,
                status: node.status,
                unreadCount: node.unreadCount,
                errorCount: node.errorCount
            ))
        }

        let fallbackIds = transcript.flatMap { item in
            [
                item.agentId,
                item.sender,
                item.recipient,
                item.payload["from"]?.stringValue,
                item.payload["to"]?.stringValue
            ]
        }
        .compactMap(Self.normalizedAgentId)
        .filter { $0 != "user" && $0 != "system" }

        for id in fallbackIds where seen.insert(id).inserted {
            options.append(AgentFilterOption(
                id: id,
                label: id,
                colorHex: nil,
                status: nil,
                unreadCount: 0,
                errorCount: 0
            ))
        }
        return options
    }

    private static func normalizedAgentId(_ id: String?) -> String? {
        guard let value = id?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
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
        daemon.onRequestSent = { [weak self] requestId in
            Task { @MainActor in
                self?.markPendingRequestSent(requestId)
            }
        }
        daemon.onDisconnect = { [weak self] reason in
            Task { @MainActor in
                self?.connectionStatus = "Disconnected"
                self?.lastError = reason
                self?.preparePendingRequestsAfterDisconnect()
                self?.resetSubscriptions()
                self?.stopSessionRefreshLoop()
            }
        }
        daemon.onSendError = { [weak self] reason in
            Task { @MainActor in
                guard let self else { return }
                if self.isTransientDaemonSocketError(reason) {
                    self.connectionStatus = "Connecting"
                    self.lastError = nil
                    self.rearmPendingRequestsForSocketRetry()
                    self.connectAndRefresh()
                    return
                }
                self.lastError = reason
                self.isCreatingSession = false
                self.clearPendingCreate()
                self.clearPendingOpenAIOAuth()
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
        guard !isConnectAndRefreshInFlight else { return }
        isConnectAndRefreshInFlight = true
        defer { isConnectAndRefreshInFlight = false }
        connectionStatus = daemon.isConnected ? "Connected" : "Connecting"
        lastError = nil
        let daemonStarted = await localDaemonLauncher.ensureStarted(port: daemonPort)
        guard daemonStarted else {
            connectionStatus = "Disconnected"
            lastError = "Could not start the local daemon. Check ~/Library/Application Support/The Software Factory/logs/app-daemon.log for details."
            return
        }
        resetSubscriptions()
        for attempt in 0..<3 {
            if attempt == 0 {
                daemon.connect(port: daemonPort)
            } else {
                resetSubscriptions()
                rearmPendingRequestsForSocketRetry()
                daemon.reconnect(port: daemonPort)
            }
            try? await Task.sleep(for: .milliseconds(250))
            sendInitialDaemonRequests()
            try? await Task.sleep(for: .milliseconds(900))
            if daemon.isConnected {
                connectionStatus = "Connected"
                startSessionRefreshLoop()
                return
            }
        }
        daemon.disconnect()
        connectionStatus = "Disconnected"
        lastError = "Daemon is running, but the app could not open its WebSocket connection. Try relaunching The Software Factory."
    }

    private func sendInitialDaemonRequests() {
        if let prompt = pendingCreatePrompt, !pendingCreateRequestSent {
            pendingCreateRequestSent = true
            let attachments = pendingCreateImageAttachments
            sendCreateSession(prompt: prompt, imageAttachments: attachments)
            return
        }
        if pendingOpenAIOAuth, !pendingOpenAIOAuthRequestSent {
            sendPendingOpenAIOAuth()
            return
        }
        refreshSessions()
        refreshCatalogs()
        if let selectedSessionId {
            daemon.sendRequest(method: "getSnapshot", params: ["sessionId": selectedSessionId])
            subscribe(to: selectedSessionId)
            subscribeDebugLogs(to: selectedSessionId)
        }
    }

    private func isTransientDaemonSocketError(_ reason: String) -> Bool {
        let normalized = reason.lowercased()
        return normalized.contains("socket is not connected")
            || normalized == "daemon is not connected."
    }

    private func clearPendingCreate() {
        pendingCreatePrompt = nil
        pendingCreateImageAttachments = []
        pendingCreateRequestSent = false
    }

    private func clearPendingOpenAIOAuth() {
        pendingOpenAIOAuth = false
        pendingOpenAIOAuthRequestSent = false
    }

    private func rearmPendingRequestsForSocketRetry() {
        if pendingCreatePrompt != nil {
            pendingCreateRequestSent = false
        }
        if pendingOpenAIOAuth {
            pendingOpenAIOAuthRequestSent = false
        }
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

    func createSession(prompt: String, imageAttachments: [ImageAttachment] = []) {
        pendingCreatePrompt = prompt
        pendingCreateImageAttachments = imageAttachments
        pendingCreateRequestSent = false
        isCreatingSession = true
        guard daemon.isConnected else {
            connectAndRefresh()
            lastError = "Connecting to daemon. The session will be created automatically."
            return
        }
        pendingCreateRequestSent = true
        sendCreateSession(prompt: prompt, imageAttachments: imageAttachments)
    }

    func cancelNewSession() {
        clearPendingCreate()
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

    private func sendCreateSession(prompt: String, imageAttachments: [ImageAttachment] = []) {
        isCreatingSession = true
        lastError = nil
        let workflowId = selectedWorkflowId(for: prompt)
        var params: [String: Any] = [
            "prompt": prompt,
            "imageAttachments": imageAttachments.map(\.payload),
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
        isInspectorVisible = true
        selectedTimelineEventId = nil
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
        selectedTimelineEventId = nil
        guard let agentId,
              let index = graph.nodes.firstIndex(where: { $0.id == agentId }) else { return }
        graph.nodes[index].unreadCount = 0
        if let last = transcript.reversed().first(where: { item in
            item.agentId == agentId || item.sender == agentId || item.recipient == agentId
        }) {
            daemon.sendRequest(method: "ackClientEvent", params: ["sessionId": graph.sessionId, "eventId": last.id])
        }
    }

    func selectTimelineEvent(_ eventId: String?) {
        selectedTimelineEventId = eventId
    }

    func clearSelectedTimelineEvent() {
        selectedTimelineEventId = nil
    }

    func attachComposerImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.png, .jpeg, .webP, .gif, .heic, .tiff]
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        var next = composerImageAttachments
        for url in panel.urls.prefix(max(0, 6 - next.count)) {
            guard let attachment = imageAttachment(for: url) else { continue }
            next.append(attachment)
        }
        composerImageAttachments = next
    }

    @discardableResult
    func pasteComposerImagesFromPasteboard(_ pasteboard: NSPasteboard = .general) -> Bool {
        let pasted = imageAttachments(from: pasteboard, remainingSlots: max(0, 6 - composerImageAttachments.count))
        guard !pasted.isEmpty else { return false }
        composerImageAttachments = composerImageAttachments + pasted
        return true
    }

    func removeComposerImageAttachment(_ attachmentId: String) {
        composerImageAttachments.removeAll { $0.id == attachmentId }
    }

    func focusTranscriptSearch() {
        guard canUseSessionViewCommands else { return }
        focusTranscriptSearchSignal += 1
    }

    func toggleInspectorVisibility() {
        guard canUseSessionViewCommands else { return }
        isInspectorVisible.toggle()
    }

    func showInspectorPanel(_ panel: InspectorPanel) {
        guard canUseSessionViewCommands else { return }
        clearSelectedTimelineEvent()
        inspectorPanel = panel
        isInspectorVisible = true
    }

    func applyGraphCommand(_ command: GraphViewCommand) {
        showInspectorPanel(.graph)
        graphCommandRequest = GraphViewCommandRequest(command: command)
    }

    func setControlAgent(_ agentId: String?) {
        controlAgentId = agentId
    }

    func clearLastError() {
        lastError = nil
        pendingOpenAIReauthURL = nil
    }

    private func clearStaleDaemonDisconnectedError() {
        if let lastError, isDaemonDisconnectedMessage(lastError) {
            self.lastError = nil
        }
    }

    func sendComposerMessage() {
        let trimmed = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = composerImageAttachments
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        let text = trimmed.isEmpty ? "Please review the attached image." : trimmed
        if isComposingNewSession {
            createSession(prompt: text, imageAttachments: attachments)
            return
        }
        guard let selectedSessionId, daemon.isConnected else { return }
        daemon.sendRequest(method: "sendMessage", params: [
            "sessionId": selectedSessionId,
            "text": text,
            "imageAttachments": attachments.map(\.payload)
        ])
        composerText = ""
        composerImageAttachments = []
    }

    func pauseOrchestrator() {
        guard let selectedSessionId else { return }
        daemon.sendRequest(method: "pauseAgent", params: ["sessionId": selectedSessionId, "agentId": orchestratorAgentId])
    }

    func resumeOrchestrator() {
        guard let selectedSessionId else { return }
        daemon.sendRequest(method: "resumeAgent", params: ["sessionId": selectedSessionId, "agentId": orchestratorAgentId])
    }

    func retryRecoveredJob(_ job: RecoveredSchedulerJob) {
        guard let selectedSessionId else { return }
        daemon.sendRequest(method: "retryRecoveredJob", params: ["sessionId": selectedSessionId, "jobId": job.jobId])
    }

    func cancelOrchestrator() {
        guard let selectedSessionId else { return }
        daemon.sendRequest(method: "cancelAgent", params: ["sessionId": selectedSessionId, "agentId": orchestratorAgentId])
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
            .filter {
                ($0.type == "workspace.file_touched" || $0.type == "workspace.conflict_detected")
                    && workspaceEventPath($0) == relativePath
            }
            .filter(workspaceDiffHasContent)
            .sorted { $0.timestamp > $1.timestamp }
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
        pendingOpenAIOAuth = true
        guard daemon.isConnected else {
            pendingOpenAIOAuthRequestSent = false
            connectAndRefresh()
            lastError = "Connecting to daemon. OpenAI setup will continue automatically."
            return
        }
        sendPendingOpenAIOAuth()
    }

    func openPendingOpenAIReauthentication() {
        if let pendingOpenAIReauthURL {
            NSWorkspace.shared.open(pendingOpenAIReauthURL)
        } else {
            beginOpenAIOAuth()
        }
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

    private func sendPendingOpenAIOAuth() {
        guard pendingOpenAIOAuth, !pendingOpenAIOAuthRequestSent else { return }
        pendingOpenAIOAuthRequestSent = true
        sendBeginOpenAIOAuth()
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
        clearPendingCreate()
        composerText = ""
        composerImageAttachments = []
        newSessionWorkspaceRoot = ""
        newSessionModel = ""
        newSessionReasoningEffort = "none"
        selectedSessionId = nil
        selectedSidebarItem = Self.newSessionDraftId
        selectedSidebarItems = [Self.newSessionDraftId]
        selectedAgentId = nil
        controlAgentId = nil
        selectedTimelineEventId = nil
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
        clearStaleDaemonDisconnectedError()
        if pendingOpenAIOAuth, object["method"] == nil {
            sendPendingOpenAIOAuth()
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
            clearPendingCreate()
            clearPendingOpenAIOAuth()
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
            clearPendingOpenAIOAuth()
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
        isInspectorVisible = true
        selectedTimelineEventId = nil
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
        clearStaleDaemonDisconnectedError()
        isCreatingSession = false
        clearPendingCreate()
        isLoadingSelection = false
        isComposingNewSession = false
        composerText = ""
        composerImageAttachments = []
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
                    isInspectorVisible = true
                    currentWorkspaceRoot = workspaceRoot
                    currentSessionDebugMode = event.payload["debugMode"]?.boolValue
                    transcript = []
                    debugLogs = []
                    selectedAgentId = nil
                    controlAgentId = nil
                    selectedTimelineEventId = nil
                    if let graphValue = event.payload["graph"],
                       let data = try? JSONEncoder().encode(graphValue),
                       let decoded = try? JSONDecoder().decode(GraphState.self, from: data) {
                        graph = decoded
                    }
                    subscribe(to: event.sessionId)
                    subscribeDebugLogs(to: event.sessionId)
                    isCreatingSession = false
                    clearPendingCreate()
                    isComposingNewSession = false
                    composerText = ""
                    composerImageAttachments = []
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
            isInspectorVisible = true
            selectedTimelineEventId = nil
            subscribe(to: event.sessionId)
            subscribeDebugLogs(to: event.sessionId)
            selectedAgentId = nil
            controlAgentId = nil
            isCreatingSession = false
            clearPendingCreate()
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
            let kind: EdgeKind = event.type == "message.sent" ? .message : .handoff
            if let index = graph.edges.firstIndex(where: { $0.from == from && $0.to == to && $0.kind == kind }) {
                graph.edges[index].active = true
            } else if graph.nodes.contains(where: { $0.id == from }) && graph.nodes.contains(where: { $0.id == to }) {
                let preferredId = event.payload["edgeId"]?.stringValue ?? "\(kind.rawValue)-\(from)-\(to)"
                let edgeId = graph.edges.contains(where: { $0.id == preferredId }) ? "\(preferredId)-\(event.eventId)" : preferredId
                graph.edges.append(AgentEdge(id: edgeId, from: from, to: to, kind: kind, active: true))
            }
        case "agent.message":
            if let agentId = event.agentId,
               let index = graph.nodes.firstIndex(where: { $0.id == agentId }) {
                if selectedAgentId != agentId {
                    graph.nodes[index].unreadCount += 1
                }
            }
        case "error":
            handleAuthenticationRequired(event)
            if let agentId = event.agentId,
               let index = graph.nodes.firstIndex(where: { $0.id == agentId }) {
                graph.nodes[index].errorCount += 1
            }
        default:
            break
        }
        refreshSessionSummaryStatuses()
    }

    private func handleAuthenticationRequired(_ event: SessionEvent) {
        guard event.payload["authenticationRequired"]?.boolValue == true,
              event.payload["authProvider"]?.stringValue == "openai" else { return }
        let message = event.payload["message"]?.stringValue ?? "OpenAI authentication expired. Sign in again to continue live runs."
        lastError = sanitizedDisplayError(message)
        refreshAuthStatus()
        guard let rawURL = event.payload["authorizationUrl"]?.stringValue,
              let url = URL(string: rawURL) else { return }
        pendingOpenAIReauthURL = url
        NSWorkspace.shared.open(url)
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
        let selectedId = Self.richMockupSessionId
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
        isInspectorVisible = true
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
                AgentNode(id: "qa", roleId: "qa", label: "QA", status: .completed, colorHex: "#4aa6a6", unreadCount: 2, errorCount: 0)
            ],
            edges: [
                AgentEdge(id: "orchestrator-planner", from: "orchestrator", to: "planner", kind: .handoff, active: false),
                AgentEdge(id: "planner-implementor", from: "planner", to: "implementor", kind: .handoff, active: false),
                AgentEdge(id: "implementor-reviewer", from: "implementor", to: "reviewer", kind: .handoff, active: false),
                AgentEdge(id: "implementor-qa", from: "implementor", to: "qa", kind: .handoff, active: false),
                AgentEdge(id: "message-reviewer-orchestrator", from: "reviewer", to: "orchestrator", kind: .message, active: true),
                AgentEdge(id: "message-qa-orchestrator", from: "qa", to: "orchestrator", kind: .message, active: true)
            ]
        )

        transcript = [
            transcriptItem("mockup-user-prompt", agentId: "user", sender: "user", recipient: "orchestrator", type: "agent.message", text: "Audit a small debug workflow and produce visible transcript events.", offset: -770),
            transcriptItem("mockup-orchestrator-working", agentId: "orchestrator", type: "agent.status", text: "Status: working", offset: -735, payload: ["status": .string("working")]),
            transcriptItem("mockup-orchestrator-goal", agentId: "orchestrator", type: "agent.message", text: "Debug orchestrator: Goal received. Planning and delegating to Implementor.", offset: -720),
            transcriptItem("mockup-handoff-orchestrator-planner", agentId: "orchestrator", sender: "orchestrator", recipient: "planner", type: "handoff.created", text: "Handoff to Planner", offset: -705, payload: ["from": .string("orchestrator"), "to": .string("planner"), "edgeId": .string("orchestrator-planner")]),
            transcriptItem("mockup-planner-working", agentId: "planner", type: "agent.status", text: "Status: working", offset: -700, payload: ["status": .string("working")]),
            transcriptItem("mockup-planner-plan", agentId: "planner", type: "agent.message", text: "Debug planner: Selected the workflow graph, confirmed responsibilities, and handed the plan back to Orchestrator.", offset: -690),
            transcriptItem(
                "mockup-plan-created",
                agentId: "planner",
                type: "plan.created",
                text: "Build, review, and QA the requested CLI",
                offset: -650,
                payload: ["planId": .string("temperature-converter-plan")]
            ),
            transcriptItem("mockup-handoff-planner-implementor", agentId: "planner", sender: "planner", recipient: "implementor", type: "handoff.created", text: "Handoff to Implementor", offset: -620, payload: ["from": .string("planner"), "to": .string("implementor"), "edgeId": .string("planner-implementor")]),
            transcriptItem("mockup-planner-idle", agentId: "planner", type: "agent.status", text: "Status: idle", offset: -615, payload: ["status": .string("idle")]),
            transcriptItem("mockup-implementor-working", agentId: "implementor", type: "agent.status", text: "Status: working", offset: -610, payload: ["status": .string("working")]),
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
            transcriptItem("mockup-handoff-implementor-reviewer", agentId: "implementor", sender: "implementor", recipient: "reviewer", type: "handoff.created", text: "Handoff to Reviewer", offset: -480, payload: ["from": .string("implementor"), "to": .string("reviewer"), "edgeId": .string("implementor-reviewer")]),
            transcriptItem("mockup-handoff-implementor-qa", agentId: "implementor", sender: "implementor", recipient: "qa", type: "handoff.created", text: "Handoff to QA", offset: -470, payload: ["from": .string("implementor"), "to": .string("qa"), "edgeId": .string("implementor-qa")]),
            transcriptItem("mockup-implementor-completed", agentId: "implementor", type: "agent.status", text: "Status: completed", offset: -465, payload: ["status": .string("completed")]),
            transcriptItem("mockup-reviewer-working", agentId: "reviewer", type: "agent.status", text: "Status: working", offset: -455, payload: ["status": .string("working")]),
            transcriptItem("mockup-qa-working", agentId: "qa", type: "agent.status", text: "Status: working", offset: -450, payload: ["status": .string("working")]),
            transcriptItem(
                "mockup-test-run",
                agentId: "qa",
                type: "agent.tool_result",
                text: "python3 -m unittest test_temperature_converter.py completed successfully.",
                offset: -430,
                payload: ["callId": .string("test-run"), "toolName": .string("test run"), "status": .string("done")]
            ),
            transcriptItem("mockup-qa-message", agentId: "qa", type: "agent.message", text: "QA acceptance passed: python3 -m unittest test_temperature_converter.py completed successfully.", offset: -310),
            transcriptItem("mockup-qa-completed", agentId: "qa", type: "agent.status", text: "Status: completed", offset: -300, payload: ["status": .string("completed")]),
            transcriptItem("mockup-reviewer-message", agentId: "reviewer", type: "agent.message", text: "Debug reviewer: Reviewed implementation and sent one follow-up to Implementor.", offset: -260),
            transcriptItem("mockup-reviewer-completed", agentId: "reviewer", type: "agent.status", text: "Status: completed", offset: -250, payload: ["status": .string("completed")]),
            transcriptItem("mockup-message-reviewer-orchestrator", agentId: "reviewer", sender: "reviewer", recipient: "orchestrator", type: "message.sent", text: "Review accepted.", offset: -230, payload: ["from": .string("reviewer"), "to": .string("orchestrator"), "text": .string("Review accepted.")]),
            transcriptItem("mockup-message-qa-orchestrator", agentId: "qa", sender: "qa", recipient: "orchestrator", type: "message.sent", text: "QA passed.", offset: -220, payload: ["from": .string("qa"), "to": .string("orchestrator"), "text": .string("QA passed.")]),
            transcriptItem("mockup-orchestrator-idle", agentId: "orchestrator", type: "agent.status", text: "Status: idle", offset: -200, payload: ["status": .string("idle")]),
            transcriptItem("mockup-complete", agentId: "orchestrator", type: "workflow.completed", text: "All acceptance checks passed. Workflow complete.", offset: -2)
        ]
        debugLogs = []
    }

    private func selectStaticMockupSession(_ sessionId: String) {
        if sessionId == Self.richMockupSessionId {
            applyMockupFixture(referenceNow: Date())
            return
        }
        selectedSessionId = sessionId
        selectedSidebarItem = sessionId
        selectedSidebarItems = [sessionId]
        isInspectorVisible = true
        selectedTimelineEventId = nil
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

private func imageAttachment(for url: URL) -> ImageAttachment? {
    guard let data = try? Data(contentsOf: url),
          data.count <= 10_000_000 else {
        return nil
    }
    let contentType = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
    let mimeType = contentType?.preferredMIMEType ?? mimeTypeForImageExtension(url.pathExtension)
    guard mimeType.hasPrefix("image/") else { return nil }
    return ImageAttachment(
        id: "img_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))",
        name: url.lastPathComponent,
        mimeType: mimeType,
        dataBase64: data.base64EncodedString()
    )
}

private func imageAttachments(from pasteboard: NSPasteboard, remainingSlots: Int) -> [ImageAttachment] {
    guard remainingSlots > 0 else { return [] }
    var attachments: [ImageAttachment] = []
    for (index, item) in (pasteboard.pasteboardItems ?? []).enumerated() {
        guard attachments.count < remainingSlots else { break }
        if let attachment = imageAttachment(from: item, index: index + 1) {
            attachments.append(attachment)
        }
    }
    if attachments.isEmpty,
       let urls = pasteboard.readObjects(
        forClasses: [NSURL.self],
        options: [.urlReadingFileURLsOnly: true]
       ) as? [URL] {
        for url in urls {
            guard attachments.count < remainingSlots else { break }
            if let attachment = imageAttachment(for: url) {
                attachments.append(attachment)
            }
        }
    }
    if attachments.isEmpty,
       let images = pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage] {
        for (index, image) in images.enumerated() {
            guard attachments.count < remainingSlots else { break }
            if let data = pngData(from: image),
               let attachment = makeImageAttachment(
                    name: "Pasted image \(index + 1).png",
                    mimeType: "image/png",
                    data: data
               ) {
                attachments.append(attachment)
            }
        }
    }
    return attachments
}

extension NSPasteboard {
    var containsComposerImage: Bool {
        if let items = pasteboardItems,
           items.contains(where: { imageAttachment(from: $0, index: 1) != nil }) {
            return true
        }
        if let urls = readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL],
            urls.contains(where: { imageAttachment(for: $0) != nil }) {
            return true
        }
        return canReadObject(forClasses: [NSImage.self], options: nil)
    }
}

private func imageAttachment(from item: NSPasteboardItem, index: Int) -> ImageAttachment? {
    let candidates: [(NSPasteboard.PasteboardType, String, String)] = [
        (.png, "image/png", "png"),
        (NSPasteboard.PasteboardType("public.jpeg"), "image/jpeg", "jpg"),
        (NSPasteboard.PasteboardType("public.webP"), "image/webp", "webp"),
        (NSPasteboard.PasteboardType("public.heic"), "image/heic", "heic"),
        (NSPasteboard.PasteboardType("com.compuserve.gif"), "image/gif", "gif")
    ]
    for (type, mimeType, pathExtension) in candidates {
        if let data = item.data(forType: type) {
            return makeImageAttachment(
                name: "Pasted image \(index).\(pathExtension)",
                mimeType: mimeType,
                data: data
            )
        }
    }
    if let data = item.data(forType: .tiff),
       let image = NSImage(data: data),
       let png = pngData(from: image) {
        return makeImageAttachment(name: "Pasted image \(index).png", mimeType: "image/png", data: png)
    }
    return nil
}

private func makeImageAttachment(name: String, mimeType: String, data: Data) -> ImageAttachment? {
    guard data.count <= 10_000_000 else { return nil }
    return ImageAttachment(
        id: "img_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))",
        name: name,
        mimeType: mimeType,
        dataBase64: data.base64EncodedString()
    )
}

private func pngData(from image: NSImage) -> Data? {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff) else {
        return nil
    }
    return bitmap.representation(using: .png, properties: [:])
}

private func mimeTypeForImageExtension(_ pathExtension: String) -> String {
    switch pathExtension.lowercased() {
    case "jpg", "jpeg": return "image/jpeg"
    case "webp": return "image/webp"
    case "gif": return "image/gif"
    case "heic": return "image/heic"
    case "tif", "tiff": return "image/tiff"
    default: return "image/png"
    }
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

func workspaceEventPath(_ item: TranscriptItem) -> String? {
    item.payload["relativePath"]?.stringValue ?? item.payload["path"]?.stringValue ?? item.text.nilIfEmpty
}

func isDaemonDisconnectedMessage(_ message: String) -> Bool {
    let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized == "daemon is not connected."
        || normalized == "daemon is not connected"
        || normalized.contains("daemon disconnected")
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
