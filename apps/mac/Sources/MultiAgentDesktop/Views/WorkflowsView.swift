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
                Text("Workflows")
                    .font(.title2.weight(.semibold))
                    .padding()

                List(selection: $selectedWorkflowId) {
                    ForEach(store.workflows) { workflow in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(workflow.name)
                                .lineLimit(1)
                            Text(workflow.description)
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
                WorkflowDetail(workflow: workflow, targetSessionTitle: store.sessions.first(where: { $0.id == store.selectedSessionId })?.title, canInstantiate: store.hasActiveSession) {
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
                        Text(workflow.description)
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
                        Text(targetSessionTitle.map { "Target: \($0)" } ?? "Select a session target")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Nodes", value: "\(workflow.nodes.count)")
                LabeledContent("Edges", value: "\(workflow.edges.count)")

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
                    ForEach(workflow.edges) { edge in
                        Label("\(edge.from) -> \(edge.to)", systemImage: edge.kind == .handoff ? "arrow.right" : "ellipsis.message")
                            .help(edge.description)
                    }
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
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
