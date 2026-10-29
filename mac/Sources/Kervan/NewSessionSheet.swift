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
                        ForEach(model.store.agents) { Text($0.name).tag($0.id) }
                    }
                    Toggle(isOn: $orchestrate) {
                        Text("Yardımcı ajan başlatabilsin")
                        Text("Alt görevleri başka ajanlara verir; yardımcılar aynı klasörde çalışır ve kenar çubuğunda bu oturumun altında görünür.")
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
                        Label(loadError, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
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
                        orchestrate: orchestrate
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
