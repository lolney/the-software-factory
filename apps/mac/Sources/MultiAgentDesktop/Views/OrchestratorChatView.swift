import SwiftUI

struct OrchestratorChatView: View {
    @Bindable var store: SessionStore
    var openInspector: () -> Void = {}
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

    private var shouldShowBranchingTimeline: Bool {
        store.selectedAgentId == nil
            && store.transcriptSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && branchingAgentCount > 1
    }

    private var branchingTranscript: [TranscriptItem] {
        Array(filteredTranscript.suffix(timelineRenderLimit))
    }

    private var branchingAgentCount: Int {
        if store.graph.nodes.count > 1 { return store.graph.nodes.count }
        let ids = filteredTranscript.flatMap { item in
            [
                item.agentId,
                item.sender,
                item.recipient,
                item.payload["from"]?.stringValue,
                item.payload["to"]?.stringValue
            ]
        }
        .compactMap(normalizedAgentId)
        .filter { $0 != "user" && $0 != "system" }
        return Set(ids).count
    }

    private func normalizedAgentId(_ id: String?) -> String? {
        guard let value = id?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TranscriptTopBar(
                store: store,
                followLiveTail: $followLiveTail,
                transcriptCountSummary: transcriptCountSummary
            )

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
                            if shouldShowBranchingTimeline {
                                AgentBranchingTimelineView(
                                    graph: store.graph,
                                    metadataTranscript: filteredTranscript,
                                    visibleTranscript: branchingTranscript,
                                    colorForAgent: color(for:),
                                    selectEvent: { eventId in
                                        store.selectTimelineEvent(eventId)
                                        openInspector()
                                    }
                                )
                                .id("branching-agent-timeline")
                            } else {
                                ForEach(timelineItems) { item in
                                    TimelineRow(store: store, item: item, color: color(for: item.primaryAgentId), openInspector: openInspector)
                                        .id(item.id)
                                }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.sRGB, white: 0.988, opacity: 1))
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

    private var transcriptCountSummary: String {
        if store.isTranscriptFiltered {
            return "\(filteredTranscript.count) of \(store.transcript.count) events"
        }
        return "\(store.transcript.count) events"
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

private struct TranscriptTopBar: View {
    @Bindable var store: SessionStore
    @Binding var followLiveTail: Bool
    let transcriptCountSummary: String

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                Menu {
                    Button {
                        store.selectAgent(nil)
                    } label: {
                        Label("All Agents", systemImage: store.selectedAgentId == nil ? "checkmark.circle.fill" : "circle")
                    }
                    if !store.transcriptAgentOptions.isEmpty {
                        Divider()
                    }
                    ForEach(store.transcriptAgentOptions) { agent in
                        Button {
                            store.selectAgent(agent.id)
                        } label: {
                            Label(agent.label, systemImage: agent.id == store.selectedAgentId ? "checkmark.circle.fill" : "circle")
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(store.transcriptFilterLabel)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.primary.opacity(0.90))
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary.opacity(0.25))
                    }
                }
                .buttonStyle(.plain)

                Color.clear
                    .frame(width: 53, height: 1)

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary.opacity(0.62))
                    TextField("Search transcript", text: $store.transcriptSearchText)
                        .textFieldStyle(.plain)
                    Image(systemName: "command")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tertiary.opacity(0.62))
                        .frame(width: 18, height: 18)
                        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 4))
                        .overlay {
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(.separator.opacity(0.35))
                        }
                }
                .padding(.horizontal, 11)
                .frame(width: 354, height: 34)
                .background(Color(.sRGB, red: 250 / 255, green: 250 / 255, blue: 250 / 255, opacity: 1), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(.sRGB, white: 0.98, opacity: 1))
                }
                .padding(.trailing, 12)

                Spacer(minLength: 0)
            }
            .padding(.top, 34)
            .padding(.horizontal, 39)
            .padding(.bottom, 24)

            SessionStateStrip(store: store, transcriptCountSummary: transcriptCountSummary)
                .padding(.horizontal, 40)
                .padding(.bottom, 14)
                .offset(x: -15, y: -4)
        }
        .background(Color.black.opacity(0.005))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(.sRGB, white: 225 / 255, opacity: 1))
                .frame(height: 1)
                .offset(y: 20)
        }
        .overlay(alignment: .trailing) {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0), location: 0),
                    .init(color: .black.opacity(0.05), location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 24)
            .allowsHitTesting(false)
        }
    }
}

