import SwiftUI

struct GraphPanelView: View {
    let graph: GraphState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Workflow Graph")
                .font(.headline)
                .padding([.top, .horizontal])

            HStack(spacing: 12) {
                Label("Handoff", systemImage: "arrow.right")
                Label("Message", systemImage: "ellipsis.message")
                Label("Active", systemImage: "bolt.fill")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal)

            Canvas { context, size in
                let positions = layout(size: size)

                for edge in graph.edges {
                    guard let start = positions[edge.from], let end = positions[edge.to] else { continue }
                    var path = Path()
                    path.move(to: start)
                    path.addLine(to: end)
                    let style = StrokeStyle(lineWidth: edge.active ? 2.5 : 1.5, dash: edge.kind == .message ? [5, 5] : [])
                    context.stroke(path, with: .color(edge.active ? .accentColor : .secondary), style: style)
                    drawArrowhead(context: context, from: start, to: end, active: edge.active)
                }

                for node in graph.nodes {
                    guard let point = positions[node.id] else { continue }
                    let rect = CGRect(x: point.x - 72, y: point.y - 34, width: 144, height: 68)
                    context.fill(Path(roundedRect: rect, cornerRadius: 8), with: .color(Color(hex: node.colorHex).opacity(0.16)))
                    context.stroke(Path(roundedRect: rect, cornerRadius: 8), with: .color(Color(hex: node.colorHex)), lineWidth: 2)
                    context.draw(Text(node.label).font(.caption.weight(.semibold)), at: CGPoint(x: rect.midX, y: rect.midY - 8), anchor: .center)
                    context.draw(Text(node.status.rawValue).font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: rect.midX, y: rect.midY + 12), anchor: .center)
                    if node.errorCount > 0 || node.unreadCount > 0 {
                        context.draw(Text(badgeText(for: node)).font(.caption2.weight(.bold)), at: CGPoint(x: rect.maxX - 10, y: rect.minY + 10), anchor: .center)
                    }
                }
            }
            .frame(minHeight: 320)

            List(graph.nodes) { node in
                HStack {
                    Circle()
                        .fill(Color(hex: node.colorHex))
                        .frame(width: 9, height: 9)
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
                    Text(node.status.rawValue)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func layout(size: CGSize) -> [String: CGPoint] {
        guard !graph.nodes.isEmpty else { return [:] }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = max(100, min(size.width, size.height) / 2.8)
        return Dictionary(uniqueKeysWithValues: graph.nodes.enumerated().map { index, node in
            let angle = (Double(index) / Double(graph.nodes.count)) * Double.pi * 2 - Double.pi / 2
            return (node.id, CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius))
        })
    }

    private func drawArrowhead(context: GraphicsContext, from start: CGPoint, to end: CGPoint, active: Bool) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length: CGFloat = 10
        let insetEnd = CGPoint(x: end.x - cos(angle) * 78, y: end.y - sin(angle) * 38)
        var arrow = Path()
        arrow.move(to: insetEnd)
        arrow.addLine(to: CGPoint(x: insetEnd.x - cos(angle - .pi / 6) * length, y: insetEnd.y - sin(angle - .pi / 6) * length))
        arrow.move(to: insetEnd)
        arrow.addLine(to: CGPoint(x: insetEnd.x - cos(angle + .pi / 6) * length, y: insetEnd.y - sin(angle + .pi / 6) * length))
        context.stroke(arrow, with: .color(active ? .accentColor : .secondary), lineWidth: active ? 2.5 : 1.5)
    }

    private func badgeText(for node: AgentNode) -> String {
        if node.errorCount > 0 { return "!\(node.errorCount)" }
        return "\(node.unreadCount)"
    }
}
