import XCTest
@testable import MultiAgentDesktop

@MainActor
final class ProjectionTests: XCTestCase {
    func testTranscriptFilteringIncludesPairedToolEventsWhenSearchMatchesResult() {
        let store = SessionStore()
        store.transcript = [
            item(id: "call", agentId: "implementor", type: "agent.tool_call", text: "Tool call", payload: ["callId": .string("tool-1"), "toolName": .string("workspace_run_command")]),
            item(id: "result", agentId: "implementor", type: "agent.tool_result", text: "all tests passed", payload: ["callId": .string("tool-1"), "toolName": .string("workspace_run_command"), "output": .string("all tests passed")]),
            item(id: "other", agentId: "reviewer", type: "agent.message", text: "looks good")
        ]
        store.transcriptSearchText = "passed"

        XCTAssertEqual(store.filteredTranscript.map(\.id), ["call", "result"])
    }

    func testTimelinePairsToolCallAndResultBeforeApplyingLimit() {
        let transcript = [
            item(id: "older", agentId: "orchestrator", type: "agent.message", text: "older"),
            item(id: "call", agentId: "qa", type: "agent.tool_call", text: "run tests", payload: ["callId": .string("run-1"), "toolName": .string("workspace_run_command")]),
            item(id: "noise", agentId: "qa", type: "agent.status", text: "Status: working", payload: ["status": .string("working")]),
            item(id: "result", agentId: "qa", type: "agent.tool_result", text: "OK", payload: ["callId": .string("run-1"), "toolName": .string("workspace_run_command"), "output": .string("OK")])
        ]

        let window = timelineWindow(from: transcript, limit: 2)

        guard let pairedTool = window.items.first(where: {
            if case .tool = $0 { return true }
            return false
        }),
        case .tool(let call, let result?) = pairedTool else {
            return XCTFail("Expected paired tool row to survive timeline limiting")
        }
        XCTAssertEqual(call.id, "call")
        XCTAssertEqual(result.id, "result")
    }

    func testEventLogExportPreservesStructuredPayloadFields() throws {
        let store = SessionStore()
        store.selectedSessionId = "session-1"
        store.transcript = [
            item(
                id: "event-1",
                sessionId: "session-1",
                agentId: "implementor",
                type: "workspace.file_touched",
                text: "main.py",
                payload: ["path": .string("main.py"), "diffStats": .object(["additions": .number(2), "deletions": .number(1)])],
                causationId: "cause-1"
            )
        ]

        let line = store.eventLogExportText
        let data = try XCTUnwrap(line.data(using: .utf8))
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(decoded?["eventId"] as? String, "event-1")
        XCTAssertEqual(decoded?["sessionId"] as? String, "session-1")
        XCTAssertEqual(decoded?["agentId"] as? String, "implementor")
        XCTAssertEqual(decoded?["causationId"] as? String, "cause-1")
        let payload = decoded?["payload"] as? [String: Any]
        XCTAssertEqual(payload?["path"] as? String, "main.py")
        let stats = payload?["diffStats"] as? [String: Any]
        XCTAssertEqual(stats?["additions"] as? Double, 2)
        XCTAssertEqual(stats?["deletions"] as? Double, 1)
    }

    func testSessionSummaryStatusProjectionPrioritizesFailuresAndActiveStates() {
        let graph = GraphState(
            sessionId: "session-1",
            workflowId: "planner-orchestrator",
            nodes: [
                node(id: "orchestrator", status: .completed),
                node(id: "qa", status: .failed, errorCount: 1),
                node(id: "implementor", status: .working)
            ],
            edges: []
        )

        let projection = deriveSessionSummaryStatus(graph: graph, transcript: [])

        XCTAssertEqual(projection.status, "failed")
        XCTAssertEqual(projection.activeAgents, 1)
        XCTAssertEqual(projection.failureCount, 2)
    }

    func testSessionSummaryStatusProjectionUsesLatestOrchestratorTerminalEvent() {
        let graph = GraphState(
            sessionId: "session-1",
            workflowId: "planner-orchestrator",
            nodes: [node(id: "orchestrator", status: .idle)],
            edges: []
        )
        let transcript = [
            item(id: "status", agentId: "orchestrator", type: "agent.status", text: "Status: completed", payload: ["status": .string("completed")])
        ]

        let projection = deriveSessionSummaryStatus(graph: graph, transcript: transcript)

        XCTAssertEqual(projection.status, "completed")
        XCTAssertEqual(projection.activeAgents, 0)
        XCTAssertEqual(projection.failureCount, 0)
    }

    private func item(
        id: String,
        sessionId: String = "session-1",
        agentId: String?,
        type: String,
        text: String,
        payload: [String: JSONValue] = [:],
        causationId: String? = nil
    ) -> TranscriptItem {
        TranscriptItem(
            id: id,
            sessionId: sessionId,
            agentId: agentId,
            sender: agentId ?? "system",
            recipient: nil,
            type: type,
            text: text,
            timestamp: Date(timeIntervalSince1970: 0),
            rawTimestamp: "2026-05-25T00:00:00.000Z",
            payload: payload,
            causationId: causationId,
            correlationId: nil
        )
    }

    private func node(id: String, status: AgentStatus, errorCount: Int = 0) -> AgentNode {
        AgentNode(
            id: id,
            roleId: id,
            label: id,
            status: status,
            colorHex: "#888888",
            unreadCount: 0,
            errorCount: errorCount
        )
    }
}
