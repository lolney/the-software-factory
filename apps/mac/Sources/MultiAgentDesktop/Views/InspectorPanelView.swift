import SwiftUI

struct InspectorPanelView: View {
    @Bindable var store: SessionStore

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $store.inspectorPanel) {
                ForEach(InspectorPanel.allCases) { panel in
                    Text(panel.rawValue).tag(panel)
                }
            }
            .pickerStyle(.segmented)
            .padding([.top, .horizontal])

            Divider()

            switch store.inspectorPanel {
            case .graph:
                GraphPanelView(store: store)
            case .plan:
                PlanInspectorPanelView(store: store)
            case .workspace:
                WorkspacePanelView(store: store)
            case .debug:
                DebugLogPanelView(store: store)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PlanInspectorPanelView: View {
    @Bindable var store: SessionStore

    private var latestPlan: TranscriptItem? {
        store.transcript.last { $0.type == "plan.created" && $0.payload["plan"]?.objectValue != nil }
    }

    private var planObject: [String: JSONValue]? {
        latestPlan?.payload["plan"]?.objectValue
    }

    private var planId: String? {
        planObject?["id"]?.stringValue
    }

    private var workflows: [[String: JSONValue]] {
        planObject?["workflows"]?.arrayValue?.compactMap(\.objectValue) ?? []
    }

    private var planInstantiatedEvent: TranscriptItem? {
        guard let planId else { return nil }
        return store.transcript.last {
            $0.type == "plan.instantiated" && $0.payload["planId"]?.stringValue == planId
        }
    }

    private var scopedWorkflowInstantiations: [TranscriptItem] {
        guard let planInstantiatedEvent else { return [] }
        let workflowIds = Set(workflows.compactMap { $0["workflowId"]?.stringValue })
        return store.transcript.filter {
            $0.type == "workflow.instantiated"
                && $0.causationId == planInstantiatedEvent.id
                && workflowIds.contains($0.payload["workflowId"]?.stringValue ?? "")
        }
    }

    private var criterionRows: [PlanCriterionRow] {
        var rows: [String: PlanCriterionRow] = [:]
        if let latestPlan,
           let globalCriteria = planObject?["globalDoneCriteria"]?.arrayValue?.compactMap(\.stringValue) {
            for (index, description) in globalCriteria.enumerated() {
                let id = "global_\(index + 1)"
                rows[id] = PlanCriterionRow(
                    id: id,
                    description: description,
                    ownerAgentId: nil,
                    ownerLabel: nil,
                    workflowId: "Global",
                    workflowInstanceId: nil,
                    status: "planned",
                    eventId: latestPlan.id,
                    timestamp: latestPlan.timestamp
                )
            }
        }

        let instantiatedWorkflowIds = Set(scopedWorkflowInstantiations.compactMap { $0.payload["workflowId"]?.stringValue })
        for workflow in workflows {
            guard let workflowId = workflow["workflowId"]?.stringValue,
                  !instantiatedWorkflowIds.contains(workflowId),
                  let doneCriteria = workflow["doneCriteria"]?.objectValue else { continue }
            for owner in doneCriteria.keys.sorted() {
                let criteria = doneCriteria[owner]?.arrayValue?.compactMap(\.stringValue) ?? []
                for (index, description) in criteria.enumerated() {
                    let id = "planned_\(workflowId)_\(owner)_\(index + 1)"
                    rows[id] = PlanCriterionRow(
                        id: id,
                        description: description,
                        ownerAgentId: nil,
                        ownerLabel: owner,
                        workflowId: workflowId,
                        workflowInstanceId: nil,
                        status: "planned",
                        eventId: latestPlan?.id ?? id,
                        timestamp: latestPlan?.timestamp ?? Date()
                    )
                }
            }
        }

        let scopedWorkflowInstanceIds = Set(scopedWorkflowInstantiations.compactMap { $0.payload["workflowInstanceId"]?.stringValue })
        for item in scopedWorkflowInstantiations {
            guard let workflowInstanceId = item.payload["workflowInstanceId"]?.stringValue else { continue }
            let workflowId = item.payload["workflowId"]?.stringValue
            let criteria = item.payload["completionCriteria"]?.arrayValue?.compactMap(\.objectValue) ?? []
            for criterion in criteria {
                guard let criterionId = criterion["id"]?.stringValue else { continue }
                let key = "\(workflowInstanceId):\(criterionId)"
                rows[key] = PlanCriterionRow(
                    id: key,
                    description: criterion["description"]?.stringValue ?? criterionId,
                    ownerAgentId: criterion["ownerNodeId"]?.stringValue,
                    ownerLabel: criterion["ownerNodeId"]?.stringValue,
                    workflowId: workflowId,
                    workflowInstanceId: workflowInstanceId,
                    status: "pending",
                    eventId: item.id,
                    timestamp: item.timestamp
                )
            }
        }

        for item in store.transcript where item.type == "completion.criterion.updated" {
            guard let workflowInstanceId = item.payload["workflowInstanceId"]?.stringValue,
                  scopedWorkflowInstanceIds.contains(workflowInstanceId) else { continue }
            guard let criterionId = item.payload["criterionId"]?.stringValue else { continue }
            let criterion = item.payload["criterion"]?.objectValue
            let key = "\(workflowInstanceId):\(criterionId)"
            rows[key] = PlanCriterionRow(
                id: key,
                description: criterion?["description"]?.stringValue ?? criterionId,
                ownerAgentId: item.payload["ownerAgentId"]?.stringValue ?? criterion?["ownerNodeId"]?.stringValue,
                ownerLabel: item.payload["ownerAgentId"]?.stringValue ?? criterion?["ownerNodeId"]?.stringValue,
                workflowId: item.payload["workflowId"]?.stringValue,
                workflowInstanceId: workflowInstanceId,
                status: item.payload["status"]?.stringValue ?? "pending",
                eventId: item.id,
                timestamp: item.timestamp
            )
        }
        for item in store.transcript where item.type == "workflow.completed" {
            guard let workflowInstanceId = item.payload["workflowInstanceId"]?.stringValue,
                  scopedWorkflowInstanceIds.contains(workflowInstanceId) else { continue }
            let workflowId = item.payload["workflowId"]?.stringValue
            let criteria = item.payload["completionCriteria"]?.arrayValue?.compactMap(\.objectValue) ?? []
            for criterion in criteria {
                guard let criterionId = criterion["id"]?.stringValue else { continue }
                let key = "\(workflowInstanceId):\(criterionId)"
                rows[key] = PlanCriterionRow(
                    id: key,
                    description: rows[key]?.description ?? criterion["description"]?.stringValue ?? criterionId,
                    ownerAgentId: rows[key]?.ownerAgentId ?? criterion["ownerNodeId"]?.stringValue,
                    ownerLabel: rows[key]?.ownerLabel ?? criterion["ownerNodeId"]?.stringValue,
                    workflowId: rows[key]?.workflowId ?? workflowId,
                    workflowInstanceId: workflowInstanceId,
                    status: "completed",
                    eventId: item.id,
                    timestamp: item.timestamp
                )
            }
        }
        return rows.values.sorted { left, right in
            let leftRank = statusRank(left.status)
            let rightRank = statusRank(right.status)
            if leftRank == rightRank {
                if left.workflowId == right.workflowId { return left.id < right.id }
                return (left.workflowId ?? "") < (right.workflowId ?? "")
            }
            return leftRank < rightRank
        }
    }

    private var workflowRows: [PlanWorkflowStatusRow] {
        let scopedInstantiations = scopedWorkflowInstantiations
        return workflows.map { workflow in
            let workflowId = workflow["workflowId"]?.stringValue ?? "workflow"
            let instantiated = scopedInstantiations.last { $0.payload["workflowId"]?.stringValue == workflowId }
            let completed = store.transcript.last {
                $0.type == "workflow.completed"
                    && $0.payload["workflowId"]?.stringValue == workflowId
                    && $0.payload["workflowInstanceId"]?.stringValue == instantiated?.payload["workflowInstanceId"]?.stringValue
            }
            let stopped = store.transcript.last {
                $0.type == "workflow.stopped"
                    && $0.payload["workflowId"]?.stringValue == workflowId
                    && $0.payload["workflowInstanceId"]?.stringValue == instantiated?.payload["workflowInstanceId"]?.stringValue
            }
            return PlanWorkflowStatusRow(
                id: workflowId,
                status: completed != nil ? "completed" : stopped != nil ? "stopped" : instantiated != nil ? "running" : "planned",
                workflowInstanceId: completed?.payload["workflowInstanceId"]?.stringValue ?? stopped?.payload["workflowInstanceId"]?.stringValue ?? instantiated?.payload["workflowInstanceId"]?.stringValue,
                eventId: completed?.id ?? stopped?.id ?? instantiated?.id
            )
        }
    }

    private func statusRank(_ status: String) -> Int {
        switch status {
        case "pending": 0
        case "planned": 1
        case "completed": 3
        default: 2
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Plan")
                    .font(.headline)
                Spacer()
                if let latestPlan {
                    Button {
                        store.selectAgent(nil)
                        store.transcriptSearchText = latestPlan.id
                    } label: {
                        Label("Find Event", systemImage: "magnifyingglass")
                    }
                    .help("Filter the transcript to the plan event")
                }
            }
            .padding()

            if let plan = planObject {
                List {
                    Section("Goal") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(plan["name"]?.stringValue ?? "Untitled plan")
                                .font(.callout.weight(.semibold))
                            Text(plan["goal"]?.stringValue ?? store.selectedSessionId ?? "No goal recorded")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 4)
                    }

                    if !workflowRows.isEmpty {
                        Section("Workflows") {
                            ForEach(workflowRows) { row in
                                PlanWorkflowStatusView(row: row)
                            }
                        }
                    }

                    if !criterionRows.isEmpty {
                        Section("Completion Criteria") {
                            ForEach(criterionRows) { row in
                                PlanCriterionStatusView(row: row) {
                                    if let owner = row.ownerAgentId {
                                        store.selectAgent(owner)
                                    }
                                }
                            }
                        }
                    }

                    Section("Agent Prompts") {
                        ForEach(workflows, id: \.self) { workflow in
                            PlanWorkflowPromptView(workflow: workflow)
                        }
                    }
                }
                .listStyle(.inset)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label("No plan yet", systemImage: "checklist")
                        .font(.callout.weight(.semibold))
                    Text("Planner-created plans and completion criteria will appear here after the session emits plan events.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.quaternary)
                }
                .padding(.horizontal)
                .padding(.top, 4)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct PlanWorkflowStatusRow: Identifiable, Hashable {
    let id: String
    let status: String
    let workflowInstanceId: String?
    let eventId: String?
}

private struct PlanCriterionRow: Identifiable, Hashable {
    let id: String
    let description: String
    let ownerAgentId: String?
    let ownerLabel: String?
    let workflowId: String?
    let workflowInstanceId: String?
    let status: String
    let eventId: String
    let timestamp: Date
}

private struct PlanWorkflowStatusView: View {
    let row: PlanWorkflowStatusRow

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.id)
                    .font(.callout.weight(.medium))
                if let workflowInstanceId = row.workflowInstanceId {
                    Text(workflowInstanceId)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(row.status)
                .font(.caption)
                .foregroundStyle(color)
        }
        .padding(.vertical, 3)
    }

    private var icon: String {
        switch row.status {
        case "completed": "checkmark.circle.fill"
        case "stopped": "xmark.octagon"
        case "running": "clock"
        default: "circle"
        }
    }

    private var color: Color {
        switch row.status {
        case "completed": .green
        case "stopped": .orange
        case "running": .blue
        default: .secondary
        }
    }
}

