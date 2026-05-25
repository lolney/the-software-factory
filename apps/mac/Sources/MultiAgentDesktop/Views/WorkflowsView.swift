import SwiftUI

struct WorkflowsView: View {
    @Bindable var store: SessionStore
    @State private var selectedWorkflowId: String?

    private var selectedWorkflow: WorkflowSpec? {
        guard let selectedWorkflowId else { return store.workflows.first }
        return store.workflows.first { $0.id == selectedWorkflowId }
    }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Workflows")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Button {
                        store.copyPersonalWorkflowsPath()
                    } label: {
                        Label("Copy Path", systemImage: "doc.on.doc")
                    }
                    .help(store.personalWorkflowsPath ?? "Personal workflows directory")
                    Button {
                        store.addWorkflowFile()
                    } label: {
                        Label("Add Workflow", systemImage: "plus")
                    }
                    .help("Add a blank workflow JSON file")
                }
                .padding()

                List(selection: $selectedWorkflowId) {
                    ForEach(store.workflows) { workflow in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(workflow.name.isEmpty ? workflow.id : workflow.name)
                                .lineLimit(1)
                            Text(workflow.description.isEmpty ? "Draft workflow JSON" : workflow.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .tag(workflow.id)
                    }
                }
            }
            .frame(minWidth: 280, idealWidth: 340)

            if let workflow = selectedWorkflow {
                WorkflowDetail(workflow: workflow, targetSessionTitle: (store.sessions + store.archivedSessions).first(where: { $0.id == store.selectedSessionId })?.title, canInstantiate: store.hasActiveSession && !store.selectedSessionArchived && workflow.isInstantiable) {
                    store.instantiateWorkflow(workflow.id)
                }
                .frame(minWidth: 560)
            } else {
                ContentUnavailableView("No Workflows", systemImage: "point.3.connected.trianglepath.dotted")
                    .frame(minWidth: 560)
            }
        }
        .task {
            store.refreshCatalogs()
            selectedWorkflowId = selectedWorkflowId ?? store.workflows.first?.id
        }
    }
}

