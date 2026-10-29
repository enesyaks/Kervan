import KervanKit
import SwiftUI

/// Pick the agent, skills and MCP servers for a new session. The last choices come back next time.
struct NewSessionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var agent: String
    @State private var skills: Set<String>
    @State private var mcpServers: Set<String>
    @State private var orchestrate: Bool
    @State private var budget: Double?
    @State private var available: [SkillInfo]?
    @State private var loadError: String?

    init(agent: String) {
        _agent = State(initialValue: agent)
        _skills = State(initialValue: Set(UserDefaults.standard.stringArray(forKey: AppModel.lastSkillsKey) ?? []))
        _mcpServers = State(initialValue: Set(UserDefaults.standard.stringArray(forKey: AppModel.lastMcpKey) ?? []))
        _orchestrate = State(initialValue: UserDefaults.standard.bool(forKey: AppModel.lastOrchestrateKey))
    }

    var body: some View {
        let servers = model.store.mcpServers

        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    Picker("Ajan", selection: $agent) {
                        ForEach(model.store.agents) { Text($0.displayName).tag($0.id) }
                    }
                    Toggle(isOn: $orchestrate) {
                        Text("Yardımcı ajan başlatabilsin")
                        Text("Alt görevleri başka ajanlara verir; yardımcılar kenar çubuğunda bu oturumun altında görünür. Klasör bir git deposuysa her yardımcı kendi dalında çalışır.")
                    }
                    if orchestrate {
                        BudgetField(budget: $budget)
                    }
                }

                Section("Skill'ler") {
                    if let available, available.isEmpty {
                        Text("Kütüphanede skill yok. Ayarlar'dan skill klasörü ekleyebilirsiniz.").foregroundStyle(.secondary)
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

                Section("MCP sunucuları") {
                    if servers.isEmpty {
                        Text("Kayıtlı MCP sunucusu yok. Ayarlar'dan ekleyebilirsiniz.").foregroundStyle(.secondary)
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
                SettingsLink {
                    Text("Skill ve MCP ayarları…")
                }
                .buttonStyle(.link)
                Spacer()
                Button("Vazgeç", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Oturumu başlat") {
                    // Drop choices that no longer exist on the server.
                    let names = Set(available?.map(\.name) ?? [])
                    model.startSession(
                        agent: agent,
                        skills: skills.filter(names.contains).sorted(),
                        mcpServers: mcpServers.filter { name in servers.contains { $0.name == name } }.sorted(),
                        orchestrate: orchestrate,
                        budgetUsd: orchestrate ? budget.flatMap { $0 > 0 ? $0 : nil } : nil
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!model.canCreateSession)
            }
            .padding(16)
        }
        .frame(width: 460, height: 560)
        .background(Color.kervanCanvas)
        .navigationTitle("Yeni oturum")
        .task { await loadSkills() }
    }

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
            loadError = "Skill'ler alınamadı: \(error.localizedDescription)"
        }
    }
}

/// An optional dollar limit for a lead and its helpers together. Empty means no limit.
struct BudgetField: View {
    @Binding var budget: Double?

    var body: some View {
        LabeledContent {
            HStack(spacing: 4) {
                TextField("Bütçe", value: $budget, format: .number.precision(.fractionLength(0...2)), prompt: Text("Sınırsız"))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                Text("USD").foregroundStyle(.secondary)
            }
        } label: {
            Text("Bütçe")
            Text("Ana ajan ve yardımcılarının toplam harcaması. Dolunca hepsi durur. Şimdilik yalnızca maliyet bildiren ajanlarda (Claude) işler.")
        }
    }
}
