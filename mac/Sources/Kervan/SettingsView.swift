import AppKit
import KervanKit
import SwiftUI

/// ⌘, — the server's skill library and MCP servers. Changes go straight to the server.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("Genel", systemImage: "gearshape") }
            SkillsSettings()
                .tabItem { Label("Skill'ler", systemImage: "book.closed") }
            McpSettings()
                .tabItem { Label("MCP sunucuları", systemImage: "point.3.connected.trianglepath.dotted") }
            AgentsSettings()
                .tabItem { Label("Ajanlar", systemImage: "person.2") }
            RolesSettings()
                .tabItem { Label("Roller", systemImage: "theatermasks") }
        }
        .frame(width: 620, height: 480)
        .fontDesign(.rounded)
    }
}

/// Settings › Genel: how the app looks and opens, and which server it is on.
private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Appearance.key) private var appearance = Appearance.light.rawValue
    @AppStorage(AppModel.introKey) private var showIntro = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsCard(title: "Görünüm", footer: "Açık görünüm varsayılandır. Sistem, macOS'un ayarını izler.") {
                    Picker("Görünüm", selection: $appearance) {
                        ForEach(Appearance.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                SettingsCard(title: "Açılış", footer: "Uygulama açılırken kervanın vahaya yürüdüğü kısa animasyon. Tıklayınca geçilir.") {
                    Toggle("Açılışta introyu göster", isOn: $showIntro)
                    Button("Introyu şimdi oynat") { model.showIntro = true }
                        .buttonStyle(.link)
                }

                SettingsCard(title: "Sunucu") {
                    LabeledContent("Adres") {
                        Text(model.activeAddress?.host ?? model.serverInput)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                    }
                    LabeledContent("Durum") {
                        HStack(spacing: 6) {
                            StatusDot(color: model.connection.state.tint, size: 7)
                            Text(model.connection.state.shortLabel)
                        }
                    }
                }
            }
            .padding(20)
        }
        .settingsPage()
    }
}

/// A titled group of settings on a soft card, with an optional note under it.
struct SettingsCard<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .softSurface()
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SkillsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var skills: [SkillInfo] = []
    @State private var busy = false
    @State private var error: String?
    @State private var removing: SkillInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Skill'ler, ajanın belirli bir işi nasıl yapacağını anlatan klasörlerdir (içinde SKILL.md). Yeni oturum açarken hangilerinin kullanılacağını seçersiniz.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List {
                ForEach(skills) { skill in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(skill.name).font(.body.monospaced())
                            Text(skill.description.isEmpty ? "Açıklama yok" : skill.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(skill.files) dosya").font(.caption).foregroundStyle(.secondary)
                        Button("Sil", role: .destructive) { removing = skill }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .softList()
            .overlay {
                if skills.isEmpty {
                    EmptyCard(symbol: "book.closed", title: "Henüz skill yok", text: "İçinde SKILL.md olan bir klasör ekleyin; yeni oturum açarken seçebilirsiniz.")
                }
            }

            HStack {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.kervanCoral).font(.callout)
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Skill klasörü ekle…", action: addSkill)
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || model.fileClient == nil)
            }
        }
        .padding(20)
        .settingsPage()
        .task { await reload() }
        .confirmationDialog(
            "\(removing?.name ?? "") skill'i silinsin mi?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
        ) {
            Button("Skill'i sil", role: .destructive) {
                if let skill = removing { Task { await remove(skill) } }
            }
        } message: {
            Text("Kütüphaneden kalkar. Bu skill ile açılmış oturumlardaki kopyalar etkilenmez.")
        }
    }

    private func addSkill() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Ekle"
        panel.message = "İçinde SKILL.md olan bir ya da daha fazla klasör seçin."
        guard panel.runModal() == .OK, let client = model.fileClient else { return }
        let folders = panel.urls
        Task {
            busy = true
            defer { busy = false }
            do {
                for folder in folders { try await client.uploadSkill(folder: folder) }
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            await reload()
        }
    }

    private func remove(_ skill: SkillInfo) async {
        do {
            try await model.fileClient?.deleteSkill(skill.name)
        } catch {
            self.error = error.localizedDescription
        }
        await reload()
    }

    private func reload() async {
        guard let client = model.fileClient else {
            error = "Önce sunucuya bağlanın."
            return
        }
        do {
            skills = try await client.listSkills()
        } catch {
            self.error = "Skill'ler alınamadı: \(error.localizedDescription)"
        }
    }
}

