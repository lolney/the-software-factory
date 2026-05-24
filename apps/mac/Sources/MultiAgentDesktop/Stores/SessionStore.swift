import Foundation
import Observation

@MainActor
@Observable
final class SessionStore {
    var sessions: [SessionSummary] = []
    var selectedSessionId: String?
    var graph = GraphState(sessionId: "", workflowId: "", nodes: [], edges: [])
    var transcript: [TranscriptItem] = []
    var presentNewSession = false
    var composerText = ""
    var connectionStatus = "Disconnected"
    var debugMode = true

    let daemon = DaemonClient()

    init() {
        sessions = [
            SessionSummary(id: "local-preview", title: "Local Preview", detail: "Daemon not connected")
        ]
        selectedSessionId = sessions.first?.id
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
            TranscriptItem(id: UUID().uuidString, agentId: "orchestrator", type: "message", text: "Create a new session to connect to the daemon and launch a workflow.", timestamp: Date())
        ]
        daemon.onMessage = { [weak self] data in
            Task { @MainActor in
                self?.handleDaemonMessage(data)
            }
        }
    }

    func connectAndRefresh() {
        daemon.connect()
        connectionStatus = daemon.isConnected ? "Connected" : "Connecting"
        daemon.sendRequest(method: "listSessions", params: [:])
    }

    func createSession(prompt: String) {
        if !daemon.isConnected {
            connectAndRefresh()
        }
        daemon.sendRequest(method: "createSession", params: [
            "prompt": prompt,
            "workspaceRoot": FileManager.default.homeDirectoryForCurrentUser.path,
            "workflowId": debugMode ? "implementor-reviewer" : "planner-orchestrator",
            "debugMode": debugMode
        ])
    }

    func sendComposerMessage() {
        let trimmed = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let selectedSessionId else { return }
        daemon.sendRequest(method: "sendMessage", params: [
            "sessionId": selectedSessionId,
            "text": trimmed
        ])
        composerText = ""
    }

    func pauseOrchestrator() {
        guard let selectedSessionId else { return }
        daemon.sendRequest(method: "pauseAgent", params: ["sessionId": selectedSessionId, "agentId": "orchestrator"])
    }

    func resumeOrchestrator() {
        guard let selectedSessionId else { return }
        daemon.sendRequest(method: "resumeAgent", params: ["sessionId": selectedSessionId, "agentId": "orchestrator"])
    }

    func cancelOrchestrator() {
        guard let selectedSessionId else { return }
        daemon.sendRequest(method: "cancelAgent", params: ["sessionId": selectedSessionId, "agentId": "orchestrator"])
    }

    private func handleDaemonMessage(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if object["method"] as? String == "event",
           let params = object["params"],
           let eventData = try? JSONSerialization.data(withJSONObject: params),
           let event = try? JSONDecoder().decode(SessionEvent.self, from: eventData) {
            apply(event: event)
            return
        }

        guard object["ok"] as? Bool == true, let result = object["result"] else { return }
        if let resultData = try? JSONSerialization.data(withJSONObject: result),
           let snapshot = try? JSONDecoder().decode(SessionSnapshot.self, from: resultData) {
            apply(snapshot: snapshot)
            return
        }

        if let resultDict = result as? [String: Any],
           let sessionsValue = resultDict["sessions"],
           let sessionsData = try? JSONSerialization.data(withJSONObject: sessionsValue),
           let summaries = try? JSONDecoder().decode([SessionSummary].self, from: sessionsData) {
            sessions = summaries.map { SessionSummary(id: $0.id, title: $0.title, detail: $0.detail) }
            if selectedSessionId == nil {
                selectedSessionId = sessions.first?.id
            }
        }
    }

    private func apply(snapshot: SessionSnapshot) {
        selectedSessionId = snapshot.sessionId
        graph = snapshot.graph
        transcript = snapshot.transcript.map(transcriptItem)
        let summary = SessionSummary(id: snapshot.sessionId, title: snapshot.title, detail: snapshot.workflowId)
        sessions.removeAll { $0.id == snapshot.sessionId }
        sessions.insert(summary, at: 0)
        connectionStatus = "Connected"
    }

    private func apply(event: SessionEvent) {
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
            sessions.removeAll { $0.id == event.sessionId }
            sessions.insert(SessionSummary(id: event.sessionId, title: title, detail: workflowId), at: 0)
            selectedSessionId = event.sessionId
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
                graph.nodes[index].unreadCount += 1
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
        let text = event.payload["text"]?.stringValue
            ?? event.payload["summary"]?.stringValue
            ?? event.payload["output"]?.stringValue
            ?? event.payload["reason"]?.stringValue
            ?? event.type
        return TranscriptItem(id: event.eventId, agentId: event.agentId, type: event.type, text: text, timestamp: Date())
    }
}
