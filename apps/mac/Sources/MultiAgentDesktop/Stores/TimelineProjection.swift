enum TimelineItem: Identifiable {
    case message(TranscriptItem, isFinalOutput: Bool)
    case compact(TranscriptItem)
    case transition(TranscriptItem)
    case plan(TranscriptItem)
    case tool(call: TranscriptItem, result: TranscriptItem?)

    var id: String {
        switch self {
        case .message(let item, _), .compact(let item), .transition(let item), .plan(let item):
            return item.id
        case .tool(let call, _):
            return call.payload["callId"]?.stringValue ?? call.id
        }
    }

    var primaryAgentId: String? {
        switch self {
        case .message(let item, _), .compact(let item), .transition(let item), .plan(let item):
            return item.agentId ?? item.sender
        case .tool(let call, _):
            return call.agentId ?? call.sender
        }
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
    let finalOutputId = finalOrchestratorOutputId(in: transcript)

    for event in transcript {
        if event.type == "client.ack" {
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
            items.append(.tool(call: pending.call, result: event))
            pendingToolCalls.removeValue(forKey: callId)
            continue
        }
        if event.type == "plan.created" || event.type == "plan.instantiated" {
            items.append(.plan(event))
            continue
        }
        if (event.type == "handoff.created" || event.type == "message.sent") && event.sender != "user" {
            items.append(.transition(event))
            continue
        }
        if isMessageEvent(event) {
            items.append(.message(event, isFinalOutput: event.id == finalOutputId))
        } else {
            items.append(.compact(event))
        }
    }

    return items.compactMap { $0 }
}

private func finalOrchestratorOutputId(in transcript: [TranscriptItem]) -> String? {
    transcript.reversed().first { item in
        item.type == "agent.message" && (item.agentId == "orchestrator" || item.sender == "orchestrator")
    }?.id
}

private func isMessageEvent(_ item: TranscriptItem) -> Bool {
    if item.sender == "user" { return true }
    return item.type == "message" || item.type == "agent.message" || item.type == "error"
}