private struct PlanCriterionStatusView: View {
    let row: PlanCriterionRow
    let selectOwner: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: row.status == "completed" ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(row.status == "completed" ? .green : .secondary)
                    .frame(width: 16)
                Text(row.description)
                    .font(.callout)
                Spacer()
                Text(row.status)
                    .font(.caption)
                    .foregroundStyle(row.status == "completed" ? .green : .secondary)
            }
            HStack(spacing: 10) {
                if let owner = row.ownerAgentId {
                    Button(owner) {
                        selectOwner()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                } else if let ownerLabel = row.ownerLabel {
                    Text(ownerLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let workflowId = row.workflowId {
                    Text(workflowId)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let workflowInstanceId = row.workflowInstanceId {
                    Text(workflowInstanceId)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(row.eventId)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(row.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct PlanWorkflowPromptView: View {
    let workflow: [String: JSONValue]
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    promptBlock(title: "Prompts", object: workflow["agentPrompts"]?.objectValue)
                    criteriaBlock(title: "Done Criteria", object: workflow["doneCriteria"]?.objectValue)
                }
                .padding(.top, 4)
            }
        } label: {
            Text(workflow["workflowId"]?.stringValue ?? "Workflow")
                .font(.callout.weight(.medium))
        }
    }

    @ViewBuilder
    private func promptBlock(title: String, object: [String: JSONValue]?) -> some View {
        if let object, !object.isEmpty {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(object.keys.sorted(), id: \.self) { key in
                VStack(alignment: .leading, spacing: 2) {
                    Text(key)
                        .font(.caption.weight(.medium))
                    Text(object[key]?.stringValue ?? object[key]?.searchText ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func criteriaBlock(title: String, object: [String: JSONValue]?) -> some View {
        if let object, !object.isEmpty {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(object.keys.sorted(), id: \.self) { key in
                let values = object[key]?.arrayValue?.compactMap(\.stringValue) ?? []
                VStack(alignment: .leading, spacing: 2) {
                    Text(key)
                        .font(.caption.weight(.medium))
                    ForEach(values, id: \.self) { value in
                        Text("- \(value)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct WorkspacePanelView: View {
    @Bindable var store: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Workspace")
                    .font(.headline)
                Spacer()
                Button {
                    store.copyCurrentWorkspacePath()
                } label: {
                    Label("Copy Path", systemImage: "doc.on.doc")
                }
                .disabled(store.currentWorkspaceRoot == nil)
                Button {
                    store.openWorkspace(tool: .finder)
                } label: {
                    Label("Finder", systemImage: "folder")
                }
                .disabled(store.currentWorkspaceRoot == nil)
            }
            .padding()

            if let root = store.currentWorkspaceRoot {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Root")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(root)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(3)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 12)

                    Divider()

                    if store.touchedWorkspaceFiles.isEmpty {
                        emptyState(
                            title: "No file activity yet",
                            detail: "Touched files, diff stats, and conflicts will appear here after agents edit the workspace."
                        )
                        Spacer(minLength: 0)
                    } else {
                        List(store.touchedWorkspaceFiles) { file in
                            WorkspaceFileRow(file: file)
                        }
                        .listStyle(.inset)
                    }
                }
            } else {
                emptyState(
                    title: "No workspace selected",
                    detail: "Create or select a session to inspect workspace activity."
                )
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func emptyState(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "folder.badge.questionmark")
                .font(.callout.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary)
        }
        .padding(.horizontal)
        .padding(.top, 4)
    }
}

private struct WorkspaceFileRow: View {
    let file: WorkspaceFileSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(file.path)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if file.conflictCount > 0 {
                    Text("!\(file.conflictCount)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.red)
                }
            }
            HStack(spacing: 10) {
                Text(file.lastAgentId ?? "system")
                Text(file.lastEventType.replacingOccurrences(of: "workspace.", with: ""))
                if file.additions > 0 || file.deletions > 0 {
                    Text("+\(file.additions) -\(file.deletions)")
                        .foregroundStyle(diffColor)
                }
                Spacer()
                Text(file.lastTimestamp, style: .time)
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var diffColor: Color {
        file.deletions > file.additions ? .orange : .green
    }
}

struct DebugLogPanelView: View {
    @Bindable var store: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Session Debug")
                    .font(.headline)
                Spacer()
                Text("\(store.debugLogs.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding()

            if store.debugLogs.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("No debug logs yet", systemImage: "text.badge.magnifyingglass")
                        .font(.callout.weight(.semibold))
                    Text("Logs stream here after the session emits events or errors.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.quaternary)
                }
                .padding(.horizontal)
                .padding(.top, 4)
                Spacer(minLength: 0)
            } else {
                List(store.debugLogs) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(entry.level.rawValue.uppercased())
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(color(for: entry.level))
                                .frame(width: 42, alignment: .leading)
                            Text(entry.source)
                                .font(.caption.weight(.semibold))
                            if let agentId = entry.agentId {
                                Text(agentId)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(format(timestamp: entry.timestamp))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Text(entry.message)
                            .font(.callout)
                            .textSelection(.enabled)
                        if let eventType = entry.payload["eventType"]?.stringValue {
                            Text(eventType)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func color(for level: DebugLogLevel) -> Color {
        switch level {
        case .debug: .secondary
        case .info: .blue
        case .warn: .orange
        case .error: .red
        }
    }

    private func format(timestamp: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: timestamp) else { return timestamp }
        return date.formatted(date: .omitted, time: .shortened)
    }
}
