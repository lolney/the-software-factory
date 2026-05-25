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
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Roles")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Button {
                        store.copyPersonalRolesPath()
                    } label: {
                        Label("Copy Path", systemImage: "doc.on.doc")
                    }
                    .help(store.personalRolesPath ?? "Personal roles directory")
                    if let index = selectedIndex, store.roles.indices.contains(index) {
                        let role = store.roles[index]
                        Button(role: .destructive) {
                            rolePendingDeletion = role
                            showDeleteConfirmation = true
                        } label: {
                            Label("Delete Role", systemImage: "trash")
                        }
                        .disabled(!store.canDeleteRole(role))
                        .help(store.canDeleteRole(role) ? "Delete this user-created role" : "Built-in roles cannot be deleted")
                    }
                    Button {
                        store.addRole()
                    } label: {
                        Label("Add Role", systemImage: "plus")
                    }
                }
                .padding()

                List(selection: $selectedRoleId) {
                    ForEach(store.roles) { role in
                        Label(role.name.isEmpty ? role.id : role.name, systemImage: "person.crop.circle")
                            .tag(role.id)
                    }
                }
            }
            .frame(minWidth: 240, idealWidth: 280)

            if let index = selectedIndex, store.roles.indices.contains(index) {
                RoleEditor(role: $store.roles[index]) {
                    store.saveRole(store.roles[index])
                }
                .frame(minWidth: 520)
            } else {
                ContentUnavailableView("No Role Selected", systemImage: "person.2", description: Text("Select a role or add a new one."))
                    .frame(minWidth: 520)
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
    }
}
