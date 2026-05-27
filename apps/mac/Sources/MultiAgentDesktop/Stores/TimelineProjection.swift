import Foundation

enum TimelineItem: Identifiable {
    case message(TranscriptItem, isFinalOutput: Bool)
    case compact(TranscriptItem)
    case group(TimelineEventGroup)
    case transition(TranscriptItem)
    case plan(TranscriptItem)
    case tool(call: TranscriptItem, result: TranscriptItem?)

    var id: String {
        switch self {
        case .message(let item, _), .compact(let item), .transition(let item), .plan(let item):
            return item.id
        case .group(let group):
            return group.id
        case .tool(let call, _):
            return call.payload["callId"]?.stringValue ?? call.id
        }
    }

    var primaryAgentId: String? {
        switch self {
        case .message(let item, _), .compact(let item), .transition(let item), .plan(let item):
            return item.agentId ?? item.sender
        case .group(let group):
            return group.primaryAgentId
        case .tool(let call, _):
            return call.agentId ?? call.sender
        }
    }
}

struct TimelineEventGroup: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let events: [TranscriptItem]
    let isActionGroup: Bool

    var primaryAgentId: String? {
        events.first?.agentId ?? events.first?.sender
    }

    var timestamp: Date {
        events.last?.timestamp ?? Date()
    }
}

func timelineWindow(from transcript: [TranscriptItem], limit: Int) -> (items: [TimelineItem], isTruncated: Bool) {
    guard transcript.count > limit else {
        return (makeTimelineItems(from: transcript), false)
    }
    var tailCount = min(transcript.count, max(limit * 2, limit))
    var items: [TimelineItem] = []
    repeat {
        let windowEvents = backfilledToolWindow(from: transcript, tailCount: tailCount)
        items = makeTimelineItems(from: windowEvents)
        if items.count >= limit || tailCount == transcript.count {
            break
        }
        tailCount = min(transcript.count, tailCount * 2)
    } while true
    return (Array(items.suffix(limit)), tailCount < transcript.count || items.count > limit)
}

private func backfilledToolWindow(from transcript: [TranscriptItem], tailCount: Int) -> [TranscriptItem] {
    let startIndex = max(0, transcript.count - tailCount)
    let tail = transcript.enumerated().filter { $0.offset >= startIndex }
    let resultCallIds = Set(tail.compactMap { _, item in
        item.type == "agent.tool_result" ? item.payload["callId"]?.stringValue : nil
    })
    let tailCallIds = Set(tail.compactMap { _, item in
        item.type == "agent.tool_call" ? item.payload["callId"]?.stringValue : nil
    })
    let missingCallIds = resultCallIds.subtracting(tailCallIds)
    guard !missingCallIds.isEmpty else {
        return tail.map(\.element)
    }
    var backfilled: [(offset: Int, element: TranscriptItem)] = []
    var foundCallIds = Set<String>()
    for (offset, item) in transcript.enumerated().reversed() where offset < startIndex {
        guard item.type == "agent.tool_call",
              let callId = item.payload["callId"]?.stringValue,
              missingCallIds.contains(callId),
              !foundCallIds.contains(callId) else {
            continue
        }
        backfilled.append((offset, item))
        foundCallIds.insert(callId)
        if foundCallIds.count == missingCallIds.count {
            break
        }
    }
    return (backfilled + tail)
        .sorted { $0.offset < $1.offset }
        .map(\.element)
}

private func makeTimelineItems(from transcript: [TranscriptItem]) -> [TimelineItem] {
    var items: [TimelineItem?] = []
    var pendingToolCalls: [String: (index: Int, call: TranscriptItem)] = [:]
    var seenNarrativeMessages = Set<String>()
    let finalOutputId = finalOrchestratorOutputId(in: transcript)

    for event in transcript {
        if event.type == "client.ack" {
            continue
        }
        if event.type == "agent.tool_call",
           lowSignalToolName(event.payload["toolName"]?.stringValue) {
            continue
        }
        if event.type == "agent.tool_result",
           lowSignalToolName(event.payload["toolName"]?.stringValue) {
            continue
        }
        if event.type == "agent.tool_call", let callId = event.payload["callId"]?.stringValue {
            pendingToolCalls[callId] = (items.count, event)
            items.append(.tool(call: event, result: nil))
            continue
        }
        if event.type == "agent.tool_result",
           let callId = event.payload["callId"]?.stringValue,
           let pending = pendingToolCalls[callId] {
            items[pending.index] = nil
            if lowSignalToolPair(call: pending.call, result: event) {
                pendingToolCalls.removeValue(forKey: callId)
                continue
            }
            items.append(.tool(call: pending.call, result: event))
            pendingToolCalls.removeValue(forKey: callId)
            continue
        }
        if event.type == "plan.instantiated" {
            continue
        }
        if event.type == "plan.created" {
            items.append(.plan(event))
            continue
        }
        if lowSignalMessage(event) {
            continue
        }
        if (event.type == "handoff.created" || event.type == "message.sent") && event.sender != "user" {
            items.append(.compact(event))
            continue
        }
        if isMessageEvent(event) {
            if event.type == "agent.message" {
                let key = "\(event.sender)|\(event.text)"
                if seenNarrativeMessages.contains(key) {
                    continue
                }
                seenNarrativeMessages.insert(key)
            }
            items.append(.message(event, isFinalOutput: event.id == finalOutputId))
        } else if shouldShowSingleCompactEvent(event) {
            items.append(.compact(event))
        }
    }

    return groupConsecutiveToolActions(groupCompactBursts(items.compactMap { $0 }))
}

