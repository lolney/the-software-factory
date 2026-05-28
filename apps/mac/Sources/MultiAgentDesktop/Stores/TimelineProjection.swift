import Foundation
import CoreGraphics

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
        } else {
            grouped.append(contentsOf: compactBuffer.map(TimelineItem.compact))
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

func timelineCompactTitle(for item: TranscriptItem) -> String {
    switch item.type {
    case "agent.created":
        return "\(item.sender) created"
    case "agent.status":
        return "\(item.sender) \(item.payload["status"]?.stringValue ?? item.text.replacingOccurrences(of: "Status: ", with: ""))"
    case "agent.reasoning":
        return "\(item.sender) reasoning"
    case "agent.tool_result":
        let tool = item.payload["toolName"]?.stringValue ?? "tool"
        let status = item.payload["status"]?.stringValue ?? "done"
        return "\(tool) \(status)"
    case "handoff.created":
        return "\(item.sender) handed off to \(item.recipient ?? "agent")"
    case "actor.mailbox.enqueued":
        return "\(item.payload["mailbox"]?.stringValue ?? item.sender) mailbox received \(item.payload["messageType"]?.stringValue ?? "message")"
    case "actor.mailbox.dequeued":
        return "\(item.payload["mailbox"]?.stringValue ?? item.sender) mailbox dequeued message"
    case "workflow.instantiated":
        return "\(item.sender) instantiated workflow"
    case "workflow.completed":
        return item.payload["message"]?.stringValue ?? "workflow completed"
    case "workflow.stopped":
        return "workflow stopped: \(item.payload["reason"]?.stringValue ?? "no reason provided")"
    case "agent.stopped":
        return "\(item.sender) stopped: \(item.payload["reason"]?.stringValue ?? "done")"
    case "agent.stop_blocked":
        let dependencies = arrayValue(item.payload["unresolvedDependencies"])?.compactMap(\.stringValue).joined(separator: ", ") ?? "dependencies"
        let childWorkflows = arrayValue(item.payload["activeChildWorkflows"])?.compactMap(\.stringValue).joined(separator: ", ")
        if let childWorkflows, !childWorkflows.isEmpty {
            return "\(item.sender) stop blocked by child workflow \(childWorkflows)"
        }
        return "\(item.sender) stop blocked by \(dependencies.isEmpty ? "completion gates" : dependencies)"
    case "message.skipped":
        let target = item.payload["to"]?.stringValue ?? item.recipient ?? "agent"
        let status = item.payload["targetStatus"]?.stringValue
        let reason = item.payload["reason"]?.stringValue ?? "target unavailable"
        if let status {
            return "message to \(target) skipped (\(status)): \(reason)"
        }
        return "message to \(target) skipped: \(reason)"
    case "plan.created", "plan.instantiated", "graph.updated":
        return item.text
    default:
        return "\(item.sender) \(item.type)"
    }
}


struct BranchingTimelineProjection {
    let lanes: [BranchingTimelineLane]
    let events: [BranchingTimelineEvent]
    let links: [BranchingTimelineLink]
    let startDate: Date
    let endDate: Date

    init(graph: GraphState, metadataTranscript: [TranscriptItem], visibleTranscript: [TranscriptItem]) {
        let metadataEvents = metadataTranscript.filter { $0.type != "client.ack" }
        let visibleEvents = visibleTranscript.filter { $0.type != "client.ack" }
        let dates = visibleEvents.map(\.timestamp)
        let firstDate = dates.min() ?? Date()
        let lastDate = dates.max() ?? firstDate.addingTimeInterval(60)
        let nodeIds = graph.nodes.map(\.id)
        let fallbackAgentIds = metadataEvents.flatMap { event in
            [event.agentId, event.sender, event.recipient, event.payload["from"]?.stringValue, event.payload["to"]?.stringValue]
        }
        .compactMap(Self.normalizedAgentId)
        .filter { $0 != "user" && $0 != "system" }
        var seenAgentIds = Set<String>()
        let fallbackIds = fallbackAgentIds.filter { seenAgentIds.insert($0).inserted }
        let orderedIds = nodeIds + fallbackIds.filter { !nodeIds.contains($0) }
        let ids = orderedIds.isEmpty ? ["orchestrator"] : orderedIds

        var creationDates = Dictionary(uniqueKeysWithValues: ids.map { ($0, $0 == "orchestrator" ? firstDate : lastDate) })
        for event in metadataEvents {
            if event.type == "handoff.created",
               let target = event.payload["to"]?.stringValue ?? event.recipient,
               creationDates[target] == nil || event.timestamp < (creationDates[target] ?? .distantFuture) {
                creationDates[target] = event.timestamp
            }
            if event.type == "agent.created",
               let agentId = event.agentId,
               creationDates[agentId] == nil || event.timestamp < (creationDates[agentId] ?? .distantFuture) {
                creationDates[agentId] = event.timestamp
            }
        }
        for id in ids where creationDates[id] == nil || creationDates[id] == lastDate {
            if let firstAgentEvent = metadataEvents.first(where: { Self.agentId(for: $0) == id }) {
                creationDates[id] = firstAgentEvent.timestamp
            }
        }

        let indexedIds = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
        self.lanes = ids.enumerated().map { index, id in
            let node = graph.nodes.first { $0.id == id }
            return BranchingTimelineLane(
                id: id,
                label: node?.label ?? id,
                index: index,
                createdAt: creationDates[id] ?? firstDate,
                activeRanges: BranchingTimelineProjection.activeRanges(for: id, events: metadataEvents, fallbackEnd: lastDate)
            )
        }
        let projectedEvents: [BranchingTimelineEvent] = visibleEvents.compactMap { event in
            guard Self.shouldRenderIcon(for: event) else { return nil }
            guard let laneId = Self.agentId(for: event),
                  let laneIndex = indexedIds[laneId] else { return nil }
            let isCreation = Self.isCreationEvent(event, laneId: laneId, creationDates: creationDates)
            return BranchingTimelineEvent(
                id: event.id,
                agentId: laneId,
                laneIndex: laneIndex,
                timestamp: event.timestamp,
                systemImage: Self.systemImage(for: event, isCreation: isCreation),
                title: Self.title(for: event),
                detail: event.text,
                isCreation: isCreation,
                linkKind: event.type == "message.sent" ? .message : (event.type == "handoff.created" ? .handoff : nil),
                isStatus: event.type == "agent.status",
                visualOffset: 0
            )
        }
        let projectionEndDate = max(lastDate, firstDate.addingTimeInterval(60))
        let adjustedEvents = Self.applyCollisionOffsets(to: projectedEvents, startDate: firstDate, endDate: projectionEndDate)
        let eventOffsets = Dictionary(uniqueKeysWithValues: adjustedEvents.map { ($0.id, $0.visualOffset) })
        self.events = adjustedEvents
        self.links = visibleEvents.compactMap { event in
            guard (event.type == "handoff.created" || event.type == "message.sent"),
                  let from = event.payload["from"]?.stringValue ?? (event.sender.isEmpty ? nil : event.sender),
                  let to = event.payload["to"]?.stringValue ?? event.recipient,
                  let fromIndex = indexedIds[from],
                  let toIndex = indexedIds[to] else { return nil }
            return BranchingTimelineLink(
                id: event.id,
                fromAgentId: from,
                toAgentId: to,
                fromLaneIndex: fromIndex,
                toLaneIndex: toIndex,
                timestamp: event.timestamp,
                kind: event.type == "handoff.created" ? .handoff : .message,
                visualOffset: eventOffsets[event.id] ?? 0
            )
        }
        self.startDate = firstDate
        self.endDate = projectionEndDate
    }

    private static func normalizedAgentId(_ id: String?) -> String? {
        guard let value = id?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func shouldRenderIcon(for event: TranscriptItem) -> Bool {
        return true
    }

    private static func isCreationEvent(_ event: TranscriptItem, laneId: String, creationDates: [String: Date]) -> Bool {
        guard event.type == "agent.created" || event.type == "handoff.created",
              let createdAt = creationDates[laneId] else {
            return false
        }
        return abs(event.timestamp.timeIntervalSince(createdAt)) < 0.001
    }

    private static func activeRanges(for agentId: String, events: [TranscriptItem], fallbackEnd: Date) -> [BranchingTimelineActiveRange] {
        let statusEvents = events
            .filter { $0.agentId == agentId && $0.type == "agent.status" }
            .sorted { $0.timestamp < $1.timestamp }
        var ranges: [BranchingTimelineActiveRange] = []
        var activeStart: Date?
        for event in statusEvents {
            let status = event.payload["status"]?.stringValue ?? ""
            if status == "working" {
                activeStart = activeStart ?? event.timestamp
            } else if let start = activeStart {
                ranges.append(BranchingTimelineActiveRange(start: start, end: max(event.timestamp, start.addingTimeInterval(1))))
                activeStart = nil
            }
        }
        if let activeStart {
            ranges.append(BranchingTimelineActiveRange(start: activeStart, end: max(fallbackEnd, activeStart.addingTimeInterval(1))))
        }
        return ranges
    }

    private static func applyCollisionOffsets(to events: [BranchingTimelineEvent], startDate: Date, endDate: Date) -> [BranchingTimelineEvent] {
        var adjusted = events
        let canvasHeight = max(540, CGFloat(max(events.count, 10)) * 38)
        let groupedIndexes = Dictionary(grouping: adjusted.indices, by: { adjusted[$0].laneIndex })
        for indexes in groupedIndexes.values {
            let sortedIndexes = indexes.sorted { adjusted[$0].timestamp < adjusted[$1].timestamp }
            var cluster: [Int] = []

            func flushCluster() {
                guard cluster.count > 1 else {
                    if let index = cluster.first {
                        adjusted[index].visualOffset = 0
                    }
                    cluster.removeAll()
                    return
                }
                for (position, index) in cluster.enumerated() {
                    let midpoint = CGFloat(cluster.count - 1) / 2
                    let offset = (CGFloat(position) - midpoint) * 26
                    adjusted[index].visualOffset = clampedVisualOffset(
                        offset,
                        for: adjusted[index].timestamp,
                        startDate: startDate,
                        endDate: endDate,
                        canvasHeight: canvasHeight
                    )
                }
                cluster.removeAll()
            }

            for index in sortedIndexes {
                if let lastIndex = cluster.last,
                   adjusted[index].timestamp.timeIntervalSince(adjusted[lastIndex].timestamp) > 24 {
                    flushCluster()
                }
                cluster.append(index)
            }
            flushCluster()
        }
        return adjusted
    }

    private static func clampedVisualOffset(_ offset: CGFloat, for timestamp: Date, startDate: Date, endDate: Date, canvasHeight: CGFloat) -> CGFloat {
        let span = max(1, endDate.timeIntervalSince(startDate))
        let topPadding: CGFloat = 54
        let bottomPadding: CGFloat = 34
        let progress = max(0, min(1, timestamp.timeIntervalSince(startDate) / span))
        let y = topPadding + (canvasHeight - topPadding - bottomPadding) * progress
        let minimumCenterY: CGFloat = 16
        let maximumCenterY = canvasHeight - 16
        return min(max(offset, minimumCenterY - y), maximumCenterY - y)
    }

    private static func agentId(for event: TranscriptItem) -> String? {
        if event.type == "handoff.created" || event.type == "message.sent" {
            return event.payload["to"]?.stringValue ?? event.recipient
        }
        if event.sender == "user" {
            return event.recipient ?? "orchestrator"
        }
        return event.agentId ?? (event.sender.isEmpty ? nil : event.sender)
    }

    private static func systemImage(for event: TranscriptItem, isCreation: Bool) -> String {
        switch event.type {
        case "agent.created":
            return isCreation ? "plus" : "circle"
        case "handoff.created":
            return isCreation ? "plus" : "arrow.right"
        case "message.sent", "agent.message", "message":
            return "envelope.fill"
        case "plan.created", "plan.instantiated":
            return "checklist"
        case "workspace.file_touched":
            return "pencil"
        case "workspace.file_claimed":
            return "doc.badge.gearshape"
        case "workspace.review_checkpoint":
            return "text.badge.checkmark"
        case "workspace.conflict_detected":
            return "exclamationmark.triangle"
        case "agent.tool_call":
            return actionIcon(for: event)
        case "agent.tool_result":
            return actionIcon(for: event)
        case "actor.mailbox.enqueued":
            return "tray.and.arrow.down"
        case "actor.mailbox.dequeued":
            return "tray.and.arrow.up"
        case "scheduler.job.created":
            return "calendar.badge.plus"
        case "scheduler.job.started":
            return "play.circle"
        case "scheduler.job.heartbeat":
            return "waveform.path.ecg"
        case "scheduler.job.completed":
            return "checkmark.circle"
        case "scheduler.job.failed":
            return "xmark.circle"
        case "scheduler.job.recovered", "scheduler.job.retry_requested":
            return "arrow.clockwise.circle"
        case "capability.checked":
            return "checkmark.seal"
        case "agent.status":
            switch event.payload["status"]?.stringValue {
            case "working": return "bolt.fill"
            case "waiting", "paused": return "clock"
            case "completed": return "checkmark"
            case "failed": return "xmark"
            default: return "circle"
            }
        case "workflow.completed", "workflow.stopped", "agent.stopped":
            return "checkmark"
        case "error":
            return "exclamationmark.triangle.fill"
        default:
            return "circle.fill"
        }
    }

    private static func actionIcon(for event: TranscriptItem) -> String {
        let haystack = [
            event.payload["toolName"]?.stringValue,
            event.payload["path"]?.stringValue,
            event.text
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()
        if haystack.contains("test") { return "checklist.checked" }
        if haystack.contains("command") || haystack.contains("terminal") || haystack.contains("shell") || haystack.contains("python") {
            return "terminal"
        }
        if haystack.contains("review") || haystack.contains("comment") {
            return "text.bubble"
        }
        if haystack.contains("mail") || haystack.contains("message") {
            return "envelope.fill"
        }
        if haystack.contains("file") || haystack.contains("edit") || haystack.contains(".swift") || haystack.contains(".py") {
            return "pencil"
        }
        return "wrench.and.screwdriver"
    }

    private static func title(for event: TranscriptItem) -> String {
        switch event.type {
        case "handoff.created":
            return "Handoff to \(event.payload["to"]?.stringValue ?? event.recipient ?? "agent")"
        case "message.sent":
            return "Message to \(event.payload["to"]?.stringValue ?? event.recipient ?? "agent")"
        case "workspace.file_touched":
            return "Edited \(event.payload["path"]?.stringValue ?? "file")"
        default:
            return timelineCompactTitle(for: event)
        }
    }
}

private func arrayValue(_ value: JSONValue?) -> [JSONValue]? {
    value?.arrayValue
}

struct BranchingTimelineLane: Identifiable {
    let id: String
    let label: String
    let index: Int
    let createdAt: Date
    let activeRanges: [BranchingTimelineActiveRange]
}

struct BranchingTimelineActiveRange {
    let start: Date
    let end: Date
}

struct BranchingTimelineEvent: Identifiable {
    let id: String
    let agentId: String
    let laneIndex: Int
    let timestamp: Date
    let systemImage: String
    let title: String
    let detail: String
    let isCreation: Bool
    let linkKind: BranchingTimelineLinkKind?
    let isStatus: Bool
    var visualOffset: CGFloat

    var helpText: String {
        let detailText = detail.isEmpty ? title : detail
        return "\(title) - \(detailText)"
    }
}

enum BranchingTimelineLinkKind: Hashable {
    case handoff
    case message
}

struct BranchingTimelineLink: Identifiable {
    let id: String
    let fromAgentId: String
    let toAgentId: String
    let fromLaneIndex: Int
    let toLaneIndex: Int
    let timestamp: Date
    let kind: BranchingTimelineLinkKind
    var visualOffset: CGFloat
}
