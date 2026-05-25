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
        case .transition(let transition):
            TransitionEventRow(item: transition, color: color, expanded: $expanded)
        case .plan(let plan):
            PlanEventRow(item: plan, color: color, expanded: $expanded)
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

private struct TransitionEventRow: View {
    let item: TranscriptItem
    let color: Color
    @Binding var expanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                if let prompt = item.payload["prompt"]?.stringValue {
                    if let originalGoal = item.payload["originalGoal"]?.stringValue {
                        ToolPayloadBlock(title: "Original Goal", value: .string(originalGoal))
                    }
                    if let edgeId = item.payload["edgeId"]?.stringValue {
                        ToolPayloadBlock(title: "Edge", value: .string(edgeId))
                    }
                    ToolPayloadBlock(title: "Prompt sent to \(item.recipient ?? "agent")", value: .string(prompt))
                } else if let text = item.payload["text"]?.stringValue {
                    ToolPayloadBlock(title: "Message", value: .string(text))
                }
                if let reason = item.payload["reason"]?.stringValue {
                    ToolPayloadBlock(title: "Reason", value: .string(reason))
                }
            }
            .padding(.top, 6)
            .padding(.leading, 20)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.type == "handoff.created" ? "arrow.right.circle" : "ellipsis.message")
                    .foregroundStyle(color)
                    .frame(width: 14)
                Text(item.type == "handoff.created" ? "\(item.sender) -> \(item.recipient ?? "agent") handoff" : "\(item.sender) -> \(item.recipient ?? "agent") message")
                    .font(.caption.weight(.medium))
                if item.payload["prompt"]?.stringValue != nil {
                    Text("prompt")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(item.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 4)
    }
}

private struct PlanEventRow: View {
    let item: TranscriptItem
    let color: Color
    @Binding var expanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                if let plan = item.payload["plan"]?.objectValue {
                    PlanPayloadView(plan: plan, workflowSpecs: arrayValue(item.payload["workflowSpecs"]) ?? [])
                }
                if let planId = item.payload["planId"] {
                    ToolPayloadBlock(title: "Plan ID", value: planId)
                }
            }
            .padding(.top, 6)
            .padding(.leading, 20)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.type == "plan.created" ? "checklist" : "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(color)
                    .frame(width: 14)
                Text(item.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text(item.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 4)
    }
}

private struct PlanPayloadView: View {
    let plan: [String: JSONValue]
    let workflowSpecs: [JSONValue]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let goal = plan["goal"]?.stringValue {
                ToolPayloadBlock(title: "Goal", value: .string(goal))
            }
            if let description = plan["description"]?.stringValue, !description.isEmpty {
                ToolPayloadBlock(title: "Description", value: .string(description))
            }
            if let workflows = arrayValue(plan["workflows"]) {
                ForEach(Array(workflows.enumerated()), id: \.offset) { _, workflow in
                    if let object = workflow.objectValue {
                        PlanWorkflowView(workflow: object, spec: workflowSpec(for: object["workflowId"]?.stringValue))
                    }
                }
            }
            if let criteria = arrayValue(plan["globalDoneCriteria"]), !criteria.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Global Done Criteria")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(criteria.compactMap(\.stringValue), id: \.self) { criterion in
                        Text("- \(criterion)")
                            .font(.caption)
                    }
                }
            }
        }
    }

    private func workflowSpec(for workflowId: String?) -> [String: JSONValue]? {
        guard let workflowId else { return nil }
        return workflowSpecs.compactMap(\.objectValue).first { $0["id"]?.stringValue == workflowId }
    }
}

private struct PlanWorkflowView: View {
    let workflow: [String: JSONValue]
    let spec: [String: JSONValue]?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(spec?["name"]?.stringValue ?? workflow["workflowId"]?.stringValue ?? "Workflow")
                .font(.caption.weight(.semibold))
            if let nodes = arrayValue(spec?["nodes"]), !nodes.isEmpty {
                Text("Nodes: \(nodes.compactMap { $0.objectValue?["label"]?.stringValue ?? $0.objectValue?["id"]?.stringValue }.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let edges = arrayValue(spec?["edges"]), !edges.isEmpty {
                Text("Edges: \(edges.compactMap(edgeLabel).joined(separator: " | "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let stopCriteria = arrayValue(spec?["stopCriteria"])?.compactMap(\.stringValue), !stopCriteria.isEmpty {
                Text("Stop: \(stopCriteria.joined(separator: "; "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let prompts = workflow["agentPrompts"]?.objectValue, !prompts.isEmpty {
                Text("Agent Prompts")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(prompts.keys.sorted(), id: \.self) { key in
                    ToolPayloadBlock(title: key, value: prompts[key] ?? .null)
                }
            }
            if let done = workflow["doneCriteria"]?.objectValue, !done.isEmpty {
                Text("Done Criteria")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(done.keys.sorted(), id: \.self) { key in
                    let criteria = arrayValue(done[key])?.compactMap(\.stringValue) ?? []
                    VStack(alignment: .leading, spacing: 2) {
                        Text(key)
                            .font(.caption.weight(.medium))
                        ForEach(criteria, id: \.self) { criterion in
                            Text("- \(criterion)")
                                .font(.caption)
                        }
                    }
                }
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
    }

    private func edgeLabel(_ value: JSONValue) -> String? {
        guard let edge = value.objectValue else { return nil }
        return "\(edge["from"]?.stringValue ?? "?")->\(edge["to"]?.stringValue ?? "?") \(edge["kind"]?.stringValue ?? "")"
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
                if let diff = result?.payload["diff"] {
                    DiffPayloadBlock(diff: diff.stringValue ?? "")
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
        if let path = result.payload["path"]?.stringValue,
           let stats = result.payload["diffStats"]?.objectValue {
            let additions = Int(stats["additions"]?.numberValue ?? 0)
            let deletions = Int(stats["deletions"]?.numberValue ?? 0)
            return "Edited \(path) +\(additions) -\(deletions) - Diff"
        }
        guard let output = result.payload["output"]?.stringValue else { return "completed" }
        return output.split(separator: "\n").first.map(String.init) ?? "completed"
    }
}

private struct DiffPayloadBlock: View {
    let diff: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Diff")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(diff.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                    Text(String(line))
                        .font(.caption.monospaced())
                        .foregroundStyle(color(for: String(line)))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .textSelection(.enabled)
            .padding(8)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func color(for line: String) -> Color {
        if line.starts(with: "+") && !line.starts(with: "+++") { return .green }
        if line.starts(with: "-") && !line.starts(with: "---") { return .red }
        return .primary
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

    return items
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

private func arrayValue(_ value: JSONValue?) -> [JSONValue]? {
    if case .array(let values) = value {
        return values
    }
    return nil
}