private struct McpSettings: View {
    @Environment(AppModel.self) private var model
    @State private var editing: McpDraft?
    @State private var removing: McpServerSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MCP sunucuları ajanlara yeni araçlar verir (GitHub, veritabanı, tarayıcı…). Gizli değerler yalnızca sunucuda tutulur; burada sadece adları görünür.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List {
                ForEach(model.store.mcpServers) { server in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.name).font(.body.monospaced())
                            Text(summary(server)).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Düzenle") { editing = McpDraft(server) }.buttonStyle(.borderless)
                        Button("Sil", role: .destructive) { removing = server }.buttonStyle(.borderless)
                    }
                }
            }
            .softList()
            .overlay {
                if model.store.mcpServers.isEmpty {
                    EmptyCard(symbol: "point.3.connected.trianglepath.dotted", title: "Henüz MCP sunucusu yok", text: "GitHub, veritabanı ya da tarayıcı gibi araçları ajanlara buradan verirsiniz.")
                }
            }

            HStack {
                Spacer()
                Button("MCP sunucusu ekle…") { editing = McpDraft() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.connection.state.isConnected)
            }
        }
        .padding(20)
        .settingsPage()
        .sheet(item: $editing) { draft in
            McpEditor(draft: draft) { input in
                Task { await model.store.saveMcp(input) }
            }
        }
        .confirmationDialog(
            "\(removing?.name ?? "") silinsin mi?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
        ) {
            Button("Sunucuyu sil", role: .destructive) {
                if let server = removing { Task { await model.store.deleteMcp(server.name) } }
            }
        } message: {
            Text("Kayıtlı gizli değerleri de silinir. Açık oturumlar bir sonraki yeniden başlatmada bu sunucuyu kullanamaz.")
        }
    }

    private func summary(_ server: McpServerSummary) -> String {
        let target = server.transport == .http ? server.url ?? "" : ([server.command ?? ""] + (server.args ?? [])).joined(separator: " ")
        let secrets = server.envKeys + server.headerKeys
        return secrets.isEmpty ? target : "\(target)  ·  \(secrets.joined(separator: ", "))"
    }
}

/// Form state for one MCP server. Secret rows loaded from the server start empty and mean "keep".
struct McpDraft: Identifiable {
    struct Secret: Identifiable {
        let id = UUID()
        var key: String
        var value: String
        /// Came from the server: an empty value keeps what is stored.
        var stored: Bool
    }

    let id = UUID()
    var isNew: Bool
    var name = ""
    var transport: McpServerSummary.Transport = .stdio
    var command = ""
    var args = ""
    var url = ""
    var secrets: [Secret] = []

    init() { isNew = true }

    init(_ server: McpServerSummary) {
        isNew = false
        name = server.name
        transport = server.transport
        command = server.command ?? ""
        args = joinArguments(server.args ?? [])
        url = server.url ?? ""
        secrets = (server.transport == .http ? server.headerKeys : server.envKeys).map { Secret(key: $0, value: "", stored: true) }
    }

    var input: McpServerInput {
        let map = Dictionary(
            secrets.filter { !$0.key.isEmpty }.map { ($0.key, $0.stored && $0.value.isEmpty ? nil : Optional($0.value)) },
            uniquingKeysWith: { _, last in last }
        )
        switch transport {
        case .stdio:
            return McpServerInput(name: name, transport: .stdio, command: command, args: splitArguments(args), env: map)
        case .http:
            return McpServerInput(name: name, transport: .http, url: url, headers: map)
        }
    }

    var isValid: Bool {
        !name.isEmpty && (transport == .stdio ? !command.trimmingCharacters(in: .whitespaces).isEmpty : url.hasPrefix("http"))
    }
}

private struct McpEditor: View {
    @State var draft: McpDraft
    let save: (McpServerInput) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("Ad", text: $draft.name, prompt: Text("github"))
                    .disabled(!draft.isNew)
                Picker("Bağlantı", selection: $draft.transport) {
                    Text("Komut (stdio)").tag(McpServerSummary.Transport.stdio)
                    Text("HTTP").tag(McpServerSummary.Transport.http)
                }
                .pickerStyle(.segmented)
                .disabled(!draft.isNew)

                if draft.transport == .stdio {
                    TextField("Komut", text: $draft.command, prompt: Text("npx"))
                        .font(.body.monospaced())
                    TextField("Argümanlar", text: $draft.args, prompt: Text("-y @modelcontextprotocol/server-github"))
                        .font(.body.monospaced())
                } else {
                    TextField("Adres", text: $draft.url, prompt: Text("https://mcp.example.com/mcp"))
                        .font(.body.monospaced())
                }

