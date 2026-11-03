import KervanKit
import SwiftUI

/// Sidebar: each team with its members (one session per role).
struct TeamsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.store
        Section(L("Teams", "Takımlar")) {
            if store.teams.isEmpty {
                Button(L("New team…", "Takım kur…")) { model.showNewTeam = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(!model.canCreateSession)
                    .help(store.roles.isEmpty ? L("Define roles in Settings › Roles first.", "Önce Ayarlar › Roller'den rol tanımlayın.") : L("Build a team from roles", "Rollerden bir takım kur"))
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
                            .help(L("Lead: can start helpers", "Ana ajan: yardımcı başlatabilir"))
                            .accessibilityLabel(L("lead", "ana ajan"))
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
        .accessibilityLabel(L("Helper \(session.title), \(model.store.agentName(session.agent)), \(session.status.label.lowercased())", "Yardımcı \(session.title), \(model.store.agentName(session.agent)), \(session.status.label.lowercased())"))
    }
}

/// Pick a title and the roles; each role becomes a member session in one shared folder.
struct NewTeamSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @State private var title = ""
    @State private var picked: [String] = []

    var body: some View {
        let roles = model.store.roles

        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField(L("Team name", "Takım adı"), text: $title, prompt: Text(L("Website refresh", "Web sitesi yenileme")))
                Section {
                    if roles.isEmpty {
                        Text(L("No roles yet. Add them in Settings › Roles.", "Henüz rol yok. Ayarlar › Roller'den ekleyin.")).foregroundStyle(.secondary)
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
                    Text(L("Members", "Üyeler"))
                } footer: {
                    Text(L("Each role becomes a session of its own; they all share one working folder.", "Her rol ayrı bir oturum olur; hepsi aynı çalışma klasörünü paylaşır."))
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            HStack {
                Button(L("Edit roles…", "Rolleri düzenle…")) {
                    UserDefaults.standard.set(SettingsTab.roles, forKey: SettingsTab.key)
                    openSettings()
                }
                .buttonStyle(.link)
                Spacer()
                Button(L("Cancel", "Vazgeç"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Create team", "Takımı kur")) {
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
        .background(Color.kervanCanvas)
    }
}

/// Settings › Roller.
struct RolesSettings: View {
    @Environment(AppModel.self) private var model
    @State private var editing: Role?
    @State private var removing: Role?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("A role is a job in a team: which agent, what it's told up front, which skills and MCP servers it uses.", "Rol, bir takımdaki görevi tanımlar: hangi ajan, ona baştan ne söylenecek, hangi skill ve MCP sunucularını kullanacak."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List {
                ForEach(model.store.roles) { role in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(role.name)
                            Text(model.store.agentName(role.agent)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L("Edit", "Düzenle")) {
                            editing = role
                        }
                        .buttonStyle(.borderless)
                        Button(L("Delete", "Sil"), role: .destructive) { removing = role }.buttonStyle(.borderless)
                    }
                }
            }
            .softList()
            .overlay {
                if model.store.roles.isEmpty {
                    EmptyCard(symbol: "theatermasks", title: L("No roles yet", "Henüz rol yok"), text: L("A role describes a job in a team: which agent, with which instructions and tools.", "Bir rol, takımdaki görevi anlatır: hangi ajan, ne talimatla, hangi araçlarla."))
                }
            }

            HStack {
                Spacer()
                Button(L("Add role…", "Rol ekle…")) {
                    editing = Role(id: "", name: "", agent: model.store.agents.first?.id ?? "")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.connection.state.isConnected)
            }
        }
        .padding(20)
        .settingsPage()
        .sheet(item: $editing) { role in
            // Decided from the role itself: a separate state value is still the old one when this closure first runs.
            RoleEditor(role: role, isNew: role.id.isEmpty)
        }
        .confirmationDialog(
            L("Delete the role \(removing?.name ?? "")?", "\(removing?.name ?? "") rolü silinsin mi?"),
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
        ) {
            Button(L("Delete role", "Rolü sil"), role: .destructive) {
                if let role = removing { Task { await model.store.deleteRole(role.id) } }
            }
        } message: {
            Text(L("Teams built with this role and their sessions stay as they are.", "Bu rolle kurulmuş takımlar ve oturumları olduğu gibi kalır."))
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
                TextField(L("ID", "Kimlik"), text: $role.id, prompt: Text("inceleyici"))
                    .font(.body.monospaced())
                    .disabled(!isNew)
                TextField(L("Name", "Ad"), text: $role.name, prompt: Text(L("Code reviewer", "Kod inceleyici")))
                Picker(L("Agent", "Ajan"), selection: $role.agent) {
                    ForEach(model.store.agents) { Text($0.displayName).tag($0.id) }
                }
                Toggle(isOn: $role.lead) {
                    Text(L("Lead agent", "Ana ajan"))
                    Text(L("Can start helper agents in the team and give them tasks.", "Takımda yardımcı ajan başlatıp onlara görev verebilir."))
                }
                if role.lead {
                    BudgetField(budget: $role.budgetUsd)
                }
                Section(L("Instructions", "Talimat")) {
                    TextEditor(text: $role.instructions)
                        .font(.body)
                        .frame(minHeight: 90)
                        .accessibilityLabel(L("Role instructions", "Rol talimatı"))
                }
                if !skills.isEmpty {
                    Section(L("Default skills", "Varsayılan skill'ler")) {
                        ForEach(skills) { skill in
                            Toggle(skill.name, isOn: membership(skill.name, in: $role.skills))
                        }
                    }
                }
                if !model.store.mcpServers.isEmpty {
                    Section(L("Default MCP servers", "Varsayılan MCP sunucuları")) {
                        ForEach(model.store.mcpServers) { server in
                            Toggle(server.name, isOn: membership(server.name, in: $role.mcpServers))
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            HStack {
                Spacer()
                Button(L("Cancel", "Vazgeç"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? L("Add", "Ekle") : L("Save", "Kaydet")) {
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
        .background(Color.kervanCanvas)
        .task { skills = (try? await model.fileClient?.listSkills()) ?? [] }
    }

    private func membership(_ name: String, in list: Binding<[String]>) -> Binding<Bool> {
        Binding(
            get: { list.wrappedValue.contains(name) },
            set: { on in if on { list.wrappedValue.append(name) } else { list.wrappedValue.removeAll { $0 == name } } }
        )
    }
}
