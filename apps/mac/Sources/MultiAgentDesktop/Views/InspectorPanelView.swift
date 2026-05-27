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
    @State private var showsIdentifiers = false

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
                Spacer()
                Text(row.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if row.workflowInstanceId != nil || !row.eventId.isEmpty {
                DisclosureGroup("Identifiers", isExpanded: $showsIdentifiers) {
                    VStack(alignment: .leading, spacing: 3) {
                        if let workflowInstanceId = row.workflowInstanceId {
                            identifierLine("Workflow run", workflowInstanceId)
                        }
                        identifierLine("Event", row.eventId)
                    }
                    .padding(.top, 2)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func identifierLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
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

    private var diffEventsByPath: [String: [TranscriptItem]] {
        Dictionary(grouping: store.transcript.filter { item in
            item.type == "workspace.file_touched"
                && workspaceDiffHasContent(item)
                && item.payload["path"]?.stringValue != nil
        }, by: { $0.payload["path"]?.stringValue ?? "" })
    }

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
                        Text(rootName(root))
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        Text("Workspace root")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(abbreviatedPath(root))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
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
                        HStack(spacing: 12) {
                            Label("\(store.touchedWorkspaceFiles.count) changed file\(store.touchedWorkspaceFiles.count == 1 ? "" : "s")", systemImage: "doc.text.magnifyingglass")
                            Spacer()
                            Text(totalDiffText)
                                .foregroundStyle(diffTotalColor)
                        }
                        .font(.caption)
                        .padding(.horizontal)
                        .padding(.vertical, 8)

                        List(store.touchedWorkspaceFiles) { file in
                            WorkspaceFileReviewRow(
                                file: file,
                                workspaceRoot: root,
                                events: diffEventsByPath[file.path] ?? [],
                                copyPath: { store.copyWorkspaceFilePath(file.path) },
                                copyDiff: { store.copyWorkspaceDiff(for: file.path) }
                            )
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

    private var totalDiffText: String {
        let additions = store.touchedWorkspaceFiles.reduce(0) { $0 + $1.additions }
        let deletions = store.touchedWorkspaceFiles.reduce(0) { $0 + $1.deletions }
        return "+\(additions) -\(deletions)"
    }

    private var diffTotalColor: Color {
        let additions = store.touchedWorkspaceFiles.reduce(0) { $0 + $1.additions }
        let deletions = store.touchedWorkspaceFiles.reduce(0) { $0 + $1.deletions }
        return deletions > additions ? .orange : .green
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

    private func rootName(_ path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? "Workspace" : name
    }

    private func abbreviatedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }
}

private struct WorkspaceFileReviewRow: View {
    let file: WorkspaceFileSummary
    let workspaceRoot: String
    let events: [TranscriptItem]
    let copyPath: () -> Void
    let copyDiff: () -> Void
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(displayPath)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        Text(changeSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        Button {
                            copyPath()
                        } label: {
                            Label("Copy Path", systemImage: "doc.on.doc")
                        }
                        Button {
                            copyDiff()
                        } label: {
                            Label("Copy Diff", systemImage: "square.on.square")
                        }
                        .disabled(events.isEmpty)
                    }
                    .font(.caption)

                    if events.isEmpty {
                        Text(file.lastEventType == "workspace.conflict_detected" ? "No diff recorded for this conflict event." : "No diff recorded for this file.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(events) { event in
                            WorkspaceDiffEventView(event: event)
                        }
                    }
                }
                .padding(.top, 6)
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: file.conflictCount > 0 ? "exclamationmark.triangle.fill" : "doc.text")
                        .foregroundStyle(file.conflictCount > 0 ? .red : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fileName)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        if !directoryName.isEmpty {
                            Text(directoryName)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
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
        }
        .padding(.vertical, 4)
    }

    private var diffColor: Color {
        file.deletions > file.additions ? .orange : .green
    }

    private var fileName: String {
        let name = (displayPath as NSString).lastPathComponent
        return name.isEmpty ? displayPath : name
    }

    private var directoryName: String {
        let directory = (displayPath as NSString).deletingLastPathComponent
        if directory == "." || directory == "/" || directory == displayPath { return "" }
        return directory
    }

    private var displayPath: String {
        guard file.path.hasPrefix("/") else { return file.path }
        let root = workspaceRoot.hasSuffix("/") ? String(workspaceRoot.dropLast()) : workspaceRoot
        if file.path == root { return "." }
        if file.path.hasPrefix(root + "/") {
            return String(file.path.dropFirst(root.count + 1))
        }
        return abbreviatePath(file.path)
    }

    private func abbreviatePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }

    private var changeSummary: String {
        let conflictText = file.conflictCount == 0 ? "" : ", \(file.conflictCount) conflict\(file.conflictCount == 1 ? "" : "s")"
        return "Latest: \(file.lastEventType.replacingOccurrences(of: "workspace.", with: "")) by \(file.lastAgentId ?? "system"); +\(file.additions) -\(file.deletions)\(conflictText)."
    }
}