private struct SessionStateStrip: View {
    @Bindable var store: SessionStore
    let transcriptCountSummary: String
    private let mockupStatusGreen = Color(.sRGB, red: 110 / 255, green: 180 / 255, blue: 119 / 255, opacity: 1)

    private var activeAgents: Int {
        store.graph.nodes.filter { [.working, .waiting, .paused].contains($0.status) }.count
    }

    private var waitingAgents: Int {
        store.graph.nodes.filter { $0.status == .waiting }.count
    }

    private var agentSummary: String {
        if activeAgents > 0 {
            return "\(activeAgents) active"
        }
        if !store.graph.nodes.isEmpty {
            return "\(store.graph.nodes.count) total"
        }
        return transcriptCountSummary
    }

    private var queuedWorkCount: Int {
        let completedCallIds = Set(store.transcript.compactMap { item in
            item.type == "agent.tool_result" ? item.payload["callId"]?.stringValue : nil
        })
        return store.transcript.filter { item in
            item.type == "agent.tool_call"
                && item.payload["callId"]?.stringValue.map { !completedCallIds.contains($0) } == true
        }.count
    }

    private var lastActionAge: String {
        guard let item = store.transcript.reversed().first(where: { $0.type != "client.ack" }) else { return "No transcript events" }
        return compactRelativeTimeLabel(from: item.timestamp)
    }

    private var runtimeLabel: String {
        guard let first = store.transcript.first?.timestamp,
              let last = store.transcript.last?.timestamp else {
            return "-"
        }
        let seconds = max(0, Int(last.timeIntervalSince(first)))
        let minutes = seconds / 60
        let remaining = seconds % 60
        if minutes > 0 {
            return "\(minutes)m \(remaining)s"
        }
        return "\(remaining)s"
    }

    var body: some View {
        GeometryReader { proxy in
            let metricWidth = max(86, (proxy.size.width - 6) / 7)
            HStack(spacing: 0) {
                MetricCell(title: "Agents", value: agentSummary, width: metricWidth)
                metricDivider
                MetricCell(title: "Queue", value: "\(queuedWorkCount)", width: metricWidth, sparkline: true, sparklineValues: [0.05, 0.05, 0.06, 0.06, 0.62, 0.08, 0.18, 0.08, 0.07, 0.07])
                metricDivider
                MetricCell(title: "Last action", value: lastActionAge, width: metricWidth)
                metricDivider
                MetricCell(title: "Failures", value: nil, width: metricWidth, statusColor: store.sessionErrorCount > 0 ? .orange : mockupStatusGreen)
                metricDivider
                MetricCell(title: "Changed files", value: "\(store.touchedWorkspaceFiles.count)", width: metricWidth, sparkline: !store.touchedWorkspaceFiles.isEmpty, sparklineValues: [0.05, 0.05, 0.06, 0.08, 0.55, 0.08, 0.12, 0.5, 0.08, 0.6, 0.08], valueOffsetX: 0)
                metricDivider
                MetricCell(title: "Mode", value: "Auto", width: metricWidth, showsChevron: true)
                metricDivider
                MetricCell(title: "Runtime", value: runtimeLabel, width: metricWidth, valueOffsetX: 0)
            }
        }
        .frame(height: 56)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metricDivider: some View {
        Rectangle()
            .fill(.separator.opacity(0.16))
            .frame(width: 1, height: 30)
    }
}

private struct MetricCell: View {
    let title: String
    let value: String?
    let width: CGFloat
    var statusColor: Color?
    var sparkline = false
    var sparklineValues: [CGFloat]?
    var showsChevron = false
    var valueOffsetX: CGFloat = -1

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary.opacity(0.69))
                    .lineLimit(1)
                HStack(spacing: 7) {
                    if let statusColor {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 7, height: 7)
                    }
                    if let value {
                        Text(value)
                            .font(.system(size: 14))
                            .foregroundStyle(.primary.opacity(0.86))
                            .lineLimit(1)
                            .monospacedDigit()
                    }
                    if sparkline {
                        TinySparkline(values: sparklineValues ?? TinySparkline.defaultValues)
                            .frame(width: 36, height: 13)
                    }
                    if showsChevron {
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .offset(x: valueOffsetX)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 15)

        }
        .frame(width: width)
    }
}

