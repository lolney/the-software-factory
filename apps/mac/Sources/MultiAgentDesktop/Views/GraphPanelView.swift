import SwiftUI

struct GraphPanelView: View {
    @Bindable var store: SessionStore
    var commandRequest: GraphViewCommandRequest?
    @State private var zoom: CGFloat = 1
    @State private var zoomStart: CGFloat?
    @State private var pan: CGSize = .zero
    @State private var panStart: CGSize?
    @State private var graphViewportSize: CGSize = .zero
    @State private var handledCommandId: UUID?

    private let nodeSize = CGSize(width: 152, height: 72)
    private let nodeGap = CGSize(width: 72, height: 70)
    private let contentPadding: CGFloat = 88
    private let workflowGroupPadding = CGSize(width: 42, height: 42)
    private var graph: GraphState { store.graph }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if graph.nodes.isEmpty {
                ContentUnavailableView(
                    "No Workflow Graph",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("No workflow graph data is available for this session.")
                )
                .frame(maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)
            } else {
                graphCanvas
                    .frame(minHeight: 320)
            }
        }
        .onAppear {
            handleGraphCommandRequest(commandRequest)
        }
        .onChange(of: commandRequest) { _, request in
            handleGraphCommandRequest(request)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Workflow Graph")
                    .font(.headline)
                Spacer()
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
                            HStack {
                                Label(agent.label, systemImage: agent.id == store.selectedAgentId ? "checkmark.circle.fill" : statusIcon(agent.status ?? .idle))
                                if agent.unreadCount > 0 {
                                    Text("\(agent.unreadCount) unread")
                                }
                                if agent.errorCount > 0 {
                                    Text("\(agent.errorCount) errors")
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "person.2")
                }
                .help("Choose an agent to inspect")
                Button {
                    setZoom(zoom - 0.15)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .help("Zoom out")
                Button {
                    setZoom(zoom + 0.15)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .help("Zoom in")
                Button {
                    resetGraphView()
                } label: {
                    Image(systemName: "arrow.up.left.and.down.right.magnifyingglass")
                }
                .help("Reset graph view")
            }
            HStack(spacing: 8) {
                Label("Viewing: \(store.transcriptFilterLabel)", systemImage: "line.3.horizontal.decrease.circle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding([.top, .horizontal])
    }

    private var graphCanvas: some View {
        GeometryReader { proxy in
            let layout = layout(size: proxy.size)
            let transformedPositions = layout.positions.mapValues { transform($0, contentSize: layout.contentSize, in: proxy.size) }
            ZStack {
                Canvas { context, size in
                    drawWorkflowGroups(context: &context, size: size, layout: layout)
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
            .onAppear {
                graphViewportSize = proxy.size
                pan = focusedPan(pan, viewport: proxy.size, contentSize: layout.contentSize)
            }
            .onChange(of: proxy.size) { _, newSize in
                graphViewportSize = newSize
                pan = focusedPan(pan, viewport: newSize, contentSize: self.layout(size: newSize).contentSize)
            }
        }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let start = panStart ?? pan
                panStart = start
                let proposedPan = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
                guard graphViewportSize != .zero else {
                    pan = proposedPan
                    return
                }
                pan = boundedPan(proposedPan, viewport: graphViewportSize, contentSize: layout(size: graphViewportSize).contentSize)
            }
            .onEnded { _ in
                panStart = nil
                guard graphViewportSize != .zero else { return }
                pan = boundedPan(pan, viewport: graphViewportSize, contentSize: layout(size: graphViewportSize).contentSize)
            }
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let start = zoomStart ?? zoom
                zoomStart = start
                setZoom(start * value)
            }
            .onEnded { _ in
                zoomStart = nil
                guard graphViewportSize != .zero else { return }
                pan = focusedPan(pan, viewport: graphViewportSize, contentSize: layout(size: graphViewportSize).contentSize)
            }
    }

    private func drawEdges(context: inout GraphicsContext, size: CGSize, layout: GraphLayout) {
        let bucketCounts = Dictionary(grouping: graph.edges, by: edgeBucketKey).mapValues(\.count)
        var endpointCounts: [String: Int] = [:]
        var edgeIndexes: [String: Int] = [:]
        var upwardMessageRouteIndex = 0
        var downwardFanoutRouteIndexes: [String: Int] = [:]
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
            var routeOffset = CGFloat(bucketIndex) - CGFloat((bucketCounts[bucket] ?? 1) - 1) / 2
            if edge.kind == .message, abs(start.x - end.x) <= 24, start.y > end.y {
                routeOffset += CGFloat(upwardMessageRouteIndex)
                upwardMessageRouteIndex += 1
            }
            if abs(start.x - end.x) <= 24, end.y > start.y, abs(start.y - end.y) > nodeGap.height * zoom * 1.5 {
                let routeIndex = downwardFanoutRouteIndexes[edge.from, default: 0]
                routeOffset += CGFloat(routeIndex + 1)
                downwardFanoutRouteIndexes[edge.from] = routeIndex + 1
            }
            let route = edgeRoute(from: start, to: end, offset: routeOffset)
            let style = StrokeStyle(lineWidth: edge.active ? 2.5 : 1.5, dash: edge.kind == .message ? [5, 5] : [])
            context.stroke(route.path, with: .color(edge.active ? .accentColor : .secondary), style: style)
            drawArrowhead(context: context, from: route.arrowFrom, to: end, active: edge.active)
            endpointCounts["\(Int(end.x)):\(Int(end.y))", default: 0] += 1
            let radius = endpointCounts["\(Int(end.x)):\(Int(end.y))", default: 1] > 1 ? 4.5 : 3.5
            context.fill(Path(ellipseIn: CGRect(x: end.x - radius, y: end.y - radius, width: radius * 2, height: radius * 2)), with: .color(edge.active ? .accentColor : .secondary))
        }
    }

    private func drawWorkflowGroups(context: inout GraphicsContext, size: CGSize, layout: GraphLayout) {
        for group in layout.workflowGroups {
            let minPoint = transform(CGPoint(x: group.rect.minX, y: group.rect.minY), contentSize: layout.contentSize, in: size)
            let maxPoint = transform(CGPoint(x: group.rect.maxX, y: group.rect.maxY), contentSize: layout.contentSize, in: size)
            let rect = CGRect(
                x: min(minPoint.x, maxPoint.x),
                y: min(minPoint.y, maxPoint.y),
                width: abs(maxPoint.x - minPoint.x),
                height: abs(maxPoint.y - minPoint.y)
            )
            let fillOpacity = group.level == 0 ? 0.04 : 0.05
            let strokeOpacity = group.level == 0 ? 0.12 : 0.13
            let cornerRadius: CGFloat = group.level == 0 ? 14 : 11
            context.fill(Path(roundedRect: rect, cornerRadius: cornerRadius), with: .color(.secondary.opacity(fillOpacity)))
            context.stroke(Path(roundedRect: rect, cornerRadius: cornerRadius), with: .color(.secondary.opacity(strokeOpacity)), lineWidth: group.level == 0 ? 1 : 0.8)
            context.draw(
                Text(group.label).font(.caption.weight(.semibold)).foregroundStyle(.secondary.opacity(group.level == 0 ? 0.82 : 0.74)),
                at: CGPoint(x: rect.minX + 14, y: rect.minY + 14),
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
            context.fill(Path(roundedRect: rect, cornerRadius: 8), with: .color(roleColor.opacity(0.09)))
            context.stroke(Path(roundedRect: rect, cornerRadius: 8), with: .color(stateColor.opacity(0.78)), lineWidth: node.status == .idle ? 1.2 : 2)
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
        guard !graph.nodes.isEmpty else { return GraphLayout(contentSize: size, positions: [:], workflowGroups: []) }
        let groups = groupedNodes()
        let cell = CGSize(width: nodeSize.width + nodeGap.width, height: nodeSize.height + nodeGap.height)
        let availableColumns = max(1, Int(floor(max(cell.width, size.width - contentPadding * 2) / cell.width)))
        let groupColumns = groups.map { min(max(1, $0.nodes.count), availableColumns) }
        let maxColumns = max(1, groupColumns.max() ?? 1)
        let groupRows = zip(groups, groupColumns).map { group, columns in
            max(1, Int(ceil(Double(group.nodes.count) / Double(columns))))
        }
        let totalRows = groupRows.reduce(0, +)
        let contentSize = CGSize(
            width: max(size.width, CGFloat(maxColumns) * cell.width + contentPadding * 2),
            height: max(size.height, CGFloat(totalRows) * cell.height + contentPadding * 2)
        )
        var positions: [String: CGPoint] = [:]
        var rowOffset = 0
        for (groupIndex, group) in groups.enumerated() {
            let columns = groupColumns[groupIndex]
            let rows = groupRows[groupIndex]
            let groupWidth = CGFloat(columns) * cell.width
            let xOffset = max(contentPadding, (contentSize.width - groupWidth) / 2)
            let y = contentPadding + cell.height * CGFloat(rowOffset) + nodeSize.height / 2
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
        return GraphLayout(
            contentSize: contentSize,
            positions: positions,
            workflowGroups: workflowGroups(contentSize: contentSize, positions: positions)
        )
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

    private func workflowGroups(contentSize: CGSize, positions: [String: CGPoint]) -> [GraphWorkflowGroup] {
        guard !positions.isEmpty else { return [] }
        var groups: [GraphWorkflowGroup] = [
            GraphWorkflowGroup(
                label: "Session",
                rect: boundingRect(for: Array(positions.keys), positions: positions, padding: CGSize(width: 76, height: 72))
                    .union(CGRect(x: contentPadding / 2, y: contentPadding / 2, width: contentSize.width - contentPadding, height: contentSize.height - contentPadding)),
                level: 0
            )
        ]

        let memberships = workflowMemberships()
        var explicitlyGroupedNodeIds = Set<String>()
        if !memberships.isEmpty {
            let grouped = Dictionary(grouping: memberships) { entry in entry.value.key }
            for (key, entries) in grouped.sorted(by: { $0.key < $1.key }) {
                let ids = entries.map(\.key).filter { positions[$0] != nil }
                guard !ids.isEmpty else { continue }
                explicitlyGroupedNodeIds.formUnion(ids)
                groups.append(GraphWorkflowGroup(
                    label: entries.first?.value.label ?? key,
                    rect: boundingRect(for: ids, positions: positions, padding: workflowGroupPadding),
                    level: 1
                ))
            }
        }
        for group in defaultWorkflowGroups() {
            let ids = group.nodeIds
                .filter { positions[$0] != nil }
                .filter { !explicitlyGroupedNodeIds.contains($0) }
            guard !ids.isEmpty else { continue }
            groups.append(GraphWorkflowGroup(
                label: group.label,
                rect: boundingRect(for: ids, positions: positions, padding: workflowGroupPadding),
                level: 1
            ))
        }

        return groups
    }

    private func defaultWorkflowGroups() -> [(label: String, nodeIds: [String])] {
        [
            ("Planning", graph.nodes.filter { matches($0, terms: ["orchestrator", "planner", "plan"]) }.map(\.id)),
            ("Implementation", graph.nodes.filter { matches($0, terms: ["implement", "build", "engineer"]) }.map(\.id)),
            ("Review / QA", graph.nodes.filter { matches($0, terms: ["review", "qa", "test", "quality"]) }.map(\.id))
        ]
    }

    private func matches(_ node: AgentNode, terms: [String]) -> Bool {
        let haystack = "\(node.id) \(node.roleId) \(node.label)".lowercased()
        return terms.contains { haystack.contains($0) }
    }

    private func boundingRect(for nodeIds: [String], positions: [String: CGPoint], padding: CGSize) -> CGRect {
        let rects = nodeIds.compactMap { nodeId -> CGRect? in
            guard let position = positions[nodeId] else { return nil }
            return nodeRect(center: position, size: nodeSize)
        }
        guard let first = rects.first else { return .zero }
        return rects.dropFirst()
            .reduce(first) { $0.union($1) }
            .insetBy(dx: -padding.width, dy: -padding.height)
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
            let membership = WorkflowMembership(
                key: workflowInstanceId,
                label: workflowLaneLabel(workflowId: workflowId, ordinal: ordinal, instanceId: workflowInstanceId)
            )
            for value in nodeMap.values {
                guard let agentId = value.stringValue else { continue }
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
        let visiblePan = boundedPan(pan, viewport: viewport, contentSize: contentSize)
        return CGPoint(
            x: (point.x - contentSize.width / 2) * zoom + viewport.width / 2 + visiblePan.width,
            y: (point.y - contentSize.height / 2) * zoom + viewport.height / 2 + visiblePan.height
        )
    }

    private func setZoom(_ proposedZoom: CGFloat) {
        zoom = min(2.2, max(0.55, proposedZoom))
        guard graphViewportSize != .zero else { return }
        pan = focusedPan(pan, viewport: graphViewportSize, contentSize: layout(size: graphViewportSize).contentSize)
    }

    private func applyGraphCommand(_ command: GraphViewCommand) {
        switch command {
        case .zoomIn:
            setZoom(zoom + 0.15)
        case .zoomOut:
            setZoom(zoom - 0.15)
        case .reset:
            resetGraphView()
        }
    }

    private func handleGraphCommandRequest(_ request: GraphViewCommandRequest?) {
        guard let request, request.id != handledCommandId else { return }
        handledCommandId = request.id
        applyGraphCommand(request.command)
    }

    private func resetGraphView() {
        zoom = 1
        pan = .zero
    }

    private func focusedPan(_ proposedPan: CGSize, viewport: CGSize, contentSize: CGSize) -> CGSize {
        guard viewport != .zero else { return proposedPan }
        guard let selectedAgentId = store.selectedAgentId,
              let point = layout(size: viewport).positions[selectedAgentId] else {
            return boundedPan(proposedPan, viewport: viewport, contentSize: contentSize)
        }

        var adjusted = proposedPan
        let center = CGPoint(
            x: (point.x - contentSize.width / 2) * zoom + viewport.width / 2 + adjusted.width,
            y: (point.y - contentSize.height / 2) * zoom + viewport.height / 2 + adjusted.height
        )
        let rect = nodeRect(center: center, size: scaledNodeSize)
        let margin: CGFloat = 22
        if rect.minX < margin {
            adjusted.width += margin - rect.minX
        } else if rect.maxX > viewport.width - margin {
            adjusted.width -= rect.maxX - (viewport.width - margin)
        }
        if rect.minY < margin {
            adjusted.height += margin - rect.minY
        } else if rect.maxY > viewport.height - margin {
            adjusted.height -= rect.maxY - (viewport.height - margin)
        }
        return boundedPan(adjusted, viewport: viewport, contentSize: contentSize)
    }

    private func boundedPan(_ proposedPan: CGSize, viewport: CGSize, contentSize: CGSize) -> CGSize {
        guard viewport != .zero else { return proposedPan }
        let scaledContent = CGSize(width: contentSize.width * zoom, height: contentSize.height * zoom)
        let horizontalOverflow = max(0, scaledContent.width - viewport.width)
        let verticalOverflow = max(0, scaledContent.height - viewport.height)
        let horizontalLimit = horizontalOverflow / 2 + 24
        let verticalLimit = verticalOverflow / 2 + 24
        return CGSize(
            width: min(horizontalLimit, max(-horizontalLimit, proposedPan.width)),
            height: min(verticalLimit, max(-verticalLimit, proposedPan.height))
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
        if abs(start.x - end.x) <= 24, abs(start.y - end.y) > 24, start.y > end.y {
            let sideX = start.x + scaledNodeSize.width / 2 + 24 + abs(offset) * 10
            let beforeEnd = CGPoint(x: sideX, y: end.y)
            path.addLine(to: CGPoint(x: sideX, y: start.y))
            path.addLine(to: beforeEnd)
            path.addLine(to: end)
            return (path, beforeEnd)
        }
        if abs(start.x - end.x) <= 24, end.y > start.y, abs(start.y - end.y) > nodeGap.height * zoom * 1.5 {
            let sideX = start.x - scaledNodeSize.width / 2 - 24 - abs(offset) * 10
            let beforeEnd = CGPoint(x: sideX, y: end.y)
            path.addLine(to: CGPoint(x: sideX, y: start.y))
            path.addLine(to: beforeEnd)
            path.addLine(to: end)
            return (path, beforeEnd)
        }
        if abs(start.y - end.y) <= 24, abs(start.x - end.x) > 24, abs(offset) > 0.1 {
            let direction: CGFloat = offset >= 0 ? 1 : -1
            let midY = start.y + direction * (20 + abs(offset) * 12)
            let beforeEnd = CGPoint(x: end.x, y: midY)
            path.addLine(to: CGPoint(x: start.x, y: midY))
            path.addLine(to: beforeEnd)
            path.addLine(to: end)
            return (path, beforeEnd)
        }
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
        [edge.from, edge.to].sorted().joined(separator: "<->")
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
        return parts.joined(separator: ", ")
    }
}

private struct GraphLayout {
    let contentSize: CGSize
    let positions: [String: CGPoint]
    let workflowGroups: [GraphWorkflowGroup]
}

private struct GraphWorkflowGroup {
    let label: String
    let rect: CGRect
    let level: Int
}

private struct GraphNodeGroup {
    let label: String
    let nodes: [AgentNode]
}

private struct WorkflowMembership {
    let key: String
    let label: String
}
