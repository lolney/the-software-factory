import SwiftUI

struct OrchestratorChatView: View {
    @Bindable var store: SessionStore

    private var timelineItems: [TimelineItem] {
        makeTimelineItems(from: store.filteredTranscript)
    }

    private var lastTranscriptEventId: String? {
        store.filteredTranscript.last?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(store.transcriptFilterLabel)
                    .font(.headline)
                if store.isTranscriptFiltered {
                    Text("filtered transcript")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        store.selectAgent(nil)
                    } label: {
                        Label("All Agents", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                Spacer()
                Text(store.connectionStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            if store.isLoadingSelection {
                ProgressView("Loading session...")
                    .controlSize(.small)
                    .padding()
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if timelineItems.isEmpty {
                            Text(store.isTranscriptFiltered ? "No transcript events for this agent yet." : "No transcript events yet.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 24)
                        } else {
                            ForEach(timelineItems) { item in
                                TimelineRow(item: item, color: color(for: item.primaryAgentId))
                                    .id(item.id)
                            }
                        }
                    }
                    .padding()
                }
                .onChange(of: timelineItems.count) { _, _ in
                    if let last = timelineItems.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onChange(of: lastTranscriptEventId) { _, _ in
                    if let last = timelineItems.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func color(for agentId: String?) -> Color {
        guard let agentId else { return .secondary }
        if let node = store.graph.nodes.first(where: { $0.id == agentId || $0.label == agentId }) {
            return Color(hex: node.colorHex)
        }
        if let role = store.roles.first(where: { $0.id == agentId || $0.name == agentId }) {
            return Color(hex: role.color)
        }
        if agentId == "user" { return .accentColor }
        return .secondary
    }
}

private enum TimelineItem: Identifiable {
    case message(TranscriptItem, isFinalOutput: Bool)
    case compact(TranscriptItem)
    case tool(call: TranscriptItem, result: TranscriptItem?)

    var id: String {
        switch self {
        case .message(let item, _), .compact(let item):
            return item.id
        case .tool(let call, _):
            return call.payload["callId"]?.stringValue ?? call.id
        }
    }

    var primaryAgentId: String? {
        switch self {
        case .message(let item, _), .compact(let item):
            return item.agentId ?? item.sender
        case .tool(let call, _):
            return call.agentId ?? call.sender
        }
    }
}

private struct TimelineRow: View {
    let item: TimelineItem
    let color: Color
    @State private var expanded = false

    var body: some View {
        switch item {
        case .message(let message, let isFinalOutput):
            MessageRow(item: message, color: color, isFinalOutput: isFinalOutput)
        case .compact(let compact):
            CompactEventRow(item: compact, color: color)
        case .tool(let call, let result):
            ToolEventRow(call: call, result: result, color: color, expanded: $expanded)
        }
    }
}

private struct MessageRow: View {
    let item: TranscriptItem
    let color: Color
    let isFinalOutput: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TimelineHeader(item: item, isFinalOutput: isFinalOutput)
            Text(item.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: 560, alignment: .leading)
        .background(color.opacity(item.sender == "user" ? 0.18 : 0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(color)
                .frame(width: 3)
        }
    }
}

private struct CompactEventRow: View {
    let item: TranscriptItem
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color.opacity(0.75))
                .frame(width: 6, height: 6)
            Text(compactTitle(for: item))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(item.timestamp, style: .time)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 4)
    }

    private func compactTitle(for item: TranscriptItem) -> String {
        switch item.type {
        case "agent.created":
            return "\(item.sender) created"
        case "agent.status":
            return "\(item.sender) \(item.payload["status"]?.stringValue ?? item.text.replacingOccurrences(of: "Status: ", with: ""))"
        case "handoff.created":
            return "\(item.sender) handed off to \(item.recipient ?? "agent")"
        case "workflow.instantiated":
            return "\(item.sender) instantiated workflow"
        case "plan.created", "plan.instantiated", "graph.updated":
            return item.text
        default:
            return "\(item.sender) \(item.type)"
        }
    }
}

private struct ToolEventRow: View {
    let call: TranscriptItem
    let result: TranscriptItem?
    let color: Color
    @Binding var expanded: Bool

    private var toolName: String {
        call.payload["toolName"]?.stringValue ?? "tool"
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                if let input = call.payload["input"] {
                    ToolPayloadBlock(title: "Input", value: input)
                }
                if let output = result?.payload["output"] {
                    ToolPayloadBlock(title: "Result", value: output)
                }
            }
            .padding(.top, 6)
            .padding(.leading, 20)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: result == nil ? "hammer" : "checkmark.circle")
                    .foregroundStyle(color)
                    .frame(width: 14)
                Text(toolName)
                    .font(.callout.weight(.medium))
                if let result {
                    Text(shortResult(result))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("running")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(call.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .disclosureGroupStyle(.automatic)
        .padding(.horizontal, 4)
    }

    private func shortResult(_ result: TranscriptItem) -> String {
        guard let output = result.payload["output"]?.stringValue else { return "completed" }
        return output.split(separator: "\n").first.map(String.init) ?? "completed"
    }
}

private struct ToolPayloadBlock: View {
    let title: String
    let value: JSONValue

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(render(value))
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func render(_ value: JSONValue) -> String {
        switch value {
        case .string(let string):
            return string
        case .number(let number):
            return String(number)
        case .bool(let bool):
            return String(bool)
        case .null:
            return "null"
        case .array(let values):
            return values.map(render).joined(separator: "\n")
        case .object(let object):
            return object.map { "\($0.key): \(render($0.value))" }.sorted().joined(separator: "\n")
        }
    }
}

private struct TimelineHeader: View {
    let item: TranscriptItem
    let isFinalOutput: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(item.sender)
                .font(.caption.weight(.semibold))
            if let recipient = item.recipient {
                Text("-> \(recipient)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(label(for: item))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(item.timestamp, style: .time)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func label(for item: TranscriptItem) -> String {
        if item.sender == "user" { return "prompt" }
        if isFinalOutput { return "final output" }
        return item.type
    }
}

private func makeTimelineItems(from transcript: [TranscriptItem]) -> [TimelineItem] {
    var items: [TimelineItem] = []
    var pendingToolCalls: [String: (index: Int, call: TranscriptItem)] = [:]
    let finalOutputId = finalOrchestratorOutputId(in: transcript)

    for event in transcript {
        if event.type == "agent.tool_call", let callId = event.payload["callId"]?.stringValue {
            pendingToolCalls[callId] = (items.count, event)
            items.append(.tool(call: event, result: nil))
            continue
        }
        if event.type == "agent.tool_result",
           let callId = event.payload["callId"]?.stringValue,
           let pending = pendingToolCalls[callId] {
            items[pending.index] = .tool(call: pending.call, result: event)
            pendingToolCalls.removeValue(forKey: callId)
            continue
        }
        if isMessageEvent(event) {
            items.append(.message(event, isFinalOutput: event.id == finalOutputId))
        } else {
            items.append(.compact(event))
        }
    }

    return items
}

private func finalOrchestratorOutputId(in transcript: [TranscriptItem]) -> String? {
    transcript.reversed().first { item in
        item.type == "agent.message" && (item.agentId == "orchestrator" || item.sender == "orchestrator")
    }?.id
}

private func isMessageEvent(_ item: TranscriptItem) -> Bool {
    if item.sender == "user" { return true }
    return item.type == "message" || item.type == "agent.message" || item.type == "message.sent" || item.type == "error"
}