private struct AgentBranchingTimelineView: View {
    let graph: GraphState
    let metadataTranscript: [TranscriptItem]
    let visibleTranscript: [TranscriptItem]
    let colorForAgent: (String?) -> Color
    let selectEvent: (String) -> Void
    @State private var hoveredEventId: String?

    private func canvasHeight(for projection: BranchingTimelineProjection) -> CGFloat {
        max(540, CGFloat(max(projection.events.count, 10)) * 38)
    }

    var body: some View {
        let projection = BranchingTimelineProjection(
            graph: graph,
            metadataTranscript: metadataTranscript,
            visibleTranscript: visibleTranscript
        )
        let lanes = projection.lanes
        VStack(alignment: .leading, spacing: 10) {
            Text("Today")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        drawTimeline(context: &context, size: size, projection: projection)
                    }
                    ForEach(lanes) { lane in
                        Text(lane.label)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary.opacity(0.78))
                            .lineLimit(1)
                            .frame(width: laneWidth(in: proxy.size.width, laneCount: lanes.count), alignment: .leading)
                            .position(
                                x: xPosition(for: lane.index, width: proxy.size.width, laneCount: lanes.count) + 74,
                                y: max(16, yPosition(for: lane.createdAt, in: projection, height: proxy.size.height) - 18)
                            )
                    }
                    ForEach(projection.events) { event in
                        TimelineIconNode(event: event, color: colorForAgent(event.agentId)) {
                            selectEvent(event.id)
                        } setHovering: { isHovering in
                            hoveredEventId = isHovering ? event.id : (hoveredEventId == event.id ? nil : hoveredEventId)
                        }
                            .position(
                                x: xPosition(for: event.laneIndex, width: proxy.size.width, laneCount: lanes.count),
                                y: yPosition(for: event.timestamp, in: projection, height: proxy.size.height) + event.visualOffset
                            )
                    }
                    if let hoveredEvent = projection.events.first(where: { $0.id == hoveredEventId }) {
                        TimelineEventTooltip(event: hoveredEvent)
                            .position(
                                x: tooltipX(
                                    for: xPosition(for: hoveredEvent.laneIndex, width: proxy.size.width, laneCount: lanes.count),
                                    width: proxy.size.width
                                ),
                                y: max(54, yPosition(for: hoveredEvent.timestamp, in: projection, height: proxy.size.height) + hoveredEvent.visualOffset - 48)
                            )
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
                            .allowsHitTesting(false)
                            .zIndex(30)
                    }
                }
            }
            .frame(height: canvasHeight(for: projection))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Concurrent agent timeline")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func drawTimeline(context: inout GraphicsContext, size: CGSize, projection: BranchingTimelineProjection) {
        let lanes = projection.lanes
        guard !lanes.isEmpty else { return }
        let startY = yPosition(for: projection.startDate, in: projection, height: size.height)
        let endY = yPosition(for: projection.endDate, in: projection, height: size.height)

        for lane in lanes {
            let x = xPosition(for: lane.index, width: size.width, laneCount: lanes.count)
            let createdY = yPosition(for: lane.createdAt, in: projection, height: size.height)
            var idlePath = Path()
            idlePath.move(to: CGPoint(x: x, y: max(startY, createdY)))
            idlePath.addLine(to: CGPoint(x: x, y: endY))
            context.stroke(idlePath, with: .color(colorForAgent(lane.id).opacity(0.18)), lineWidth: 1.6)

            for range in lane.activeRanges {
                guard range.end >= projection.startDate, range.start <= projection.endDate else { continue }
                let activeStartY = max(createdY, yPosition(for: range.start, in: projection, height: size.height))
                let activeEndY = max(activeStartY + 1, yPosition(for: range.end, in: projection, height: size.height))
                var activePath = Path()
                activePath.move(to: CGPoint(x: x, y: activeStartY))
                activePath.addLine(to: CGPoint(x: x, y: activeEndY))
                context.stroke(activePath, with: .color(colorForAgent(lane.id).opacity(0.82)), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            }
        }

        for link in projection.links {
            let fromX = xPosition(for: link.fromLaneIndex, width: size.width, laneCount: lanes.count)
            let toX = xPosition(for: link.toLaneIndex, width: size.width, laneCount: lanes.count)
            let y = yPosition(for: link.timestamp, in: projection, height: size.height) + link.visualOffset
            var path = Path()
            if link.kind == .message {
                let midX = (fromX + toX) / 2
                let lift = min(18, max(8, abs(toX - fromX) * 0.035))
                path.move(to: CGPoint(x: fromX, y: y))
                path.addCurve(
                    to: CGPoint(x: toX, y: y),
                    control1: CGPoint(x: midX, y: y + lift),
                    control2: CGPoint(x: midX, y: y + lift)
                )
                context.stroke(
                    path,
                    with: .color(Color.secondary.opacity(0.46)),
                    style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round, dash: [4, 4])
                )
            } else {
                path.move(to: CGPoint(x: fromX, y: y))
                let midX = (fromX + toX) / 2
                path.addCurve(
                    to: CGPoint(x: toX, y: y),
                    control1: CGPoint(x: midX, y: y - 14),
                    control2: CGPoint(x: midX, y: y - 14)
                )
                context.stroke(
                    path,
                    with: .color(colorForAgent(link.toAgentId).opacity(0.42)),
                    style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round)
                )
            }
        }
    }

    private func laneWidth(in width: CGFloat, laneCount: Int) -> CGFloat {
        guard laneCount > 1 else { return min(160, width) }
        return min(120, max(64, (width - 72) / CGFloat(laneCount)))
    }

    private func xPosition(for index: Int, width: CGFloat, laneCount: Int) -> CGFloat {
        guard laneCount > 1 else { return width / 2 }
        let available = max(width - 72, 1)
        return 36 + available * CGFloat(index) / CGFloat(laneCount - 1)
    }

    private func yPosition(for date: Date, in projection: BranchingTimelineProjection, height: CGFloat) -> CGFloat {
        let top: CGFloat = 54
        let bottom: CGFloat = 34
        let span = max(1, projection.endDate.timeIntervalSince(projection.startDate))
        let progress = max(0, min(1, date.timeIntervalSince(projection.startDate) / span))
        return top + (height - top - bottom) * progress
    }

    private func tooltipX(for x: CGFloat, width: CGFloat) -> CGFloat {
        min(max(x, 118), max(118, width - 118))
    }
}

