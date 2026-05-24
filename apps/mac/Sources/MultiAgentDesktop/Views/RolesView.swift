import SwiftUI

struct RolesView: View {
    @Bindable var store: SessionStore
    @State private var selectedRoleId: String?

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
                        store.addRole()
                        selectedRoleId = store.roles.last?.id
                    } label: {
                        Label("Add Role", systemImage: "plus")
                    }
                }
                .padding()

                List(selection: $selectedRoleId) {
                    ForEach(store.roles) { role in
                        Label(role.name, systemImage: "person.crop.circle")
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
    }
}

private struct RoleEditor: View {
    @Binding var role: RoleSpec
    let save: () -> Void

    var body: some View {
        Form {
            Section("Identity") {
                TextField("ID", text: $role.id)
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
