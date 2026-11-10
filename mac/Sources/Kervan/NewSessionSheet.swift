import KervanKit
import SwiftUI

/// Pick the agent, skills and MCP servers for a new session. The last choices come back next time.
struct NewSessionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @State private var agent: String
    @State private var skills: Set<String>
    @State private var mcpServers: Set<String>
    @State private var orchestrate: Bool
    /// With helpers on: the lead judges the size first and splits large work among them.
    @State private var split = false
    @State private var budget: Double?
    /// Starts off every time, unlike the other choices: it means fewer questions, so it's decided per task.
    @State private var autoApprove = false
    @State private var available: [SkillInfo]?
    @State private var loadError: String?
    @State private var project: String?
    /// In a git project: a worktree and branch of its own (the default), or the project folder itself.
    @State private var ownBranch = true

    init(agent: String, project: String? = nil) {
        _agent = State(initialValue: agent)
        _project = State(initialValue: project)
        _skills = State(initialValue: Set(UserDefaults.standard.stringArray(forKey: AppModel.lastSkillsKey) ?? []))
        _mcpServers = State(initialValue: Set(UserDefaults.standard.stringArray(forKey: AppModel.lastMcpKey) ?? []))
        _orchestrate = State(initialValue: UserDefaults.standard.bool(forKey: AppModel.lastOrchestrateKey))
    }

    var body: some View {
        let servers = model.store.mcpServers

        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    AgentPicker(agent: $agent)
                    if onNode {
                        Text(L("On another machine the agent works in a folder of its own there. Projects and skills need an agent on this server.", "Başka bir makinede ajan oradaki kendi klasöründe çalışır. Proje ve skill'ler için bu sunucudaki bir ajan gerekir."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker(selection: $project) {
                            Text(L("None (the session's own folder)", "Yok (oturumun kendi klasörü)")).tag(String?.none)
                            ForEach(model.store.projects) { Text($0.name).tag(Optional($0.id)) }
                        } label: {
                            Text(L("Project", "Proje"))
                            Text(L("The agent works on the project's files, with the project's instructions.", "Ajan projenin dosyalarında, projenin talimatlarıyla çalışır."))
                        }
                    }
                    if project != nil && !onNode {
                        Toggle(isOn: $ownBranch) {
                            Text(L("Work on a branch of its own", "Kendi branch'inde çalışsın"))
                            Text(L("In a git repository the session gets its own copy (a worktree), so sessions in the same project never edit the same files. Turn off to work in the project folder itself.", "Git deposunda oturum kendi kopyasını (worktree) alır; böylece aynı projedeki oturumlar aynı dosyaları düzenlemez. Proje klasörünün kendisinde çalışmak için kapatın."))
                        }
                    }
                    // A terminal agent has no MCP servers, so it has nothing to start helpers with.
                    if selected?.terminal != true {
                        Toggle(isOn: $orchestrate) {
                            Text(L("Can start helper agents", "Yardımcı ajan başlatabilsin"))
                            Text(L("Hands subtasks to other agents, on this server or on any machine with an agent; helpers show up under this session in the sidebar. A helper on this server's own files works on a branch of its own.", "Alt görevleri başka ajanlara verir — bu sunucudaki ya da ajanı olan herhangi bir makinedeki; yardımcılar kenar çubuğunda bu oturumun altında görünür. Bu sunucunun dosyalarında çalışan yardımcı kendi dalını alır."))
                        }
                    }
                    if orchestrate && !onNode {
                        // The lead judges size against its own folder, which only this server can look into.
                        Toggle(isOn: $split) {
                            Text(L("Split into helpers when the work is large", "İş büyük olduğunda yardımcılara böl"))
                            Text(L("The agent judges the size first: large work with separate parts it plans and hands out, small work it does itself. Idle helpers rest after a while and wake when needed.", "Ajan önce işin büyüklüğüne bakar: ayrı parçaları olan büyük işi planlayıp dağıtır, küçük işi kendisi yapar. Boşta kalan yardımcılar bir süre sonra dinlenmeye geçer, gerekince uyanır."))
                        }
                        BudgetField(budget: $budget)
                    }
                    if selected?.terminal != true {
                        Toggle(isOn: $autoApprove) {
                            Text(L("Auto-approve", "Otomatik onay"))
                            Text(L("Approves routine actions by itself. It still asks before major ones: pushing, deleting folders, rewriting git history, deploying, touching secrets or files outside this task's folder.", "Sıradan işlemleri kendisi onaylar. Büyük işlemlerde yine sorar: push, klasör silme, git geçmişini değiştirme, yayına alma, gizli bilgilere ya da bu görevin klasörü dışındaki dosyalara dokunma."))
                        }
                    }
                }

                if !onNode {
                    Section(L("Skills", "Skill'ler")) {
                        if let available, available.isEmpty {
                            Text(L("No skills in the library. Add a skill folder in Settings.", "Kütüphanede skill yok. Ayarlar'dan skill klasörü ekleyebilirsiniz.")).foregroundStyle(.secondary)
                        } else if let available {
                            ForEach(available) { skill in
                                Toggle(isOn: binding(for: skill.name, in: $skills)) {
                                    Text(skill.name)
                                    if !skill.description.isEmpty { Text(skill.description) }
                                }
                            }
                        } else if let loadError {
                            Label(loadError, systemImage: "exclamationmark.triangle").foregroundStyle(.kervanCoral)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                }

                Section(L("MCP servers", "MCP sunucuları")) {
                    if servers.isEmpty {
                        Text(L("No MCP servers yet. Add them in Settings.", "Kayıtlı MCP sunucusu yok. Ayarlar'dan ekleyebilirsiniz.")).foregroundStyle(.secondary)
                    }
                    ForEach(servers) { server in
                        Toggle(isOn: binding(for: server.name, in: $mcpServers)) {
                            Text(server.name)
                            Text(server.transport == .http ? server.url ?? "" : ([server.command ?? ""] + (server.args ?? [])).joined(separator: " "))
                                .font(.caption.monospaced())
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            HStack {
                Button(L("Skill and MCP settings…", "Skill ve MCP ayarları…")) {
                    UserDefaults.standard.set(SettingsTab.skills, forKey: SettingsTab.key)
                    openSettings()
                }
                .buttonStyle(.link)
                Spacer()
                Button(L("Cancel", "Vazgeç"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Start session", "Oturumu başlat")) {
                    // Drop choices that no longer exist on the server.
                    let names = Set(available?.map(\.name) ?? [])
                    // What a node can't do stays picked in the sheet but isn't asked for.
                    let lead = orchestrate && selected?.terminal != true
                    let folder = onNode ? nil : project
                    model.startSession(
                        agent: agent,
                        skills: onNode ? [] : skills.filter(names.contains).sorted(),
                        mcpServers: mcpServers.filter { name in servers.contains { $0.name == name } }.sorted(),
                        orchestrate: lead,
                        budgetUsd: lead ? budget.flatMap { $0 > 0 ? $0 : nil } : nil,
                        projectId: folder,
                        shared: folder != nil && !ownBranch,
                        split: lead && split,
                        autoApprove: autoApprove && selected?.terminal != true
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!model.canCreateSession || selected == nil || selected?.isAway == true)
            }
            .padding(16)
        }
        .frame(width: 460, height: 480) // fits a window at its smallest; the form scrolls
        .background(Color.kervanCanvas)
        .navigationTitle(L("New session", "Yeni oturum"))
        .task {
            // Started from a project: the project's files are on this server.
            if project != nil, onNode, let here = model.store.agents.first(where: { $0.node == nil }) { agent = here.id }
            await loadSkills()
        }
    }

    private var selected: AgentInfo? { model.store.agents.first { $0.id == agent } }
    private var onNode: Bool { selected?.node != nil }

    private func binding(for name: String, in set: Binding<Set<String>>) -> Binding<Bool> {
        Binding(
            get: { set.wrappedValue.contains(name) },
            set: { on in if on { set.wrappedValue.insert(name) } else { set.wrappedValue.remove(name) } }
        )
    }

    private func loadSkills() async {
        guard let client = model.fileClient else { return }
        do {
            available = try await client.listSkills()
        } catch {
            loadError = L("Couldn't load skills: \(error.localizedDescription)", "Skill'ler alınamadı: \(error.localizedDescription)")
        }
    }
}

/// An optional dollar limit for a lead and its helpers together. Empty means no limit.
struct BudgetField: View {
    @Binding var budget: Double?

    var body: some View {
        LabeledContent {
            HStack(spacing: 4) {
                TextField(L("Budget", "Bütçe"), value: $budget, format: .number.precision(.fractionLength(0...2)), prompt: Text(L("Unlimited", "Sınırsız")))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                Text("USD").foregroundStyle(.secondary)
            }
        } label: {
            Text(L("Budget", "Bütçe"))
            Text(L("What the lead and its helpers may spend together. When it runs out, they all stop. Works only with agents that report cost (Claude) for now.", "Ana ajan ve yardımcılarının toplam harcaması. Dolunca hepsi durur. Şimdilik yalnızca maliyet bildiren ajanlarda (Claude) işler."))
        }
    }
}