private struct TimelineIconNode: View {
    let event: BranchingTimelineEvent
    let color: Color
    let action: () -> Void
    let setHovering: (Bool) -> Void

    var body: some View {
        Button {
            setHovering(false)
            action()
        } label: {
            actionMarker
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
        }
        .frame(width: 32, height: 32)
        .contentShape(Rectangle())
        .buttonStyle(.plain)
        .onHover(perform: setHovering)
        .accessibilityLabel(event.helpText)
    }

    private var creationMarker: some View {
        Image(systemName: event.systemImage)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(color.opacity(0.76))
            .frame(width: 22, height: 22)
            .background(Color(.sRGB, white: 0.995, opacity: 0.96), in: Circle())
            .overlay {
                Circle()
                    .stroke(color.opacity(0.24), lineWidth: 1)
            }
            .overlay(alignment: .bottom) {
            Rectangle()
                .fill(color.opacity(0.38))
                .frame(width: 1.5, height: 18)
                    .offset(y: 16)
            }
    }

    @ViewBuilder
    private var actionMarker: some View {
        if event.isCreation {
            creationMarker
        } else {
        Image(systemName: event.systemImage)
            .font(.system(size: iconSize, weight: event.isStatus ? .regular : .semibold))
            .foregroundStyle(iconForeground)
            .frame(width: nodeSize, height: nodeSize)
            .background(iconBackground, in: Circle())
            .overlay {
                Circle()
                    .stroke(color.opacity(strokeOpacity), lineWidth: event.isStatus ? 0.8 : 1)
            }
            .shadow(color: .black.opacity(event.isStatus ? 0 : 0.045), radius: 1.5, y: 1)
        }
    }