private func finalOrchestratorOutputId(in transcript: [TranscriptItem]) -> String? {
    transcript.reversed().first { item in
        item.type == "agent.message" && (item.agentId == "orchestrator" || item.sender == "orchestrator")
    }?.id
}

private func isMessageEvent(_ item: TranscriptItem) -> Bool {
    if item.sender == "user" {
        return item.type == "message" || item.type == "message.sent"
    }
    return item.type == "message" || item.type == "agent.message" || item.type == "error"
}

private func shouldShowSingleCompactEvent(_ item: TranscriptItem) -> Bool {
    switch item.type {
    case "message.skipped", "workflow.stopped":
        return true
    default:
        return false
    }
}

private func groupCompactBursts(_ items: [TimelineItem]) -> [TimelineItem] {
    var grouped: [TimelineItem] = []
    var compactBuffer: [TranscriptItem] = []

    func flushCompactBuffer() {
        guard !compactBuffer.isEmpty else { return }
        if compactBuffer.count >= 2 {
            let group = makeGroup(from: compactBuffer)
            if group.isActionGroup {
                grouped.append(.group(group))
            }
        }
        compactBuffer.removeAll()
    }

    for item in items {
        if case .compact(let event) = item, isGroupableCompactEvent(event) {
            compactBuffer.append(event)
        } else {
            flushCompactBuffer()
            grouped.append(item)
        }
    }
    flushCompactBuffer()
    return grouped
}

private func groupConsecutiveToolActions(_ items: [TimelineItem]) -> [TimelineItem] {
    var grouped: [TimelineItem] = []
    var buffer: [(call: TranscriptItem, result: TranscriptItem?)] = []
    var bufferKind: String?

    func flushBuffer() {
        guard !buffer.isEmpty else { return }
        defer {
            buffer.removeAll()
            bufferKind = nil
        }
        guard buffer.count >= 2, let bufferKind else {
            for pair in buffer {
                grouped.append(.tool(call: pair.call, result: pair.result))
            }
            return
        }
        let events = buffer.map { $0.result ?? $0.call }
        grouped.append(.group(TimelineEventGroup(
            id: "tool-group-\(events.first?.id ?? "start")-\(events.last?.id ?? "end")",
            title: "\(buffer.count) \(bufferKind)",
            subtitle: toolGroupSubtitle(for: buffer),
            events: events,
            isActionGroup: true
        )))
    }

    for item in items {
        if case .tool(let call, let result) = item,
           let kind = toolActionGroupKind(call: call, result: result) {
            if bufferKind == nil || bufferKind == kind {
                buffer.append((call, result))
                bufferKind = kind
            } else {
                flushBuffer()
                buffer.append((call, result))
                bufferKind = kind
            }
        } else {
            flushBuffer()
            grouped.append(item)
        }
    }
    flushBuffer()
    return grouped
}

private func toolActionGroupKind(call: TranscriptItem, result: TranscriptItem?) -> String? {
    guard result != nil else { return nil }
    switch call.payload["toolName"]?.stringValue {
    case "workspace.write_file":
        return "file edits"
    default:
        return nil
    }
}

private func toolGroupSubtitle(for pairs: [(call: TranscriptItem, result: TranscriptItem?)]) -> String {
    pairs.compactMap { pair in
        guard let result = pair.result else { return nil }
        if let path = result.payload["path"]?.stringValue,
           let stats = result.payload["diffStats"]?.objectValue {
            let additions = Int(stats["additions"]?.numberValue ?? 0)
            let deletions = Int(stats["deletions"]?.numberValue ?? 0)
            return "\(path) +\(additions) -\(deletions)"
        }
        return result.payload["path"]?.stringValue
    }
    .prefix(2)
    .joined(separator: " · ")
}

