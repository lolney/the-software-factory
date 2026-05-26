import SwiftUI

struct OrchestratorChatView: View {
    @Bindable var store: SessionStore
    @State private var timelineItems: [TimelineItem] = []
    @State private var timelineIsTruncated = false
    @State private var scrollWorkItem: DispatchWorkItem?
    @State private var followLiveTail = true
    @State private var tailIsVisible = true

    private let timelineRenderLimit = 500
    private let timelineTailId = "timeline-tail"

    private var filteredTranscript: [TranscriptItem] {
        store.filteredTranscript
    }

    private var isTimelineTruncated: Bool {
        timelineIsTruncated
    }

    private var timelineDisplayVersion: String {
        "\(filteredTranscript.count)|\(filteredTranscript.first?.id ?? "")|\(filteredTranscript.last?.id ?? "")|\(store.transcriptSearchText)|\(store.selectedAgentId ?? "")"
    }

    private var liveTranscriptVersion: String {
        "\(store.transcript.count)|\(store.transcript.first?.id ?? "")|\(store.transcript.last?.id ?? "")"
    }

    private var transcriptFilterVersion: String {
        "\(store.transcriptSearchText)|\(store.selectedAgentId ?? "")"
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
                TextField("Search transcript", text: $store.transcriptSearchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                Button {
                    followLiveTail.toggle()
                } label: {
                    Label("Follow Live", systemImage: followLiveTail ? "arrow.down.circle.fill" : "arrow.down.circle")
                }
                .labelStyle(.iconOnly)
                .disabled(store.isTranscriptFiltered)
                .help(store.isTranscriptFiltered ? "Clear transcript filters to follow live events" : "Follow new transcript events")
                Text(store.connectionStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            if let status = store.statusBannerText {
                HStack(spacing: 8) {
                    Image(systemName: store.sessionErrorCount > 0 ? "exclamationmark.triangle.fill" : "info.circle")
                        .foregroundStyle(store.sessionErrorCount > 0 ? .orange : .secondary)
                    Text(status)
                        .font(.caption)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Button {
                        store.inspectorPanel = .debug
                    } label: {
                        Label("Debug", systemImage: "ladybug")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    if store.lastError != nil {
                        Button {
                            store.clearLastError()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .accessibilityLabel("Dismiss status")
                    }
                }
                .padding(8)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.orange.opacity(0.25))
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }

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
                            Text(store.isTranscriptFiltered ? "No transcript events match the current filter." : "No transcript events yet.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 24)
                        } else {
                            if isTimelineTruncated {
                                Text("Showing latest \(timelineItems.count) timeline rows from \(filteredTranscript.count) matching events")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 4)
                            }
                            ForEach(timelineItems) { item in
                                TimelineRow(item: item, color: color(for: item.primaryAgentId))
                                    .id(item.id)
                            }
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(timelineTailId)
                            .onAppear {
                                tailIsVisible = true
                            }
                            .onDisappear {
                                tailIsVisible = false
                                if followLiveTail {
                                    followLiveTail = false
                                }
                            }
                    }
                    .padding()
                }
                .onAppear {
                    updateTimelineItems()
                    if followLiveTail, !store.isTranscriptFiltered, let last = timelineItems.last {
                        scheduleScroll(to: last.id, proxy: proxy)
                    }
                }
                .onDisappear {
                    scrollWorkItem?.cancel()
                }
                .onChange(of: timelineDisplayVersion) { _, _ in
                    updateTimelineItems()
                }
                .onChange(of: liveTranscriptVersion) { _, _ in
                    updateTimelineItems()
                    if followLiveTail, tailIsVisible, !store.isTranscriptFiltered {
                        scheduleScroll(to: timelineTailId, proxy: proxy)
                    }
                }
                .onChange(of: transcriptFilterVersion) { _, _ in
                    if store.isTranscriptFiltered {
                        followLiveTail = false
                    }
                    updateTimelineItems()
                }
                .onChange(of: followLiveTail) { _, isFollowing in
                    if isFollowing, !store.isTranscriptFiltered {
                        scheduleScroll(to: timelineTailId, proxy: proxy)
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

    private func updateTimelineItems() {
        let window = timelineWindow(from: filteredTranscript, limit: timelineRenderLimit)
        timelineItems = window.items
        timelineIsTruncated = window.isTruncated
    }

    private func scheduleScroll(to id: String, proxy: ScrollViewProxy) {
        scrollWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(id, anchor: .bottom)
            }
        }
        scrollWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
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
}

private struct TransitionEventRow: View {
    let item: TranscriptItem
    let color: Color
    @Binding var expanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if let prompt = item.payload["prompt"]?.stringValue {
                        if let originalGoal = item.payload["originalGoal"]?.stringValue {
                            ToolPayloadBlock(title: "Original Goal", value: .string(originalGoal))
                        }
                        if let edgeId = item.payload["edgeId"]?.stringValue {
                            ToolPayloadBlock(title: "Edge", value: .string(edgeId))
                        }
                        if let workflowInstanceId = item.payload["workflowInstanceId"]?.stringValue {
                            ToolPayloadBlock(title: "Workflow Instance", value: .string(workflowInstanceId))
                        }
                        ToolPayloadBlock(title: "Prompt sent to \(item.recipient ?? "agent")", value: .string(prompt))
                    } else if let text = item.payload["text"]?.stringValue {
                        if let workflowInstanceId = item.payload["workflowInstanceId"]?.stringValue {
                            ToolPayloadBlock(title: "Workflow Instance", value: .string(workflowInstanceId))
                        }
                        ToolPayloadBlock(title: "Message", value: .string(text))
                    }
                    if let reason = item.payload["reason"]?.stringValue {
                        ToolPayloadBlock(title: "Reason", value: .string(reason))
                    }
                }
                .padding(.top, 6)
                .padding(.leading, 20)
            }
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
            if expanded {
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
            }
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
                let dependencyLabels = nodes.compactMap { value -> String? in
                    guard let node = value.objectValue,
                          let id = node["id"]?.stringValue,
                          let dependencies = arrayValue(node["dependencies"])?.compactMap(\.stringValue),
                          !dependencies.isEmpty else { return nil }
                    return "\(id) waits for \(dependencies.joined(separator: ", "))"
                }
                if !dependencyLabels.isEmpty {
                    Text("Dependencies: \(dependencyLabels.joined(separator: " | "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
            if let completionCriteria = arrayValue(spec?["completionCriteria"])?.compactMap(\.objectValue), !completionCriteria.isEmpty {
                Text("Completion Criteria")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(Array(completionCriteria.enumerated()), id: \.offset) { _, criterion in
                    Text("- \(criterion["description"]?.stringValue ?? criterion["id"]?.stringValue ?? "Criterion")")
                        .font(.caption)
                }
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
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if !metadataPairs.isEmpty {
                        ToolMetadataGrid(pairs: metadataPairs)
                    }
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
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                    .frame(width: 14)
                Text(toolName)
                    .font(.callout.weight(.medium))
                Text(statusLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(statusColor)
                if let result {
                    Text(shortResult(result))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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

    private var statusIcon: String {
        guard let result else { return "hammer" }
        if result.payload["blocked"]?.boolValue == true { return "exclamationmark.octagon" }
        if let exitCode = result.payload["exitCode"]?.numberValue, exitCode != 0 { return "xmark.octagon" }
        if resultLooksLikeError { return "exclamationmark.triangle" }
        return "checkmark.circle"
    }

    private var statusColor: Color {
        guard let result else { return color }
        if result.payload["blocked"]?.boolValue == true { return .orange }
        if let exitCode = result.payload["exitCode"]?.numberValue, exitCode != 0 { return .red }
        if resultLooksLikeError { return .orange }
        return .green
    }

    private var statusLabel: String {
        guard let result else { return "running" }
        if result.payload["blocked"]?.boolValue == true { return "blocked" }
        if let exitCode = result.payload["exitCode"]?.numberValue {
            return exitCode == 0 ? "exit 0" : "exit \(Int(exitCode))"
        }
        if resultLooksLikeError { return "error" }
        return "done"
    }

    private var resultLooksLikeError: Bool {
        guard let result else { return false }
        if result.payload["error"] != nil { return true }
        guard let output = result.payload["output"]?.stringValue?.lowercased() else { return false }
        return output.contains("an error occurred while running the tool")
            || output.contains("error: error:")
            || output.contains("cannot receive messages while")
            || output.contains("cannot receive messages")
    }

    private var metadataPairs: [(String, String)] {
        var pairs: [(String, String)] = []
        if let durationMs = result?.payload["durationMs"]?.numberValue {
            pairs.append(("Duration", formatDuration(durationMs)))
        }
        if let exitCode = result?.payload["exitCode"]?.numberValue {
            pairs.append(("Exit Code", "\(Int(exitCode))"))
        }
        if result?.payload["blocked"]?.boolValue == true {
            pairs.append(("Status", "Blocked"))
        }
        if let cwd = result?.payload["cwd"]?.stringValue ?? call.payload["input"]?.objectValue?["cwd"]?.stringValue {
            pairs.append(("Working Directory", abbreviatePath(cwd)))
        }
        return pairs
    }

    private func shortResult(_ result: TranscriptItem) -> String {
        if let path = result.payload["path"]?.stringValue,
           let stats = result.payload["diffStats"]?.objectValue {
            let additions = Int(stats["additions"]?.numberValue ?? 0)
            let deletions = Int(stats["deletions"]?.numberValue ?? 0)
            return "Edited \(path) +\(additions) -\(deletions) - Diff"
        }
        if let durationMs = result.payload["durationMs"]?.numberValue,
           let cwd = result.payload["cwd"]?.stringValue {
            return "\(formatDuration(durationMs)) in \(abbreviatePath(cwd))"
        }
        if let durationMs = result.payload["durationMs"]?.numberValue {
            return formatDuration(durationMs)
        }
        guard let output = result.payload["output"]?.stringValue else { return "completed" }
        return output.split(separator: "\n").first.map(String.init) ?? "completed"
    }

    private func formatDuration(_ milliseconds: Double) -> String {
        if milliseconds < 1_000 {
            return "\(Int(milliseconds)) ms"
        }
        return String(format: "%.1f s", milliseconds / 1_000)
    }

    private func abbreviatePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }
}

private struct ToolMetadataGrid: View {
    let pairs: [(String, String)]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(pairs, id: \.0) { label, value in
                GridRow {
                    Text(label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct DiffPayloadBlock: View {
    let diff: String

    private var previewLines: [String] {
        diffPreview(diff, limit: 300).lines
    }

    private var omittedLineCount: Int {
        diffPreview(diff, limit: 300).omitted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Diff")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(previewLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption.monospaced())
                        .foregroundStyle(color(for: line))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if omittedLineCount > 0 {
                    HStack(spacing: 8) {
                        Text("... at least \(omittedLineCount) more diff lines omitted from inline preview")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Button("Copy Full Diff") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(diff, forType: .string)
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)
                    }
                    .padding(.top, 4)
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

    private var renderedPreview: (text: String, omitted: Int) {
        renderPreview(value, limit: 12_000)
    }

    private var omittedCharacterCount: Int {
        renderedPreview.omitted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(renderedPreview.text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            if omittedCharacterCount > 0 {
                HStack(spacing: 8) {
                    Text("At least \(omittedCharacterCount) more characters omitted from inline preview")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button("Copy Full Value") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(render(value), forType: .string)
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
            }
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

private func timelineWindow(from transcript: [TranscriptItem], limit: Int) -> (items: [TimelineItem], isTruncated: Bool) {
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

private func diffPreview(_ diff: String, limit: Int) -> (lines: [String], omitted: Int) {
    var lines: [String] = []
    var current = ""
    var omitted = 0
    for character in diff {
        if character == "\n" {
            if lines.count < limit {
                lines.append(current)
            } else {
                omitted += 1
                if omitted > limit { break }
            }
            current = ""
        } else if lines.count < limit {
            current.append(character)
        }
    }
    if !current.isEmpty || diff.last == "\n" {
        if lines.count < limit {
            lines.append(current)
        } else {
            omitted += 1
        }
    }
    return (lines, omitted)
}

private func renderPreview(_ value: JSONValue, limit: Int) -> (text: String, omitted: Int) {
    var renderer = BoundedJSONRenderer(limit: limit)
    renderer.append(value)
    return (renderer.text, renderer.omitted)
}

private struct BoundedJSONRenderer {
    let limit: Int
    private(set) var text = ""
    private(set) var omitted = 0

    mutating func append(_ value: JSONValue) {
        switch value {
        case .string(let string):
            append(string)
        case .number(let number):
            append(String(number))
        case .bool(let bool):
            append(String(bool))
        case .null:
            append("null")
        case .array(let values):
            for (index, value) in values.enumerated() {
                if index > 0 { append("\n") }
                append(value)
                if omitted > limit { break }
            }
        case .object(let object):
            let keys = object.keys.sorted()
            for (index, key) in keys.enumerated() {
                if index > 0 { append("\n") }
                append("\(key): ")
                append(object[key] ?? .null)
                if omitted > limit { break }
            }
        }
    }

    mutating func append(_ string: String) {
        guard text.count < limit else {
            omitted += string.count
            return
        }
        let remaining = limit - text.count
        if string.count <= remaining {
            text += string
        } else {
            text += String(string.prefix(remaining))
            omitted += string.count - remaining
        }
    }
}

private func arrayValue(_ value: JSONValue?) -> [JSONValue]? {
    if case .array(let values) = value {
        return values
    }
    return nil
}