                Section(draft.transport == .stdio ? "Ortam değişkenleri" : "HTTP başlıkları") {
                    ForEach($draft.secrets) { $secret in
                        HStack {
                            TextField("Ad", text: $secret.key)
                                .font(.body.monospaced())
                                .disabled(secret.stored)
                            SecureField(secret.stored ? "kayıtlı — değiştirmek için yazın" : "Değer", text: $secret.value)
                            Button {
                                draft.secrets.removeAll { $0.id == secret.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("\(secret.key) satırını kaldır")
                        }
                    }
                    Button("Ekle") { draft.secrets.append(.init(key: "", value: "", stored: false)) }
                        .buttonStyle(.link)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            HStack {
                Spacer()
                Button("Vazgeç", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(draft.isNew ? "Ekle" : "Kaydet") {
                    save(draft.input)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!draft.isValid)
            }
            .padding(16)
        }
        .frame(width: 500, height: 420) // fits under the Settings window; the form scrolls
        .background(Color.kervanCanvas)
    }
}

private struct AgentsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var editing: AgentDraft?
    @State private var removing: AgentConfig?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sunucunun çalıştırabildiği ajanlar. Eklediğiniz ajan, kaydedilmeden önce sunucuda bir kez denenir; çalışmazsa eklenmez.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List {
                ForEach(model.store.agentConfigs) { agent in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(agent.name)
                                if agent.source == .builtin {
                                    Text("yerleşik").font(.caption2).foregroundStyle(.secondary)
                                }
                                if !agent.available {
                                    Text("çalışmıyor").font(.caption2).foregroundStyle(.kervanCoral)
                                }
                            }
                            Text(([agent.command] + agent.args).joined(separator: " "))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button("Düzenle") { editing = AgentDraft(agent) }.buttonStyle(.borderless)
                        if agent.source == .app {
                            Button("Sil", role: .destructive) { removing = agent }.buttonStyle(.borderless)
                        }
                    }
                }
            }
            .softList()

            NodesSection()

            HStack {
                Spacer()
                Button("Ajan ekle…") { editing = AgentDraft() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.connection.state.isConnected)
            }
        }
        .padding(20)
        .settingsPage()
        .task { await model.store.loadAgentConfigs() }
        .sheet(item: $editing) { draft in
            AgentEditor(draft: draft, nodes: model.store.nodes)
        }
        .confirmationDialog(
            "\(removing?.name ?? "") silinsin mi?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
        ) {
            Button("Ajanı sil", role: .destructive) {
                if let agent = removing { Task { await model.store.deleteAgent(agent.id) } }
            }
        } message: {
            Text("Bu ajanla açılmış oturumlar geçmişleriyle kalır ama yeniden başlatılamaz.")
        }
    }
}

/// Form state for one agent. Editing a built-in agent saves an app-managed copy that replaces it.
struct AgentDraft: Identifiable {
    enum Kind: Hashable { case builtin, command }

    let id = UUID()
    var isNew: Bool
    var agentID = ""
    var name = ""
    var kind: Kind = .command
    var command = ""
    var args = ""
    var authMethod = ""
    var skillsDir = ""
    var node = "local"
    var terminal = false
    var quietMs: Int?
    var secrets: [McpDraft.Secret] = []

    static let builtinIDs = ["claude", "codex", "gemini"]

    init() { isNew = true }

    init(_ agent: AgentConfig) {
        isNew = false
        agentID = agent.id
        name = agent.name
        // Built-in agents are listed with their resolved path; editing keeps them on the shipped adapter.
        kind = agent.source == .builtin && Self.builtinIDs.contains(agent.id) || agent.command == "builtin" ? .builtin : .command
        command = kind == .builtin ? "" : agent.command
        args = kind == .builtin ? "" : joinArguments(agent.args)
        authMethod = agent.authMethod ?? ""
        skillsDir = agent.skillsDir ?? ""
        node = agent.node
        terminal = agent.protocol == "pty"
        quietMs = agent.quietMs
        secrets = agent.envKeys.map { McpDraft.Secret(key: $0, value: "", stored: agent.source == .app) }
    }

