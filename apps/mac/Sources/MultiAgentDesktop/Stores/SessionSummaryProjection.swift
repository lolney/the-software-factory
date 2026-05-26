struct SessionSummaryStatusProjection: Hashable {
    var status: String
    var activeAgents: Int
    var failureCount: Int
}

func deriveSessionSummaryStatus(graph: GraphState, transcript: [TranscriptItem]) -> SessionSummaryStatusProjection {
    let failureCount = graph.nodes.reduce(0) { total, node in total + node.errorCount + (node.status == .failed ? 1 : 0) }
    let activeCount = graph.nodes.filter { [.working, .waiting, .paused].contains($0.status) }.count
    let latestOrchestratorStatus = transcript.reversed().first { item in
        item.agentId == "orchestrator" && item.type == "agent.status"
    }?.payload["status"]?.stringValue

    let status: String
    if failureCount > 0 || graph.nodes.contains(where: { $0.status == .failed }) {
        status = "failed"
    } else if graph.nodes.contains(where: { [.working, .waiting].contains($0.status) }) {
        status = "active"
    } else if graph.nodes.contains(where: { $0.status == .paused }) {
        status = "paused"
    } else if latestOrchestratorStatus == "cancelled" || graph.nodes.first(where: { $0.id == "orchestrator" })?.status == .cancelled {
        status = "cancelled"
    } else if latestOrchestratorStatus == "completed" || graph.nodes.first(where: { $0.id == "orchestrator" })?.status == .completed {
        status = "completed"
    } else {
        status = "idle"
    }

    return SessionSummaryStatusProjection(status: status, activeAgents: activeCount, failureCount: failureCount)
}