private func makeGroup(from events: [TranscriptItem]) -> TimelineEventGroup {
    let agents = Array(Set(events.map { $0.agentId ?? $0.sender })).sorted()
    let agentSummary: String
    if agents.count <= 2 {
        agentSummary = agents.joined(separator: ", ")
    } else {
        agentSummary = "\(agents.prefix(2).joined(separator: ", ")) +\(agents.count - 2)"
    }
    let categories = eventGroupCategories(for: events)
    let title = categories == "action" ? "\(events.count) actions" : "\(events.count) \(categories) events"
    let subtitle = agentSummary.isEmpty ? "Low-level session activity" : "Low-level activity from \(agentSummary)"
    return TimelineEventGroup(
        id: "group-\(events.first?.id ?? "start")-\(events.last?.id ?? "end")",
        title: title,
        subtitle: subtitle,
        events: events,
        isActionGroup: categories == "action"
    )
}

private func eventGroupCategories(for events: [TranscriptItem]) -> String {
    let categories = Set(events.map { compactEventCategory($0) })
    if categories.count == 1 {
        return categories.first ?? "low-level"
    }
    if categories.contains("status") && categories.contains("scheduler") {
        return "status and scheduler"
    }
    if categories.contains("mailbox") {
        return "mailbox and status"
    }
    if categories.contains("workspace") || categories.contains("tool") || categories.contains("routing") {
        return "action"
    }
    return "low-level"
}

private func compactEventCategory(_ item: TranscriptItem) -> String {
    if item.type == "agent.status" { return "status" }
    if item.type == "session.created" || item.type == "agent.created" || item.type == "workflow.instantiated" || item.type == "graph.updated" { return "lifecycle" }
    if item.type.hasPrefix("scheduler.job.") { return "scheduler" }
    if item.type.hasPrefix("actor.mailbox.") { return "mailbox" }
    if item.type.hasPrefix("completion.criterion.") { return "criteria" }
    if item.type.hasPrefix("workspace.") { return "workspace" }
    if item.type == "agent.reasoning" { return "reasoning" }
    if item.type == "agent.message" { return "message" }
    if item.type == "agent.stopped" { return "status" }
    if item.type == "agent.stop_blocked" { return "status" }
    if item.type == "agent.tool_result" { return "tool" }
    if item.type == "handoff.created" || item.type == "message.sent" { return "routing" }
    if item.type == "capability.checked" { return "capability" }
    return "low-level"
}

private func isGroupableCompactEvent(_ item: TranscriptItem) -> Bool {
    item.type == "agent.status"
        || item.type == "session.created"
        || item.type == "agent.created"
        || item.type == "workflow.instantiated"
        || item.type == "graph.updated"
        || item.type.hasPrefix("scheduler.job.")
        || item.type.hasPrefix("actor.mailbox.")
        || item.type.hasPrefix("completion.criterion.")
        || item.type == "capability.checked"
        || item.type == "agent.reasoning"
        || lowSignalMessage(item)
        || item.type == "agent.stopped"
        || item.type == "agent.stop_blocked"
        || (item.type == "agent.tool_result" && lowSignalToolName(item.payload["toolName"]?.stringValue))
        || (item.type == "agent.tool_result" && zeroDiffWorkspaceWrite(item))
        || item.type == "handoff.created"
        || item.type == "message.sent"
        || item.type == "workspace.file_claimed"
        || item.type == "workspace.file_touched"
        || item.type == "workspace.review_checkpoint"
}

private func lowSignalMessage(_ item: TranscriptItem) -> Bool {
    guard item.type == "agent.message" else { return false }
    if item.text.hasPrefix("Debug QA: acceptance checks completed") {
        return item.sender != "orchestrator"
    }
    return item.text.hasPrefix("Orchestrator evaluated stop criteria:")
}

private func lowSignalToolPair(call: TranscriptItem, result: TranscriptItem) -> Bool {
    lowSignalToolName(call.payload["toolName"]?.stringValue)
        || zeroDiffWorkspaceWrite(result)
}

private func lowSignalToolName(_ toolName: String?) -> Bool {
    switch toolName {
    case "debug.inspect_goal":
        return true
    default:
        return false
    }
}

private func zeroDiffWorkspaceWrite(_ item: TranscriptItem) -> Bool {
    guard item.payload["toolName"]?.stringValue == "workspace.write_file",
          let stats = item.payload["diffStats"]?.objectValue else { return false }
    return Int(stats["additions"]?.numberValue ?? 0) == 0
        && Int(stats["deletions"]?.numberValue ?? 0) == 0
}