private struct WorkflowDetail: View {
    let workflow: WorkflowSpec
    let targetSessionTitle: String?
    let canInstantiate: Bool
    let instantiate: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(workflow.name)
                            .font(.title2.weight(.semibold))
                        Text(workflow.description.isEmpty ? workflow.id : workflow.description)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        Button {
                            instantiate()
                        } label: {
                            Label("Instantiate", systemImage: "plus.square.on.square")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canInstantiate)
                        Text(instantiateHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Nodes", value: "\(workflow.nodes.count)")
                LabeledContent("Edges", value: "\(workflow.edges.count)")

                VStack(alignment: .leading, spacing: 8) {
                    Text("Node Dependencies")
                        .font(.headline)
                    ForEach(workflow.nodes) { node in
                        HStack(alignment: .firstTextBaseline) {
                            Text(node.label)
                                .font(.callout.weight(.medium))
                            Spacer()
                            Text((node.dependencies ?? []).isEmpty ? "None" : (node.dependencies ?? []).joined(separator: ", "))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Roles")
                        .font(.headline)
                    ForEach(workflow.roles) { role in
                        HStack {
                            Circle()
                                .fill(Color(hex: role.color))
                                .frame(width: 9, height: 9)
                            Text(role.name)
                            Spacer()
                            Text(role.model)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Graph")
                        .font(.headline)
                    WorkflowSpecGraphView(workflow: workflow)
                        .frame(height: 280)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))

                    HStack(spacing: 12) {
                        Label("Handoff", systemImage: "arrow.right")
                        Label("Message", systemImage: "ellipsis.message")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if !workflow.stopCriteria.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Stop Criteria")
                            .font(.headline)
                        ForEach(workflow.stopCriteria, id: \.self) { criterion in
                            Text(criterion)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let completionCriteria = workflow.completionCriteria, !completionCriteria.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Completion Criteria")
                            .font(.headline)
                        ForEach(completionCriteria) { criterion in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: criterion.required == false ? "circle" : "checkmark.circle")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(criterion.description)
                                    if let owner = criterion.ownerNodeId {
                                        Text(owner)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var instantiateHint: String {
        if !workflow.isInstantiable {
            return "Complete the workflow JSON before instantiating"
        }
        return targetSessionTitle.map { "Target: \($0)" } ?? "Select a session target"
    }
}

private struct WorkflowSpecGraphView: View {
    let workflow: WorkflowSpec

    private var rolesById: [String: RoleSpec] {
        Dictionary(uniqueKeysWithValues: workflow.roles.map { ($0.id, $0) })
    }

    var body: some View {
        GeometryReader { proxy in
            let positions = layout(size: proxy.size)
            ZStack {
                Canvas { context, size in
                    let positions = layout(size: size)
                    for edge in workflow.edges {
                        guard let start = positions[edge.from], let end = positions[edge.to] else { continue }
                        let offset = reciprocalOffset(for: edge)
                        var path = Path()
                        path.move(to: start)
                        if offset == 0 {
                            path.addLine(to: end)
                        } else {
                            path.addQuadCurve(to: end, control: controlPoint(from: start, to: end, offset: offset))
                        }
                        context.stroke(path, with: .color(.secondary), style: StrokeStyle(lineWidth: 1.5, dash: edge.kind == .message ? [5, 5] : []))
                        drawArrowhead(context: context, from: offset == 0 ? start : controlPoint(from: start, to: end, offset: offset), to: end)
                    }

                    for node in workflow.nodes {
                        guard let point = positions[node.id] else { continue }
                        let color = color(for: node)
                        let rect = CGRect(x: point.x - 66, y: point.y - 28, width: 132, height: 56)
                        context.fill(Path(roundedRect: rect, cornerRadius: 8), with: .color(color.opacity(0.16)))
                        context.stroke(Path(roundedRect: rect, cornerRadius: 8), with: .color(color), lineWidth: 1.8)
                        context.draw(Text(shortLabel(node.label)).font(.caption.weight(.semibold)), at: CGPoint(x: rect.midX, y: rect.midY - 6), anchor: .center)
                        context.draw(Text(node.roleId).font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: rect.midX, y: rect.midY + 12), anchor: .center)
                    }
                }

                ForEach(workflow.edges) { edge in
                    if let start = positions[edge.from], let end = positions[edge.to] {
                        Text(edge.kind == .handoff ? "handoff" : "message")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .background(.regularMaterial, in: Capsule())
                            .position(labelPoint(from: start, to: end, offset: reciprocalOffset(for: edge)))
                            .help(edge.description)
                    }
                }
            }
            .padding(8)
        }
    }

    private func layout(size: CGSize) -> [String: CGPoint] {
        guard !workflow.nodes.isEmpty else { return [:] }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = max(70, min(size.width - 160, size.height - 86) / 2.15)
        return Dictionary(uniqueKeysWithValues: workflow.nodes.enumerated().map { index, node in
            let angle = (Double(index) / Double(workflow.nodes.count)) * Double.pi * 2 - Double.pi / 2
            return (node.id, CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius))
        })
    }

    private func color(for node: WorkflowNodeSpec) -> Color {
        Color(hex: rolesById[node.roleId]?.color ?? "#7f8c8d")
    }

    private func reciprocalOffset(for edge: WorkflowEdgeSpec) -> CGFloat {
        let hasReverse = workflow.edges.contains { candidate in
            candidate.id != edge.id && candidate.from == edge.to && candidate.to == edge.from
        }
        guard hasReverse else { return 0 }
        return edge.from < edge.to ? -22 : 22
    }

    private func controlPoint(from start: CGPoint, to end: CGPoint, offset: CGFloat) -> CGPoint {
        let midpoint = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = max(sqrt(dx * dx + dy * dy), 1)
        return CGPoint(x: midpoint.x - dy / length * offset, y: midpoint.y + dx / length * offset)
    }

    private func labelPoint(from start: CGPoint, to end: CGPoint, offset: CGFloat) -> CGPoint {
        if offset == 0 {
            return CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        }
        let control = controlPoint(from: start, to: end, offset: offset)
        return CGPoint(
            x: (start.x + 2 * control.x + end.x) / 4,
            y: (start.y + 2 * control.y + end.y) / 4
        )
    }

    private func drawArrowhead(context: GraphicsContext, from start: CGPoint, to end: CGPoint) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length: CGFloat = 8
        let insetEnd = CGPoint(x: end.x - cos(angle) * 72, y: end.y - sin(angle) * 32)
        var arrow = Path()
        arrow.move(to: insetEnd)
        arrow.addLine(to: CGPoint(x: insetEnd.x - cos(angle - .pi / 6) * length, y: insetEnd.y - sin(angle - .pi / 6) * length))
        arrow.move(to: insetEnd)
        arrow.addLine(to: CGPoint(x: insetEnd.x - cos(angle + .pi / 6) * length, y: insetEnd.y - sin(angle + .pi / 6) * length))
        context.stroke(arrow, with: .color(.secondary), lineWidth: 1.5)
    }

    private func shortLabel(_ label: String) -> String {
        label.count > 18 ? "\(label.prefix(17))..." : label
    }
}

private extension WorkflowSpec {
    var isInstantiable: Bool {
        !nodes.isEmpty && nodes.contains { $0.id == "orchestrator" || $0.roleId == "orchestrator" }
    }
}