    var input: AgentInput {
        AgentInput(
            id: agentID,
            name: name,
            command: kind == .builtin ? "builtin" : command,
            args: kind == .builtin ? [] : splitArguments(args),
            authMethod: authMethod.isEmpty ? nil : authMethod,
            skillsDir: skillsDir.isEmpty ? nil : skillsDir,
            env: Dictionary(
                secrets.filter { !$0.key.isEmpty }.map { ($0.key, $0.stored && $0.value.isEmpty ? nil : Optional($0.value)) },
                uniquingKeysWith: { _, last in last }
            ),
            node: node,
            protocol: terminal ? "pty" : nil,
            quietMs: terminal ? quietMs : nil
        )
    }

    var isValid: Bool {
        !agentID.isEmpty && !name.isEmpty && (kind == .builtin ? Self.builtinIDs.contains(agentID) : !command.isEmpty)
    }
}

private struct AgentEditor: View {
    @State var draft: AgentDraft
    let nodes: [String]
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("Kimlik", text: $draft.agentID, prompt: Text("opencode"))
                    .font(.body.monospaced())
                    .disabled(!draft.isNew)
                TextField("Ad", text: $draft.name, prompt: Text("OpenCode"))
                Picker("Node", selection: $draft.node) {
                    ForEach(nodes, id: \.self) { node in
                        Text(node == "local" ? "Bu sunucu" : node).tag(node)
                    }
                }
                .help("Ajanın çalışacağı makine. Bu sunucu ya da ona bağlanmış bir kervan-node.")

                Picker("Kaynak", selection: $draft.kind) {
                    Text("Komut").tag(AgentDraft.Kind.command)
                    Text("Yerleşik adaptör").tag(AgentDraft.Kind.builtin)
                }
                .pickerStyle(.segmented)

                if draft.kind == .command {
                    TextField("Komut", text: $draft.command, prompt: Text("opencode"))
                        .font(.body.monospaced())
                    TextField("Argümanlar", text: $draft.args, prompt: Text("acp"))
                        .font(.body.monospaced())
                } else {
                    Text("Sunucuyla gelen adaptör kullanılır; kimlik claude, codex ya da gemini olmalı.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if draft.kind == .command {
                    Toggle(isOn: $draft.terminal) {
                        Text("Terminal üzerinden çalıştır")
                        Text("ACP desteklemeyen, satır satır çalışan araçlar için. Mesajlar terminale yazılır; ajan sustuğunda yanıt bitmiş sayılır. Onay kartı ve kaldığı yerden devam yoktur.")
                    }
                    if draft.terminal {
                        LabeledContent("Sessizlik süresi") {
                            HStack(spacing: 4) {
                                TextField("Sessizlik süresi", value: $draft.quietMs, format: .number, prompt: Text("2000"))
                                    .labelsHidden()
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 80)
                                Text("ms").foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                TextField("Kimlik doğrulama yöntemi", text: $draft.authMethod, prompt: Text("isteğe bağlı, ör. gemini-api-key"))
                    .font(.body.monospaced())
                TextField("Skill klasörü", text: $draft.skillsDir, prompt: Text("isteğe bağlı, ör. .claude/skills"))
                    .font(.body.monospaced())

                Section("Ortam değişkenleri") {
                    ForEach($draft.secrets) { $secret in
                        HStack {
                            TextField("Ad", text: $secret.key)
                                .font(.body.monospaced())
                                .disabled(secret.stored)
                            SecureField(secret.stored ? "kayıtlı — değiştirmek için yazın" : "Değer", text: $secret.value)
                            Button {
                                draft.secrets.removeAll { $0.id == secret.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("\(secret.key) satırını kaldır")
                        }
                    }
                    Button("Ekle") { draft.secrets.append(.init(key: "", value: "", stored: false)) }
                        .buttonStyle(.link)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .disabled(saving)

            HStack {
                if saving {
                    ProgressView().controlSize(.small)
                    Text("Ajan sunucuda deneniyor…").foregroundStyle(.secondary)
                } else if let error = model.store.agentSaveError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.kervanCoral)
                        .lineLimit(3)
                        .font(.callout)
                }
                Spacer()
                Button("Vazgeç", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(draft.isNew ? "Dene ve ekle" : "Dene ve kaydet") {
                    Task {
                        saving = true
                        await model.store.saveAgent(draft.input)
                        saving = false
                        if model.store.agentSaveError == nil { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!draft.isValid || saving)
            }
            .padding(16)
        }
        .frame(width: 520, height: 440) // fits under the Settings window; the form scrolls
        .background(Color.kervanCanvas)
    }
}

/// What an empty settings list says: what belongs here and how to add the first one.
struct EmptyCard: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Color.kervanLapis.opacity(0.6))
            Text(title).font(.headline)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .padding(24)
    }
}
