import SwiftUI

struct GraphPanelView: View {
    @Bindable var store: SessionStore
    @State private var zoom: CGFloat = 1
    @State private var zoomStart: CGFloat?
    @State private var pan: CGSize = .zero
    @State private var panStart: CGSize?

    private let nodeSize = CGSize(width: 152, height: 72)
    private let nodeGap = CGSize(width: 72, height: 70)
    private let contentPadding: CGFloat = 88
    private var graph: GraphState { store.graph }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            legend
            graphCanvas
                .frame(minHeight: 320)
            nodeList
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Workflow Graph")
                    .font(.headline)
                Spacer()
                Button {
                    zoom = max(0.55, zoom - 0.15)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .help("Zoom out")
                Button {
                    zoom = min(2.2, zoom + 0.15)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .help("Zoom in")
                Button {
                    zoom = 1
                    pan = .zero
                } label: {
                    Image(systemName: "arrow.up.left.and.down.right.magnifyingglass")
                }
                .help("Reset graph view")
            }
            HStack(spacing: 8) {
                Label("Viewing: \(store.transcriptFilterLabel)", systemImage: "line.3.horizontal.decrease.circle")
                Spacer()
                Label("Controlling: \(store.selectedControlAgentLabel)", systemImage: "scope")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding([.top, .horizontal])
    }

    private var legend: some View {
        HStack(spacing: 12) {
            Label("Handoff", systemImage: "arrow.right")
            Label("Message", systemImage: "ellipsis.message")
            ForEach([AgentStatus.working, .waiting, .completed, .failed], id: \.self) { status in
                Label(status.rawValue.capitalized, systemImage: statusIcon(status))
                    .foregroundStyle(statusColor(status))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
    }

    private var graphCanvas: some View {
        GeometryReader { proxy in
            let layout = layout(size: proxy.size)
            let transformedPositions = layout.positions.mapValues { transform($0, contentSize: layout.contentSize, in: proxy.size) }
            ZStack {
                Canvas { context, size in
                    drawLanes(context: &context, size: size, layout: layout)
                    drawEdges(context: &context, size: size, layout: layout)
                    drawNodes(context: &context, size: size, layout: layout)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    store.selectAgent(nil)
                }
                .gesture(panGesture)
                .simultaneousGesture(zoomGesture)

                ForEach(graph.nodes) { node in
                    if let point = transformedPositions[node.id] {
                        let size = scaledNodeSize
                        Button {
                            store.selectAgent(node.id)
                        } label: {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.clear)
                                .contentShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(accessibilityLabel(for: node))
                        .frame(width: size.width, height: size.height)
                        .position(point)
                    }
                }
            }
            .clipShape(Rectangle())
        }
    }

    private var nodeList: some View {
        List {
            ForEach(Array(graph.nodes.enumerated()), id: \.element.id) { _, node in
                Button {
                    store.selectAgent(node.id)
                } label: {
                    HStack {
                        Circle()
                            .fill(Color(hex: node.colorHex))
                            .frame(width: 9, height: 9)
                        Image(systemName: statusIcon(node.status))
                            .foregroundStyle(statusColor(node.status))
                            .frame(width: 14)
                        Text(node.label)
                        Spacer()
                        if node.unreadCount > 0 {
                            Text("\(node.unreadCount)")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.blue.opacity(0.18), in: Capsule())
                        }
                        if node.errorCount > 0 {
                            Text("!\(node.errorCount)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.red)
                        }
                        if node.id == store.selectedControlAgentId {
                            Text("control")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                        Text(node.status.rawValue)
                            .foregroundStyle(statusColor(node.status))
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let start = panStart ?? pan
                panStart = start
                pan = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
            }
            .onEnded { _ in
                panStart = nil
            }
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let start = zoomStart ?? zoom
                zoomStart = start
                zoom = min(2.2, max(0.55, start * value))
            }
            .onEnded { _ in
                zoomStart = nil
            }
    }

    private func drawEdges(context: inout GraphicsContext, size: CGSize, layout: GraphLayout) {
        let bucketCounts = Dictionary(grouping: graph.edges, by: edgeBucketKey).mapValues(\.count)
        var endpointCounts: [String: Int] = [:]
        var edgeIndexes: [String: Int] = [:]
        let visibleNodeSize = scaledNodeSize
        for edge in graph.edges {
            guard let startCenter = layout.positions[edge.from],
                  let endCenter = layout.positions[edge.to] else { continue }
            let startRect = nodeRect(center: transform(startCenter, contentSize: layout.contentSize, in: size), size: visibleNodeSize)
            let endRect = nodeRect(center: transform(endCenter, contentSize: layout.contentSize, in: size), size: visibleNodeSize)
            let endpoints = edgeEndpoints(from: startRect, to: endRect)
            let start = endpoints.start
            let end = endpoints.end
            let bucket = edgeBucketKey(edge)
            let bucketIndex = edgeIndexes[bucket, default: 0]
            edgeIndexes[bucket] = bucketIndex + 1
            let route = edgeRoute(from: start, to: end, offset: CGFloat(bucketIndex) - CGFloat((bucketCounts[bucket] ?? 1) - 1) / 2)
            let style = StrokeStyle(lineWidth: edge.active ? 2.5 : 1.5, dash: edge.kind == .message ? [5, 5] : [])
            context.stroke(route.path, with: .color(edge.active ? .accentColor : .secondary), style: style)
            drawArrowhead(context: context, from: route.arrowFrom, to: end, active: edge.active)
            endpointCounts["\(Int(end.x)):\(Int(end.y))", default: 0] += 1
            let radius = endpointCounts["\(Int(end.x)):\(Int(end.y))", default: 1] > 1 ? 4.5 : 3.5
            context.fill(Path(ellipseIn: CGRect(x: end.x - radius, y: end.y - radius, width: radius * 2, height: radius * 2)), with: .color(edge.active ? .accentColor : .secondary))
        }
    }

    private func drawLanes(context: inout GraphicsContext, size: CGSize, layout: GraphLayout) {
        for lane in layout.lanes {
            let minPoint = transform(CGPoint(x: lane.rect.minX, y: lane.rect.minY), contentSize: layout.contentSize, in: size)
            let maxPoint = transform(CGPoint(x: lane.rect.maxX, y: lane.rect.maxY), contentSize: layout.contentSize, in: size)
            let rect = CGRect(
                x: min(minPoint.x, maxPoint.x),
                y: min(minPoint.y, maxPoint.y),
                width: abs(maxPoint.x - minPoint.x),
                height: abs(maxPoint.y - minPoint.y)
            )
            context.fill(Path(roundedRect: rect, cornerRadius: 10), with: .color(.secondary.opacity(0.045)))
            context.stroke(Path(roundedRect: rect, cornerRadius: 10), with: .color(.secondary.opacity(0.12)), lineWidth: 1)
            context.draw(
                Text(lane.label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary),
                at: CGPoint(x: rect.minX + 12, y: rect.minY + 12),
                anchor: .leading
            )
        }
    }

    private func drawNodes(context: inout GraphicsContext, size: CGSize, layout: GraphLayout) {
        let visibleNodeSize = scaledNodeSize
        for node in graph.nodes {
            guard let point = layout.positions[node.id] else { continue }
            let center = transform(point, contentSize: layout.contentSize, in: size)
            let rect = nodeRect(center: center, size: visibleNodeSize)
            let roleColor = Color(hex: node.colorHex)
            let stateColor = statusColor(node.status)
            context.fill(Path(roundedRect: rect, cornerRadius: 8), with: .color(roleColor.opacity(0.14)))
            context.stroke(Path(roundedRect: rect, cornerRadius: 8), with: .color(stateColor), lineWidth: node.status == .idle ? 1.5 : 2.5)
            if node.id == store.selectedAgentId {
                context.stroke(Path(roundedRect: rect.insetBy(dx: -4, dy: -4), cornerRadius: 10), with: .color(.accentColor), lineWidth: 2.5)
            }
            context.draw(Text(shortLabel(node.label, maxLength: zoom < 0.75 ? 10 : 18)).font(.system(size: max(8, 12 * zoom), weight: .semibold)), at: CGPoint(x: rect.midX, y: rect.midY - 12 * zoom), anchor: .center)
            if zoom >= 0.7 {
                context.draw(Text(node.status.rawValue).font(.system(size: max(7, 10 * zoom))).foregroundStyle(stateColor), at: CGPoint(x: rect.midX, y: rect.midY + 10 * zoom), anchor: .center)
            }
            if node.errorCount > 0 || node.unreadCount > 0 {
                context.draw(Text(badgeText(for: node)).font(.system(size: max(7, 10 * zoom), weight: .bold)), at: CGPoint(x: rect.maxX - 12 * zoom, y: rect.minY + 12 * zoom), anchor: .center)
            }
        }
    }

    private func layout(size: CGSize) -> GraphLayout {
        guard !graph.nodes.isEmpty else { return GraphLayout(contentSize: size, positions: [:], lanes: []) }
        let groups = groupedNodes()
        let cell = CGSize(width: nodeSize.width + nodeGap.width, height: nodeSize.height + nodeGap.height)
        let availableColumns = max(1, Int(floor(max(cell.width, size.width / max(zoom, 0.1) - contentPadding * 2) / cell.width)))
        let groupColumns = groups.map { min(max(1, $0.nodes.count), availableColumns) }
        let maxColumns = max(1, groupColumns.max() ?? 1)
        let groupRows = zip(groups, groupColumns).map { group, columns in
            max(1, Int(ceil(Double(group.nodes.count) / Double(columns))))
        }
        let totalRows = groupRows.reduce(0, +)
        let contentSize = CGSize(
            width: max(size.width / max(zoom, 0.1), CGFloat(maxColumns) * cell.width + contentPadding * 2),
            height: max(size.height / max(zoom, 0.1), CGFloat(totalRows) * cell.height + contentPadding * 2)
        )
        var positions: [String: CGPoint] = [:]
        var lanes: [GraphLane] = []
        var rowOffset = 0
        for (groupIndex, group) in groups.enumerated() {
            let columns = groupColumns[groupIndex]
            let rows = groupRows[groupIndex]
            let groupWidth = CGFloat(columns) * cell.width
            let xOffset = max(contentPadding, (contentSize.width - groupWidth) / 2)
            let y = contentPadding + cell.height * CGFloat(rowOffset) + nodeSize.height / 2
            lanes.append(GraphLane(
                label: group.label,
                rect: CGRect(
                    x: contentPadding / 2,
                    y: y - cell.height / 2 + 10,
                    width: contentSize.width - contentPadding,
                    height: CGFloat(rows) * cell.height - 20
                )
            ))
            for (index, node) in group.nodes.enumerated() {
                let row = index / columns
                let column = index % columns
                positions[node.id] = CGPoint(
                    x: xOffset + cell.width * CGFloat(column) + nodeSize.width / 2,
                    y: y + cell.height * CGFloat(row)
                )
            }
            rowOffset += rows
        }
        return GraphLayout(contentSize: contentSize, positions: positions, lanes: lanes)
    }

    private func groupedNodes() -> [GraphNodeGroup] {
        let memberships = workflowMemberships()
        var groups: [String: [AgentNode]] = [:]
        var order: [String] = []
        for node in graph.nodes {
            let key = memberships[node.id]?.key ?? "session"
            if groups[key] == nil {
                groups[key] = []
                order.append(key)
            }
            groups[key, default: []].append(node)
        }
        order.sort { lhs, rhs in
            if lhs == "session" { return true }
            if rhs == "session" { return false }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        return order.map { key in
            GraphNodeGroup(
                label: memberships.values.first { $0.key == key }?.label ?? "Session",
                nodes: groups[key] ?? []
            )
        }
    }

    private func workflowMemberships() -> [String: WorkflowMembership] {
        var memberships: [String: WorkflowMembership] = [:]
        var workflowCounts: [String: Int] = [:]
        for event in store.transcript where event.type == "workflow.instantiated" {
            guard let workflowInstanceId = event.payload["workflowInstanceId"]?.stringValue,
                  let workflowId = event.payload["workflowId"]?.stringValue,
                  let nodeMap = event.payload["nodeMap"]?.objectValue else { continue }
            workflowCounts[workflowId, default: 0] += 1
            let ordinal = workflowCounts[workflowId, default: 1]
            let callerAgentId = event.payload["callerAgentId"]?.stringValue
            let membership = WorkflowMembership(
                key: workflowInstanceId,
                label: workflowLaneLabel(workflowId: workflowId, ordinal: ordinal, instanceId: workflowInstanceId)
            )
            for value in nodeMap.values {
                guard let agentId = value.stringValue, agentId != callerAgentId else { continue }
                memberships[agentId] = membership
            }
        }
        return memberships
    }

    private func workflowLaneLabel(workflowId: String, ordinal: Int, instanceId: String) -> String {
        let base = workflowId.replacingOccurrences(of: "-", with: " ")
        let suffix = String(instanceId.suffix(4))
        return ordinal == 1 ? base : "\(base) \(ordinal) #\(suffix)"
    }

    private func transform(_ point: CGPoint, contentSize: CGSize, in viewport: CGSize) -> CGPoint {
        CGPoint(
            x: (point.x - contentSize.width / 2) * zoom + viewport.width / 2 + pan.width,
            y: (point.y - contentSize.height / 2) * zoom + viewport.height / 2 + pan.height
        )
    }

    private var scaledNodeSize: CGSize {
        CGSize(width: nodeSize.width * zoom, height: nodeSize.height * zoom)
    }

    private func nodeRect(center: CGPoint, size: CGSize) -> CGRect {
        CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    private func edgeEndpoints(from startRect: CGRect, to endRect: CGRect) -> (start: CGPoint, end: CGPoint) {
        let startCandidates = edgeAnchorPoints(for: startRect)
        let endCandidates = edgeAnchorPoints(for: endRect)
        var best = (start: startCandidates[0], end: endCandidates[0])
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for start in startCandidates {
            for end in endCandidates {
                let distance = hypot(start.x - end.x, start.y - end.y)
                if distance < bestDistance {
                    bestDistance = distance
                    best = (start, end)
                }
            }
        }
        return best
    }

    private func edgeAnchorPoints(for rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.midX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.midY)
        ]
    }

    private func edgeRoute(from start: CGPoint, to end: CGPoint, offset: CGFloat) -> (path: Path, arrowFrom: CGPoint) {
        var path = Path()
        path.move(to: start)
        guard abs(start.x - end.x) > 24, abs(start.y - end.y) > 24 else {
            path.addLine(to: end)
            return (path, start)
        }
        let midY = (start.y + end.y) / 2 + offset * 10
        let beforeEnd = CGPoint(x: end.x, y: midY)
        path.addLine(to: CGPoint(x: start.x, y: midY))
        path.addLine(to: beforeEnd)
        path.addLine(to: end)
        return (path, beforeEnd)
    }

    private func drawArrowhead(context: GraphicsContext, from start: CGPoint, to end: CGPoint, active: Bool) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length: CGFloat = 10
        var arrow = Path()
        arrow.move(to: end)
        arrow.addLine(to: CGPoint(x: end.x - cos(angle - .pi / 6) * length, y: end.y - sin(angle - .pi / 6) * length))
        arrow.move(to: end)
        arrow.addLine(to: CGPoint(x: end.x - cos(angle + .pi / 6) * length, y: end.y - sin(angle + .pi / 6) * length))
        context.stroke(arrow, with: .color(active ? .accentColor : .secondary), lineWidth: active ? 2.5 : 1.5)
    }

    private func statusIcon(_ status: AgentStatus) -> String {
        switch status {
        case .working: return "bolt.fill"
        case .waiting: return "hourglass"
        case .idle: return "circle"
        case .paused: return "pause.circle"
        case .cancelled: return "xmark.circle"
        case .failed: return "exclamationmark.triangle.fill"
        case .completed: return "checkmark.circle.fill"
        }
    }

    private func statusColor(_ status: AgentStatus) -> Color {
        switch status {
        case .working: return .blue
        case .waiting: return .orange
        case .idle: return .secondary
        case .paused: return .purple
        case .cancelled: return .gray
        case .failed: return .red
        case .completed: return .green
        }
    }

    private func badgeText(for node: AgentNode) -> String {
        if node.errorCount > 0 { return "!\(node.errorCount)" }
        return "\(node.unreadCount)"
    }

    private func edgeBucketKey(_ edge: AgentEdge) -> String {
        [edge.from, edge.to].sorted().joined(separator: "<->") + ":\(edge.kind.rawValue)"
    }

    private func shortLabel(_ label: String, maxLength: Int = 18) -> String {
        label.count > maxLength ? "\(label.prefix(max(1, maxLength - 1)))..." : label
    }

    private func accessibilityLabel(for node: AgentNode) -> String {
        var parts = ["Select \(node.label)", "status \(node.status.rawValue)"]
        if node.unreadCount > 0 {
            parts.append("\(node.unreadCount) unread")
        }
        if node.errorCount > 0 {
            parts.append("\(node.errorCount) errors")
        }
        if node.id == store.selectedControlAgentId {
            parts.append("control agent")
        }
        return parts.joined(separator: ", ")
    }
}

private struct GraphLayout {
    let contentSize: CGSize
    let positions: [String: CGPoint]
    let lanes: [GraphLane]
}

private struct GraphLane {
    let label: String
    let rect: CGRect
}

private struct GraphNodeGroup {
    let label: String
    let nodes: [AgentNode]
}

private struct WorkflowMembership {
    let key: String
    let label: String
}