    private var nodeSize: CGFloat {
        return event.isStatus ? 16 : 22
    }

    private var iconSize: CGFloat {
        if event.isStatus { return 8 }
        return 10.5
    }

    private var strokeOpacity: Double {
        if event.isStatus { return 0.16 }
        return 0.18
    }

    private var iconForeground: Color {
        if event.isStatus { return color.opacity(0.42) }
        if event.linkKind == .message { return .secondary }
        return color.opacity(0.72)
    }

    private var iconBackground: Color {
        if event.isStatus { return Color(.sRGB, white: 1, opacity: 0.74) }
        return Color(.sRGB, white: 0.995, opacity: 0.96)
    }
}

private struct TimelineEventTooltip: View {
    let event: BranchingTimelineEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: event.systemImage)
                    .font(.caption2.weight(.semibold))
                Text(event.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            if !event.detail.isEmpty && event.detail != event.title {
                Text(event.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text("Click for details")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(width: 220, alignment: .leading)
        .background(Color(.windowBackgroundColor).opacity(0.98), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(.separator.opacity(0.45))
        }
        .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
    }
}

private struct TinySparkline: View {
    static let defaultValues: [CGFloat] = [0.06, 0.06, 0.07, 0.06, 0.08, 0.58, 0.08, 0.12, 0.36, 0.78, 0.08, 0.5, 0.06]

    let values: [CGFloat]

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                for (index, value) in values.enumerated() {
                    let x = proxy.size.width * CGFloat(index) / CGFloat(values.count - 1)
                    let y = proxy.size.height * (1 - value)
                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(.secondary.opacity(0.7), lineWidth: 1)
        }
    }
}

private struct TimelineRow: View {
    @Bindable var store: SessionStore
    let item: TimelineItem
    let color: Color
    let openInspector: () -> Void
    @State private var expanded = false

    var body: some View {
        switch item {
        case .message(let message, let isFinalOutput):
            MessageRow(item: message, color: color, isFinalOutput: isFinalOutput)
        case .compact(let compact):
            CompactEventRow(item: compact, color: color)
        case .group(let group):
            GroupedEventRow(group: group, color: color, expanded: $expanded)
        case .transition(let transition):
            TransitionEventRow(item: transition, color: color, expanded: $expanded)
        case .plan(let plan):
            PlanEventRow(store: store, item: plan, color: color, expanded: $expanded, openInspector: openInspector)
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
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 6) {
                TimelineHeader(item: item, isFinalOutput: isFinalOutput)
                BoundedTextBlock(text: narrativeMessageText(for: item, isFinalOutput: isFinalOutput), font: .body, limit: 8_000)
            }
            .frame(maxWidth: 680, alignment: .leading)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
    }
}

private struct BoundedTextBlock: View {
    let text: String
    let font: Font
    let limit: Int

    private var preview: String {
        text.count > limit ? String(text.prefix(limit)) : text
    }

