import KervanKit
import SwiftUI

/// Sidebar: each team with its members (one session per role).
struct TeamsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.store
        Section("Takımlar") {
            if store.teams.isEmpty {
                Button("Takım kur…") { model.showNewTeam = true }
                    .buttonStyle(.link)
                    .disabled(store.roles.isEmpty || !model.canCreateSession)
                    .help(store.roles.isEmpty ? "Önce Ayarlar › Roller'den rol tanımlayın." : "Rollerden bir takım kur")
            }
            ForEach(store.teams) { team in
                DisclosureGroup {
                    // Helpers a lead started join its team; they're listed under that lead.
                    ForEach(team.sessionIds.compactMap(store.session).filter { $0.parentId == nil }) { session in
                        MemberRow(session: session).tag(session.id)
                        ForEach(store.helpers(of: session.id)) { helper in
                            HelperRow(session: helper).tag(helper.id)
                        }
                    }
                } label: {
                    Label(team.title, systemImage: "person.3")
                }
            }
        }
    }
}

private struct MemberRow: View {
    let session: SessionInfo
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(color: session.status.tint)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(session.role ?? session.title).lineLimit(1)
                    if session.orchestrate {
                        Image(systemName: "flag.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.kervanSaffron)
                            .help("Ana ajan: yardımcı başlatabilir")
                            .accessibilityLabel("ana ajan")
                    }
                }
                Text("\(model.store.agentName(session.agent)), \(session.status.label.lowercased())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A helper under the lead that started it, in the sidebar.
struct HelperRow: View {
    let session: SessionInfo
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "arrow.turn.down.right")
                .font(.caption)
                .foregroundStyle(Color.kervanSaffron)
            StatusDot(color: session.status.tint, size: 7)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title).lineLimit(1)
                Text("\(model.store.agentName(session.agent)), \(session.status.label.lowercased())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Yardımcı \(session.title), \(model.store.agentName(session.agent)), \(session.status.label.lowercased())")
    }
}

/// Pick a title and the roles; each role becomes a member session in one shared folder.
struct NewTeamSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var picked: [String] = []

    var body: some View {
        let roles = model.store.roles

        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("Takım adı", text: $title, prompt: Text("Web sitesi yenileme"))
                Section {
                    if roles.isEmpty {
                        Text("Henüz rol yok. Ayarlar › Roller'den ekleyin.").foregroundStyle(.secondary)
                    }
                    ForEach(roles) { role in
                        Toggle(isOn: Binding(
                            get: { picked.contains(role.id) },
                            set: { on in if on { picked.append(role.id) } else { picked.removeAll { $0 == role.id } } }
                        )) {
                            Text(role.name)
                            Text("\(model.store.agentName(role.agent))\(role.instructions.isEmpty ? "" : " — \(role.instructions)")")
                                .lineLimit(2)
                        }
                    }
                } header: {
                    Text("Üyeler")
                } footer: {
                    Text("Her rol ayrı bir oturum olur; hepsi aynı çalışma klasörünü paylaşır.")
                }
            }
            .formStyle(.grouped)

            HStack {
                SettingsLink { Text("Rolleri düzenle…") }.buttonStyle(.link)
                Spacer()
                Button("Vazgeç", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Takımı kur") {
                    let name = title.trimmingCharacters(in: .whitespaces)
                    Task { await model.store.createTeam(title: name, roles: picked) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || picked.isEmpty || !model.canCreateSession)
            }
            .padding(16)
        }
        .frame(width: 460, height: 480)
    }
}

/// Settings › Roller.
struct RolesSettings: View {
    @Environment(AppModel.self) private var model
    @State private var editing: Role?
    @State private var isNew = false
    @State private var removing: Role?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rol, bir takımdaki görevi tanımlar: hangi ajan, ona baştan ne söylenecek, hangi skill ve MCP sunucularını kullanacak.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List {
                if model.store.roles.isEmpty {
                    Text("Henüz rol yok").foregroundStyle(.secondary)
                }
                ForEach(model.store.roles) { role in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(role.name)
                            Text(model.store.agentName(role.agent)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Düzenle") {
                            isNew = false
                            editing = role
                        }
                        .buttonStyle(.borderless)
                        Button("Sil", role: .destructive) { removing = role }.buttonStyle(.borderless)
                    }
                }
            }
            .listStyle(.bordered)

            HStack {
                Spacer()
                Button("Rol ekle…") {
                    isNew = true
                    editing = Role(id: "", name: "", agent: model.store.agents.first?.id ?? "")
                }
                .disabled(!model.connection.state.isConnected)
            }
        }
        .padding(20)
        .sheet(item: $editing) { role in
            RoleEditor(role: role, isNew: isNew)
        }
        .confirmationDialog(
            "\(removing?.name ?? "") rolü silinsin mi?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
        ) {
            Button("Rolü sil", role: .destructive) {
                if let role = removing { Task { await model.store.deleteRole(role.id) } }
            }
        } message: {
            Text("Bu rolle kurulmuş takımlar ve oturumları olduğu gibi kalır.")
        }
    }
}

private struct RoleEditor: View {
    @State var role: Role
    let isNew: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var skills: [SkillInfo] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("Kimlik", text: $role.id, prompt: Text("inceleyici"))
                    .font(.body.monospaced())
                    .disabled(!isNew)
                TextField("Ad", text: $role.name, prompt: Text("Kod inceleyici"))
                Picker("Ajan", selection: $role.agent) {
                    ForEach(model.store.agents) { Text($0.displayName).tag($0.id) }
                }
                Toggle(isOn: $role.lead) {
                    Text("Ana ajan")
                    Text("Takımda yardımcı ajan başlatıp onlara görev verebilir.")
                }
                if role.lead {
                    BudgetField(budget: $role.budgetUsd)
                }
                Section("Talimat") {
                    TextEditor(text: $role.instructions)
                        .font(.body)
                        .frame(minHeight: 90)
                        .accessibilityLabel("Rol talimatı")
                }
                if !skills.isEmpty {
                    Section("Varsayılan skill'ler") {
                        ForEach(skills) { skill in
                            Toggle(skill.name, isOn: membership(skill.name, in: $role.skills))
                        }
                    }
                }
                if !model.store.mcpServers.isEmpty {
                    Section("Varsayılan MCP sunucuları") {
                        ForEach(model.store.mcpServers) { server in
                            Toggle(server.name, isOn: membership(server.name, in: $role.mcpServers))
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Vazgeç", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Ekle" : "Kaydet") {
                    Task { await model.store.saveRole(role) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(role.id.isEmpty || role.name.trimmingCharacters(in: .whitespaces).isEmpty || role.agent.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 500, height: 440) // fits under the Settings window; the form scrolls
        .task { skills = (try? await model.fileClient?.listSkills()) ?? [] }
    }

    private func membership(_ name: String, in list: Binding<[String]>) -> Binding<Bool> {
        Binding(
            get: { list.wrappedValue.contains(name) },
            set: { on in if on { list.wrappedValue.append(name) } else { list.wrappedValue.removeAll { $0 == name } } }
        )
    }
}