private struct WorkspaceDiffEventView: View {
    let event: TranscriptItem
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DisclosureGroup(isExpanded: $expanded) {
                if expanded {
                    WorkspaceDiffBlock(diff: event.payload["diff"]?.stringValue ?? "")
                        .padding(.top, 4)
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(event.agentId ?? "system")
                            .font(.caption.weight(.semibold))
                        if let stats = event.payload["diffStats"]?.objectValue {
                            Text("+\(Int(stats["additions"]?.numberValue ?? 0)) -\(Int(stats["deletions"]?.numberValue ?? 0))")
                                .foregroundStyle(diffColor(stats: stats))
                        }
                        Spacer()
                        Text(event.timestamp, style: .time)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let diff = event.payload["diff"]?.stringValue {
                        Text(diffSummary(diff))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    private func diffColor(stats: [String: JSONValue]) -> Color {
        let additions = Int(stats["additions"]?.numberValue ?? 0)
        let deletions = Int(stats["deletions"]?.numberValue ?? 0)
        return deletions > additions ? .orange : .green
    }

    private func diffSummary(_ diff: String) -> String {
        let files = diff
            .split(separator: "\n")
            .filter { $0.hasPrefix("diff --git ") || $0.hasPrefix("+++ ") || $0.hasPrefix("--- ") }
            .prefix(3)
            .map(String.init)
        if files.isEmpty {
            return "\(diff.split(separator: "\n", omittingEmptySubsequences: false).count) diff lines"
        }
        return files.joined(separator: "  ")
    }
}

private struct WorkspaceDiffBlock: View {
    let diff: String
    private let previewLineLimit = 300

    private var lines: [Substring] {
        diff.split(separator: "\n", omittingEmptySubsequences: false)
    }

    private var previewLines: ArraySlice<Substring> {
        lines.prefix(previewLineLimit)
    }

    private var omittedLineCount: Int {
        max(0, lines.count - previewLineLimit)
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(previewLines.enumerated()), id: \.offset) { _, line in
                    Text(String(line))
                        .font(.caption.monospaced())
                        .foregroundStyle(color(for: String(line)))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if omittedLineCount > 0 {
                    Text("Diff preview truncated. Copy Diff includes \(omittedLineCount) more line\(omittedLineCount == 1 ? "" : "s").")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 280)
        .textSelection(.enabled)
        .padding(8)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    }

    private func color(for line: String) -> Color {
        if line.starts(with: "+") && !line.starts(with: "+++") { return .green }
        if line.starts(with: "-") && !line.starts(with: "---") { return .red }
        return .primary
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
                Text("\(store.schedulerRuns.count) runs / \(store.debugLogs.count) logs")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .padding()

            if store.schedulerRuns.isEmpty && store.recoveredSchedulerJobs.isEmpty && store.debugLogs.isEmpty {
                emptyDebugState
                    .padding(.horizontal)
                    .padding(.top, 4)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !store.schedulerRuns.isEmpty {
                            schedulerRunsView
                        }
                        if !store.recoveredSchedulerJobs.isEmpty {
                            recoveredJobsView
                        }
                        if store.debugLogs.isEmpty {
                            emptyLogState
                        } else {
                            debugLogList
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyDebugState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("No debug logs yet", systemImage: "text.badge.magnifyingglass")
                .font(.callout.weight(.semibold))
            Text("Scheduler runs and debug logs will appear here after the session starts work or emits an error.")
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
    }

    private var emptyLogState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("No debug logs yet", systemImage: "text.badge.magnifyingglass")
                .font(.callout.weight(.semibold))
            Text("Scheduler runs are visible above. Debug logs will appear here after the session emits diagnostics or errors.")
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
    }

    private var schedulerRunsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Scheduler Runs", systemImage: "list.bullet.rectangle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(store.schedulerRuns.prefix(12)) { run in
                schedulerRunRow(run)
            }
            if store.schedulerRuns.count > 12 {
                Text("\(store.schedulerRuns.count - 12) older run\(store.schedulerRuns.count - 12 == 1 ? "" : "s") hidden.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary)
        }
    }

    private func schedulerRunRow(_ run: SchedulerRunSummary) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(run.kind)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(run.agentId)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                statusPill(run.status)
                if let timestamp = run.updatedAt {
                    Text(timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            if !run.prompt.isEmpty {
                Text(run.prompt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let message = run.message, !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(messageColor(for: run.status))
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                Text(run.jobId)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .textSelection(.enabled)
                if let workflowInstanceId = run.workflowInstanceId {
                    Text(workflowInstanceId)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                } else if let workflowId = run.workflowId {
                    Text(workflowId)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
                if let eventCount = run.eventCount {
                    Text("\(eventCount) event\(eventCount == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
    }

    private func statusPill(_ status: String) -> some View {
        Text(status)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(statusColor(status))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(statusColor(status).opacity(0.12), in: Capsule())
    }

    private var debugLogList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Debug Logs", systemImage: "text.alignleft")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(store.debugLogs.prefix(200)) { entry in
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
                .padding(8)
                .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
            }
            if store.debugLogs.count > 200 {
                Text("\(store.debugLogs.count - 200) older log\(store.debugLogs.count - 200 == 1 ? "" : "s") hidden. Export Session Artifacts for the complete debug log.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary)
        }
    }

    private var recoveredJobsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Recovered Jobs", systemImage: "arrow.clockwise.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(store.recoveredSchedulerJobs) { job in
                let statusLabel = recoveredJobStatusLabel(job)
                let statusColor = job.retried ? Color.secondary : Color.orange
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("\(job.kind) - \(job.agentId)")
                                .font(.caption.weight(.semibold))
                            Text(statusLabel)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(statusColor)
                        }
                        Text(job.prompt.isEmpty ? job.reason : job.prompt)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Text(job.recoveredAt, style: .time)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button(job.retried ? "Retried" : "Retry") {
                        store.retryRecoveredJob(job)
                    }
                    .font(.caption)
                    .disabled(job.retried || store.selectedSessionArchived)
                }
                .padding(8)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary)
        }
    }

    private func recoveredJobStatusLabel(_ job: RecoveredSchedulerJob) -> String {
        if job.retryReason == "auto-resume workflow execution after daemon restart" {
            return "Auto-resumed"
        }
        return job.retried ? "Retry requested" : "Needs retry"
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "completed": .green
        case "failed": .red
        case "recovered", "retry requested": .orange
        case "running": .blue
        default: .secondary
        }
    }

    private func messageColor(for status: String) -> Color {
        switch status {
        case "failed": .red
        case "recovered", "retry requested": .orange
        default: .secondary
        }
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
