import Foundation
import Observation

@Observable
final class SessionStore {
    var sessions: [SessionSummary] = []
    var selectedSessionId: String?
    var graph = GraphState(sessionId: "", workflowId: "", nodes: [], edges: [])
    var transcript: [TranscriptItem] = []
    var presentNewSession = false
    var composerText = ""
    var connectionStatus = "Disconnected"

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
    }
}
