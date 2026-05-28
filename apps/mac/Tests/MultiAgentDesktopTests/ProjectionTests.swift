import XCTest
@testable import TheSoftwareFactory

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

    func testTranscriptAgentOptionsIncludeFallbackTranscriptAgents() {
        let store = SessionStore()
        store.graph = GraphState(
            sessionId: "session-1",
            workflowId: "wf",
            nodes: [node(id: "orchestrator", status: .idle)],
            edges: []
        )
        store.transcript = [
            item(id: "handoff", agentId: "orchestrator", sender: "orchestrator", recipient: "qa", type: "handoff.created", text: "handoff", payload: ["from": .string("orchestrator"), "to": .string("qa")]),
            item(id: "message", agentId: "reviewer", sender: "reviewer", recipient: "orchestrator", type: "message.sent", text: "reviewed")
        ]

        XCTAssertEqual(store.transcriptAgentOptions.map(\.id), ["orchestrator", "qa", "reviewer"])
    }

    func testSelectingAgentClearsTimelineEventDetail() {
        let store = SessionStore()
        store.graph = GraphState(sessionId: "session-1", workflowId: "wf", nodes: [node(id: "qa", status: .idle)], edges: [])
        store.transcript = [
            item(id: "qa-event", agentId: "qa", type: "agent.message", text: "QA"),
            item(id: "impl-event", agentId: "implementor", type: "agent.message", text: "Implementation")
        ]
        store.selectTimelineEvent("impl-event")

        store.selectAgent("qa")

        XCTAssertNil(store.selectedTimelineEventId)
        XCTAssertNil(store.selectedTimelineEvent)
    }

    func testStatusBannerRedactsSecretBearingCommandFailures() {
        let store = SessionStore()
        store.lastError = #"Command failed: security add-generic-password -a codex-public-client -s local.softwarefactory.codex-oauth -w {"accessToken":"secret-access","refreshToken":"secret-refresh"} -U"#

        let banner = store.statusBannerText ?? ""

        XCTAssertEqual(banner, "Could not store credentials in macOS Keychain. Open Settings and try reconnecting.")
        XCTAssertFalse(banner.contains("secret-access"))
        XCTAssertFalse(banner.contains("secret-refresh"))
    }

    func testWorkspaceDiffContentIgnoresHeaderOnlyDiffs() {
        let zeroDiff = item(
            id: "zero",
            agentId: "implementor",
            type: "workspace.file_touched",
            text: "main.py",
            payload: [
                "path": .string("main.py"),
                "diff": .string("--- a/main.py\n+++ b/main.py"),
                "diffStats": .object(["additions": .number(0), "deletions": .number(0)])
            ]
        )
        let changedDiff = item(
            id: "changed",
            agentId: "implementor",
            type: "workspace.file_touched",
            text: "main.py",
            payload: [
                "path": .string("main.py"),
                "diff": .string("--- a/main.py\n+++ b/main.py\n+print(\"hi\")"),
                "diffStats": .object(["additions": .number(1), "deletions": .number(0)])
            ]
        )

        XCTAssertFalse(workspaceDiffHasContent(zeroDiff))
        XCTAssertTrue(workspaceDiffHasContent(changedDiff))
    }

    func testSourceArtifactStemNormalizesImplementationAndTestFileNames() {
        XCTAssertEqual(sourceArtifactStem(from: "temperature_converter.py"), "temperature converter")
        XCTAssertEqual(sourceArtifactStem(from: "test_temperature_converter.py"), "temperature converter")
        XCTAssertEqual(sourceArtifactStem(from: "Sources/AuthModule-test.swift"), "AuthModule")
    }

    func testCompactRelativeTimeLabelMatchesMockupStyle() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(compactRelativeTimeLabel(from: now.addingTimeInterval(-2), now: now), "2s ago")
        XCTAssertEqual(compactRelativeTimeLabel(from: now.addingTimeInterval(-14 * 60), now: now), "14 min ago")
        XCTAssertEqual(compactRelativeTimeLabel(from: now.addingTimeInterval(-2 * 60 * 60), now: now), "2h ago")
        XCTAssertEqual(compactRelativeTimeLabel(from: now.addingTimeInterval(-25 * 60 * 60), now: now), "Yesterday")
        XCTAssertEqual(compactRelativeTimeLabel(from: now.addingTimeInterval(-3 * 24 * 60 * 60), now: now), "3d ago")
    }

    func testSidebarSessionIconNameMatchesMockupRecentRows() {
        XCTAssertEqual(sidebarSessionIconName(for: "Debug workflow: temperature converter", debugMode: true), "wrench.and.screwdriver")
        XCTAssertEqual(sidebarSessionIconName(for: "Refactor auth module", debugMode: false), "command")
        XCTAssertEqual(sidebarSessionIconName(for: "Add payment flow", debugMode: false), "plus.circle")
        XCTAssertEqual(sidebarSessionIconName(for: "Spike: data pipeline", debugMode: false), "arrow.triangle.2.circlepath.circle")
        XCTAssertEqual(sidebarSessionIconName(for: "API error investigation", debugMode: false), "exclamationmark.circle")
    }

    func testMockupFixturePreservesSidebarAndStateStripInputs() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let store = SessionStore(mockupFixture: true, referenceNow: now)

        XCTAssertTrue(store.usesStaticMockupFixture)
        XCTAssertEqual(store.connectionStatus, "Connected")
        XCTAssertEqual(store.visibleSessions.prefix(5).map(\.title), [
            "Debug workflow: temperature converter",
            "Refactor auth module",
            "Add payment flow",
            "Spike: data pipeline",
            "API error investigation"
        ])
        XCTAssertEqual(store.graph.nodes.count, 5)
        XCTAssertEqual(store.touchedWorkspaceFiles.count, 2)
        XCTAssertEqual(store.touchedWorkspaceFiles.map(\.path).compactMap(sourceArtifactStem).first, "temperature converter")
        XCTAssertEqual(store.transcript.last?.timestamp.timeIntervalSince(store.transcript.first?.timestamp ?? now), 768)
        XCTAssertEqual(compactRelativeTimeLabel(from: store.transcript.last?.timestamp ?? now, now: now), "2s ago")
    }

    func testMockupFixtureReselectDoesNotClearTranscript() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let store = SessionStore(mockupFixture: true, referenceNow: now)
        let initialTranscriptIds = store.transcript.map(\.id)

        store.selectSession(store.selectedSessionId)

        XCTAssertFalse(store.isLoadingSelection)
        XCTAssertEqual(store.transcript.map(\.id), initialTranscriptIds)
        XCTAssertEqual(store.connectionStatus, "Connected")
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

    func testTimelineHidesDenseRuntimeEventBursts() {
        let transcript = [
            item(id: "status-1", agentId: "qa", type: "agent.status", text: "Status: waiting", payload: ["status": .string("waiting")]),
            item(id: "mailbox", agentId: "qa", type: "actor.mailbox.enqueued", text: "message", payload: ["mailbox": .string("qa"), "messageType": .string("prompt")]),
            item(id: "scheduler", agentId: "qa", type: "scheduler.job.started", text: "started", payload: ["jobId": .string("job-1")]),
            item(id: "message", agentId: "qa", type: "agent.message", text: "QA finished")
        ]

        let window = timelineWindow(from: transcript, limit: 10)

        XCTAssertEqual(window.items.count, 1)
        guard case .message(let message, _) = window.items.first else {
            return XCTFail("Expected narrative messages to stay visible")
        }
        XCTAssertEqual(message.id, "message")
    }

    func testTimelineKeepsSingletonCompactHandoffEvents() {
        let transcript = [
            item(
                id: "handoff",
                agentId: "orchestrator",
                type: "handoff.created",
                text: "Handoff to implementor",
                payload: ["from": .string("orchestrator"), "to": .string("implementor")]
            ),
            item(id: "message", agentId: "implementor", type: "agent.message", text: "Started")
        ]

        let window = timelineWindow(from: transcript, limit: 10)

        guard case .compact(let handoff) = window.items.first else {
            return XCTFail("Expected the singleton handoff to remain visible as a compact event")
        }
        XCTAssertEqual(handoff.id, "handoff")
    }

    func testBranchingTimelineProjectionUsesFullMetadataForLaneCreation() throws {
        let start = Date(timeIntervalSince1970: 10)
        let later = Date(timeIntervalSince1970: 100)
        let metadata = [
            item(
                id: "handoff",
                agentId: "orchestrator",
                sender: "orchestrator",
                recipient: "implementor",
                type: "handoff.created",
                text: "Handoff",
                timestamp: start,
                payload: ["from": .string("orchestrator"), "to": .string("implementor")]
            ),
            item(id: "working", agentId: "implementor", type: "agent.status", text: "working", timestamp: start.addingTimeInterval(5), payload: ["status": .string("working")]),
            item(id: "done", agentId: "implementor", type: "agent.status", text: "done", timestamp: later, payload: ["status": .string("completed")])
        ]
        let visible = [
            item(id: "edit", agentId: "implementor", type: "workspace.file_touched", text: "main.py", timestamp: later, payload: ["path": .string("main.py")])
        ]

        let projection = BranchingTimelineProjection(
            graph: GraphState(sessionId: "session-1", workflowId: "wf", nodes: [], edges: []),
            metadataTranscript: metadata,
            visibleTranscript: visible
        )

        let implementor = try XCTUnwrap(projection.lanes.first { $0.id == "implementor" })
        XCTAssertEqual(implementor.createdAt, start)
        XCTAssertEqual(implementor.activeRanges.first?.start, start.addingTimeInterval(5))
        XCTAssertEqual(projection.events.map(\.id), ["edit"])
    }

    func testBranchingTimelineProjectionDropsBlankFallbackAgentIds() {
        let projection = BranchingTimelineProjection(
            graph: GraphState(sessionId: "session-1", workflowId: "wf", nodes: [], edges: []),
            metadataTranscript: [
                item(id: "blank", agentId: nil, sender: "", type: "agent.status", text: "blank", payload: ["status": .string("working")]),
                item(id: "real", agentId: "qa", sender: "", type: "agent.message", text: "QA finished")
            ],
            visibleTranscript: [
                item(id: "real", agentId: "qa", sender: "", type: "agent.message", text: "QA finished")
            ]
        )

        XCTAssertFalse(projection.lanes.contains { $0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        XCTAssertTrue(projection.lanes.contains { $0.id == "qa" })
    }

    func testBranchingTimelineProjectionKeepsStatusInLanesAndIcons() throws {
        let projection = BranchingTimelineProjection(
            graph: GraphState(sessionId: "session-1", workflowId: "wf", nodes: [], edges: []),
            metadataTranscript: [
                item(id: "working", agentId: "qa", type: "agent.status", text: "working", timestamp: Date(timeIntervalSince1970: 10), payload: ["status": .string("working")]),
                item(id: "completed", agentId: "qa", type: "agent.status", text: "completed", timestamp: Date(timeIntervalSince1970: 30), payload: ["status": .string("completed")]),
                item(id: "failed", agentId: "qa", type: "agent.status", text: "failed", timestamp: Date(timeIntervalSince1970: 40), payload: ["status": .string("failed")])
            ],
            visibleTranscript: [
                item(id: "working", agentId: "qa", type: "agent.status", text: "working", timestamp: Date(timeIntervalSince1970: 10), payload: ["status": .string("working")]),
                item(id: "completed", agentId: "qa", type: "agent.status", text: "completed", timestamp: Date(timeIntervalSince1970: 30), payload: ["status": .string("completed")]),
                item(id: "failed", agentId: "qa", type: "agent.status", text: "failed", timestamp: Date(timeIntervalSince1970: 40), payload: ["status": .string("failed")])
            ]
        )

        let qa = try XCTUnwrap(projection.lanes.first { $0.id == "qa" })
        XCTAssertEqual(qa.activeRanges.count, 1)
        XCTAssertEqual(qa.activeRanges.first?.start, Date(timeIntervalSince1970: 10))
        XCTAssertEqual(qa.activeRanges.first?.end, Date(timeIntervalSince1970: 30))
        XCTAssertEqual(projection.events.map(\.id), ["working", "completed", "failed"])
    }

    func testBranchingTimelineProjectionUsesSpecificIconsForRuntimeEvents() throws {
        let events = [
            item(id: "mail-in", agentId: "qa", type: "actor.mailbox.enqueued", text: "queued", payload: ["mailbox": .string("qa")]),
            item(id: "job-started", agentId: "qa", type: "scheduler.job.started", text: "started", payload: ["jobId": .string("job-1")]),
            item(id: "claimed", agentId: "qa", type: "workspace.file_claimed", text: "claimed"),
            item(id: "checkpoint", agentId: "qa", type: "workspace.review_checkpoint", text: "review"),
            item(id: "capability", agentId: "qa", type: "capability.checked", text: "checked")
        ]
        let projection = BranchingTimelineProjection(
            graph: GraphState(sessionId: "session-1", workflowId: "wf", nodes: [], edges: []),
            metadataTranscript: events,
            visibleTranscript: events
        )

        XCTAssertEqual(projection.events.map(\.systemImage), [
            "tray.and.arrow.down",
            "play.circle",
            "doc.badge.gearshape",
            "text.badge.checkmark",
            "checkmark.seal"
        ])
        XCTAssertFalse(projection.events.contains { $0.systemImage == "circle.fill" })
    }

    func testBranchingTimelineProjectionOnlyMarksFirstBranchAsCreation() throws {
        let projection = BranchingTimelineProjection(
            graph: GraphState(sessionId: "session-1", workflowId: "wf", nodes: [], edges: []),
            metadataTranscript: [
                item(id: "create-reviewer", agentId: "implementor", sender: "implementor", recipient: "reviewer", type: "handoff.created", text: "Create reviewer", timestamp: Date(timeIntervalSince1970: 10), payload: ["from": .string("implementor"), "to": .string("reviewer")]),
                item(id: "later-reviewer", agentId: "qa", sender: "qa", recipient: "reviewer", type: "handoff.created", text: "Ask reviewer again", timestamp: Date(timeIntervalSince1970: 40), payload: ["from": .string("qa"), "to": .string("reviewer")])
            ],
            visibleTranscript: [
                item(id: "create-reviewer", agentId: "implementor", sender: "implementor", recipient: "reviewer", type: "handoff.created", text: "Create reviewer", timestamp: Date(timeIntervalSince1970: 10), payload: ["from": .string("implementor"), "to": .string("reviewer")]),
                item(id: "later-reviewer", agentId: "qa", sender: "qa", recipient: "reviewer", type: "handoff.created", text: "Ask reviewer again", timestamp: Date(timeIntervalSince1970: 40), payload: ["from": .string("qa"), "to": .string("reviewer")])
            ]
        )

        let creation = try XCTUnwrap(projection.events.first { $0.id == "create-reviewer" })
        let later = try XCTUnwrap(projection.events.first { $0.id == "later-reviewer" })
        XCTAssertTrue(creation.isCreation)
        XCTAssertFalse(later.isCreation)
        XCTAssertEqual(later.systemImage, "arrow.right")
    }

    func testBranchingTimelineProjectionKeepsLinkAndEventOffsetsAligned() throws {
        let first = item(id: "review-message", agentId: "reviewer", sender: "reviewer", recipient: "orchestrator", type: "message.sent", text: "Review accepted", timestamp: Date(timeIntervalSince1970: 10), payload: ["from": .string("reviewer"), "to": .string("orchestrator")])
        let second = item(id: "qa-message", agentId: "qa", sender: "qa", recipient: "orchestrator", type: "message.sent", text: "QA passed", timestamp: Date(timeIntervalSince1970: 12), payload: ["from": .string("qa"), "to": .string("orchestrator")])
        let projection = BranchingTimelineProjection(
            graph: GraphState(sessionId: "session-1", workflowId: "wf", nodes: [], edges: []),
            metadataTranscript: [first, second],
            visibleTranscript: [first, second]
        )
        let eventOffsets = Dictionary(uniqueKeysWithValues: projection.events.map { ($0.id, $0.visualOffset) })

        for link in projection.links {
            XCTAssertEqual(link.visualOffset, eventOffsets[link.id])
        }
    }

    func testBranchingTimelineProjectionClampsStartBurstOffsetsIntoCanvas() {
        let timestamp = Date(timeIntervalSince1970: 10)
        let events = (0..<5).map { index in
            item(id: "burst-\(index)", agentId: "qa", type: "agent.message", text: "burst \(index)", timestamp: timestamp)
        }

        let projection = BranchingTimelineProjection(
            graph: GraphState(sessionId: "session-1", workflowId: "wf", nodes: [], edges: []),
            metadataTranscript: events,
            visibleTranscript: events
        )

        XCTAssertGreaterThanOrEqual(projection.events.map(\.visualOffset).min() ?? 0, -38)
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

    func testSchedulerRunProjectionCombinesLifecycleEvents() throws {
        let store = SessionStore()
        store.transcript = [
            item(
                id: "created",
                agentId: "implementor",
                type: "scheduler.job.created",
                text: "created",
                timestamp: Date(timeIntervalSince1970: 10),
                payload: [
                    "jobId": .string("job-1"),
                    "agentId": .string("implementor"),
                    "kind": .string("workflow-agent-turn"),
                    "prompt": .string("Build the CLI"),
                    "workflowInstanceId": .string("workflow-1")
                ]
            ),
            item(
                id: "started",
                agentId: "implementor",
                type: "scheduler.job.started",
                text: "started",
                timestamp: Date(timeIntervalSince1970: 20),
                payload: ["jobId": .string("job-1")]
            ),
            item(
                id: "completed",
                agentId: "implementor",
                type: "scheduler.job.completed",
                text: "completed",
                timestamp: Date(timeIntervalSince1970: 30),
                payload: ["jobId": .string("job-1"), "eventCount": .number(7)]
            )
        ]

        let run = try XCTUnwrap(store.schedulerRuns.first)

        XCTAssertEqual(run.jobId, "job-1")
        XCTAssertEqual(run.agentId, "implementor")
        XCTAssertEqual(run.kind, "workflow-agent-turn")
        XCTAssertEqual(run.status, "completed")
        XCTAssertEqual(run.prompt, "Build the CLI")
        XCTAssertEqual(run.workflowInstanceId, "workflow-1")
        XCTAssertEqual(run.eventCount, 7)
        XCTAssertEqual(run.startedAt, Date(timeIntervalSince1970: 20))
        XCTAssertEqual(run.finishedAt, Date(timeIntervalSince1970: 30))
        XCTAssertEqual(run.updatedAt, Date(timeIntervalSince1970: 30))
    }

    func testSchedulerRunProjectionPreservesFailureAndRetryReasons() throws {
        let store = SessionStore()
        store.transcript = [
            item(
                id: "failed-created",
                agentId: "qa",
                type: "scheduler.job.created",
                text: "created",
                timestamp: Date(timeIntervalSince1970: 10),
                payload: ["jobId": .string("job-failed"), "kind": .string("workflow-agent-turn"), "prompt": .string("Run checks")]
            ),
            item(
                id: "failed-started",
                agentId: "qa",
                type: "scheduler.job.started",
                text: "started",
                timestamp: Date(timeIntervalSince1970: 20),
                payload: ["jobId": .string("job-failed")]
            ),
            item(
                id: "failed-terminal",
                agentId: "qa",
                type: "scheduler.job.failed",
                text: "failed",
                timestamp: Date(timeIntervalSince1970: 30),
                payload: ["jobId": .string("job-failed"), "message": .string("pytest exited 1")]
            ),
            item(
                id: "retry-created",
                agentId: "implementor",
                type: "scheduler.job.created",
                text: "created",
                timestamp: Date(timeIntervalSince1970: 40),
                payload: ["jobId": .string("job-retry"), "kind": .string("agent-turn"), "prompt": .string("Implement")]
            ),
            item(
                id: "retry-recovered",
                agentId: "implementor",
                type: "scheduler.job.recovered",
                text: "recovered",
                timestamp: Date(timeIntervalSince1970: 50),
                payload: ["jobId": .string("job-retry"), "reason": .string("daemon restarted")]
            ),
            item(
                id: "retry-requested",
                agentId: "implementor",
                type: "scheduler.job.retry_requested",
                text: "retry",
                timestamp: Date(timeIntervalSince1970: 60),
                payload: ["jobId": .string("job-retry"), "reason": .string("user retried")]
            )
        ]

        let retry = try XCTUnwrap(store.schedulerRuns.first)
        let failed = try XCTUnwrap(store.schedulerRuns.dropFirst().first)

        XCTAssertEqual(retry.jobId, "job-retry")
        XCTAssertEqual(retry.status, "retry requested")
        XCTAssertEqual(retry.message, "user retried")
        XCTAssertEqual(retry.updatedAt, Date(timeIntervalSince1970: 60))
        XCTAssertEqual(failed.jobId, "job-failed")
        XCTAssertEqual(failed.status, "failed")
        XCTAssertEqual(failed.message, "pytest exited 1")
    }

    func testSchedulerRunProjectionDoesNotDowngradeTerminalStatusOnLateHeartbeat() throws {
        let store = SessionStore()
        store.transcript = [
            item(id: "created", agentId: "qa", type: "scheduler.job.created", text: "created", timestamp: Date(timeIntervalSince1970: 10), payload: ["jobId": .string("job-1")]),
            item(id: "failed", agentId: "qa", type: "scheduler.job.failed", text: "failed", timestamp: Date(timeIntervalSince1970: 20), payload: ["jobId": .string("job-1"), "message": .string("timed out")]),
            item(id: "heartbeat", agentId: "qa", type: "scheduler.job.heartbeat", text: "heartbeat", timestamp: Date(timeIntervalSince1970: 30), payload: ["jobId": .string("job-1")])
        ]

        let run = try XCTUnwrap(store.schedulerRuns.first)

        XCTAssertEqual(run.status, "failed")
        XCTAssertEqual(run.message, "timed out")
        XCTAssertEqual(run.updatedAt, Date(timeIntervalSince1970: 30))
    }

    private func item(
        id: String,
        sessionId: String = "session-1",
        agentId: String?,
        sender: String? = nil,
        recipient: String? = nil,
        type: String,
        text: String,
        timestamp: Date = Date(timeIntervalSince1970: 0),
        payload: [String: JSONValue] = [:],
        causationId: String? = nil
    ) -> TranscriptItem {
        TranscriptItem(
            id: id,
            sessionId: sessionId,
            agentId: agentId,
            sender: sender ?? agentId ?? "system",
            recipient: recipient,
            type: type,
            text: text,
            timestamp: timestamp,
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