    private var omitted: Int {
        max(0, text.count - limit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(preview)
                .font(font)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if omitted > 0 {
                HStack(spacing: 8) {
                    Text("\(omitted) more characters omitted from inline preview")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button("Copy Full Text") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
            }
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
            Text(timelineCompactTitle(for: item))
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
}

private struct GroupedEventRow: View {
    let group: TimelineEventGroup
    let color: Color
    @Binding var expanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if expanded {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(group.events.prefix(20)) { event in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(color.opacity(0.45))
                                .frame(width: 5, height: 5)
                            Text(timelineCompactTitle(for: event))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Text(event.timestamp, style: .time)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    if group.events.count > 20 {
                        Text("\(group.events.count - 20) more events hidden")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.top, 6)
                .padding(.leading, 20)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: group.isActionGroup ? "checkmark.circle" : "ellipsis")
                    .font(.caption)
                    .foregroundStyle(group.isActionGroup ? Color.green : Color.secondary.opacity(0.55))
                    .frame(width: 16)
                Text(group.title)
                    .font(.caption.weight(.medium))
                if !group.subtitle.isEmpty {
                    Text(group.subtitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, group.isActionGroup ? 7 : 1)
        .frame(maxWidth: 680, alignment: .leading)
        .background {
            if group.isActionGroup {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary.opacity(0.18))
            }
        }
        .overlay {
            if group.isActionGroup {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(.separator.opacity(0.45))
            }
        }
    }
}

private func sessionStateActionTitle(for item: TranscriptItem) -> String {
    switch item.type {
    case "agent.message":
        return "\(item.sender) message"
    case "agent.tool_result":
        return item.payload["toolName"]?.stringValue ?? "tool completed"
    case "workspace.file_touched":
        return "edited \(item.payload["path"]?.stringValue ?? "file")"
    case "workflow.completed":
        return "workflow completed"
    case "scheduler.job.completed":
        return "turn completed"
    default:
        return timelineCompactTitle(for: item)
    }
}

private func narrativeMessageText(for item: TranscriptItem, isFinalOutput: Bool) -> String {
    switch item.text {
    case let text where text.hasPrefix("Debug orchestrator:"):
        return "Goal received. Planning and delegating to the workflow agents."
    case let text where text.hasPrefix("Debug planner:"):
        return "Selected the workflow graph, confirmed responsibilities, and handed the plan back to Orchestrator."
    case let text where text.hasPrefix("Debug reviewer:"):
        return "Reviewed implementation and sent one follow-up to Implementor."
    case let text where text.hasPrefix("Debug QA: acceptance checks completed"):
        return "Acceptance checks completed."
    default:
        return item.text
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
    @Bindable var store: SessionStore
    let item: TranscriptItem
    let color: Color
    @Binding var expanded: Bool
    let openInspector: () -> Void

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if let plan = item.payload["plan"]?.objectValue {
                        PlanPayloadView(plan: plan, workflowSpecs: arrayValue(item.payload["workflowSpecs"]) ?? [])
                    }
                    if item.payload["plan"]?.objectValue == nil {
                        planSummary
                    }
                    Button {
                        store.inspectorPanel = .plan
                        store.clearSelectedTimelineEvent()
                        openInspector()
                    } label: {
                        Label("Open Plan Inspector", systemImage: "sidebar.right")
                    }
                    .font(.caption)
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

    private var planSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let planId = item.payload["planId"]?.stringValue {
                Label(planId, systemImage: "number")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if !item.text.isEmpty {
                Text(item.text)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Text("Structured workflow and criteria details are available in the Plan inspector when the plan event records them.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
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
                Text(toolDisplayTitle)
                    .font(.caption.weight(.medium))
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
        .padding(.vertical, 7)
        .frame(maxWidth: 680, alignment: .leading)
        .background(.quaternary.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(.separator.opacity(0.42))
        }
    }

    private var toolDisplayTitle: String {
        switch toolName {
        case "workspace.write_file":
            return "file edit"
        case "workspace.run_command":
            return "test run"
        default:
            return toolName
        }
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
            return "\(path) +\(additions) -\(deletions)"
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
            if let label = label(for: item) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(isFinalOutput ? .green : .secondary)
                    .padding(.horizontal, isFinalOutput ? 5 : 0)
                    .padding(.vertical, isFinalOutput ? 1 : 0)
                    .background {
                        if isFinalOutput {
                            Capsule()
                                .fill(.green.opacity(0.14))
                        }
                    }
            }
            Text(item.timestamp, style: .time)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func label(for item: TranscriptItem) -> String? {
        if isFinalOutput { return "done" }
        if item.sender == "user" { return "prompt" }
        return nil
    }
}

private func diffPreview(_ diff: String, limit: Int) -> (lines: [String], omitted: Int) {
    let maxLineLength = 1_600
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
            if current.count < maxLineLength {
                current.append(character)
            } else {
                omitted += 1
            }
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
