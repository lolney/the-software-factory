import SwiftUI

struct RolesView: View {
    @Bindable var store: SessionStore
    @State private var selectedRoleId: String?
    @State private var rolePendingDeletion: RoleSpec?
    @State private var showDeleteConfirmation = false

    private var selectedIndex: Int? {
        guard let selectedRoleId else { return store.roles.indices.first }
        return store.roles.firstIndex { $0.id == selectedRoleId }
    }

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width < 760 {
                VStack(spacing: 0) {
                    roleListPane(compact: true)
                        .frame(minHeight: 180, idealHeight: 220, maxHeight: 260)
                    Divider()
                    roleDetailPane
                }
            } else {
                HSplitView {
                    roleListPane(compact: false)
                        .frame(minWidth: 220, idealWidth: 280)
                        .frame(maxHeight: .infinity, alignment: .topLeading)
                    roleDetailPane
                        .frame(minWidth: 340)
                }
            }
        }
        .task {
            store.refreshCatalogs()
            selectedRoleId = selectedRoleId ?? store.roles.first?.id
        }
        .onChange(of: store.roles.map(\.id)) { _, ids in
            if let selectedRoleId, ids.contains(selectedRoleId) {
                return
            }
            selectedRoleId = ids.first
        }
        .confirmationDialog(
            "Delete Role?",
            isPresented: $showDeleteConfirmation,
            presenting: rolePendingDeletion
        ) { role in
            Button("Delete \(role.name)", role: .destructive) {
                store.deleteRole(role)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This removes the user-created role from the local role catalog. Built-in roles are protected.")
        }
    }

    private func roleListPane(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Roles")
                    .font(.title2.weight(.semibold))
                Spacer()
                roleActions(labelStyle: compact ? .iconOnly : .titleAndIcon)
            }
            .padding()

            if store.roles.isEmpty {
                roleCatalogEmptyHint
                    .padding(.horizontal)
                    .padding(.top, 24)
                Spacer()
            } else {
                List(selection: $selectedRoleId) {
                    ForEach(store.roles) { role in
                        Label(role.name.isEmpty ? role.id : role.name, systemImage: "person.crop.circle")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .tag(role.id)
                    }
                }
            }
        }
    }

    private func roleActions(labelStyle: AdaptiveRolesActionLabelStyle) -> some View {
        HStack(spacing: 8) {
            Button {
                store.copyPersonalRolesPath()
            } label: {
                Label("Copy Path", systemImage: "doc.on.doc")
                    .adaptiveRolesLabelStyle(labelStyle)
            }
            .help(store.personalRolesPath ?? "Personal roles directory")
            .disabled(store.personalRolesPath == nil)
            .accessibilityLabel("Copy personal roles path")

            if let index = selectedIndex, store.roles.indices.contains(index) {
                let role = store.roles[index]
                Button(role: .destructive) {
                    rolePendingDeletion = role
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete Role", systemImage: "trash")
                        .adaptiveRolesLabelStyle(labelStyle)
                }
                .disabled(!store.canDeleteRole(role))
                .help(store.canDeleteRole(role) ? "Delete this user-created role" : "Built-in roles cannot be deleted")
                .accessibilityLabel("Delete role")
            }

            Button {
                store.addRole()
            } label: {
                Label("Add Role", systemImage: "plus")
                    .adaptiveRolesLabelStyle(labelStyle)
            }
            .disabled(!store.daemon.isConnected)
            .help("Add a blank role JSON file")
            .accessibilityLabel("Add role")
        }
    }

    private var roleCatalogEmptyHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(emptyCatalogTitle, systemImage: emptyCatalogIcon)
                .font(.headline)
            Text(emptyCatalogDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var roleDetailPane: some View {
        if let index = selectedIndex, store.roles.indices.contains(index) {
            RoleEditor(role: $store.roles[index]) {
                store.saveRole(store.roles[index])
            }
        } else {
            ContentUnavailableView {
                Label(emptyCatalogTitle, systemImage: emptyCatalogIcon)
            } description: {
                Text(emptyCatalogDescription)
            } actions: {
                Button {
                    store.addRole()
                } label: {
                    Label("Add Personal Role", systemImage: "plus")
                }
                .disabled(!store.daemon.isConnected)
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyCatalogTitle: String {
        if !store.daemon.isConnected {
            return "Role Library Unavailable"
        }
        if store.roles.isEmpty {
            return "No Role Catalog Entries"
        }
        return "Select a Role"
    }

    private var emptyCatalogDescription: String {
        if !store.daemon.isConnected {
            return "Connect to the local daemon to load built-in roles and personal role JSON files."
        }
        if store.roles.isEmpty {
            return "The daemon did not report any built-in or personal roles. Add a personal role JSON file, or check the daemon role library."
        }
        return "Built-in and personal roles appear together in this catalog. Choose one to inspect or edit its local definition."
    }

    private var emptyCatalogIcon: String {
        store.daemon.isConnected ? "person.2" : "antenna.radiowaves.left.and.right.slash"
    }
}

private enum AdaptiveRolesActionLabelStyle {
    case titleAndIcon
    case iconOnly
}

private extension View {
    @ViewBuilder
    func adaptiveRolesLabelStyle(_ style: AdaptiveRolesActionLabelStyle) -> some View {
        switch style {
        case .titleAndIcon:
            self.labelStyle(.titleAndIcon)
        case .iconOnly:
            self.labelStyle(.iconOnly)
        }
    }
}

private struct RoleEditor: View {
    @Binding var role: RoleSpec
    let save: () -> Void

    var body: some View {
        Form {
            Section("Identity") {
                LabeledContent("ID", value: role.id)
                TextField("Name", text: $role.name)
                TextField("Model", text: $role.model)
                TextField("Color", text: $role.color)
            }

            Section("Prompt") {
                TextEditor(text: $role.promptTemplate)
                    .font(.body.monospaced())
                    .frame(minHeight: 220)
            }

            Section("Tool Policy") {
                Toggle("Can read files", isOn: $role.toolPolicy.canRead)
                Toggle("Can write files", isOn: $role.toolPolicy.canWrite)
                Toggle("Can run commands", isOn: $role.toolPolicy.canRunCommands)
                Toggle("Can create plans", isOn: Binding(
                    get: { role.toolPolicy.canCreatePlans ?? false },
                    set: { role.toolPolicy.canCreatePlans = $0 }
                ))
                Toggle("Can use local browser QA", isOn: Binding(
                    get: { role.toolPolicy.canUseBrowser ?? false },
                    set: { role.toolPolicy.canUseBrowser = $0 }
                ))
                Toggle("Can request Computer Use QA", isOn: Binding(
                    get: { role.toolPolicy.canUseComputer ?? false },
                    set: { role.toolPolicy.canUseComputer = $0 }
                ))
                Toggle("Can use MCP servers", isOn: Binding(
                    get: { role.toolPolicy.canUseMCP ?? false },
                    set: { role.toolPolicy.canUseMCP = $0 }
                ))
            }

            Section("Workspace") {
                TextField("Allowed roots", text: Binding(
                    get: { role.workspace.allowedRoots.joined(separator: ", ") },
                    set: { role.workspace.allowedRoots = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                ))
            }

            Section("Expected Outputs") {
                TextEditor(text: Binding(
                    get: { role.expectedOutputs.joined(separator: "\n") },
                    set: { role.expectedOutputs = $0.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
                ))
                .frame(minHeight: 80)
            }

            Section("Review Responsibilities") {
                TextEditor(text: Binding(
                    get: { role.reviewResponsibilities.joined(separator: "\n") },
                    set: { role.reviewResponsibilities = $0.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
                ))
                .frame(minHeight: 80)
            }

            Section {
                Button {
                    save()
                } label: {
                    Label("Save Role", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 320)
    }
}
