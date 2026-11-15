import KervanKit
import SwiftUI

/// The project's env variables, edited here because the project's folder is on the server, not on this Mac.
struct ProjectEnvSection: View {
    let project: ProjectInfo

    var body: some View {
        SettingsCard(
            title: L("Environment variables", "Ortam değişkenleri"),
            footer: L(
                "Saved into the env file in the project's folder on the server, and into the folders of the project's open sessions, so the app their agents run finds the values.",
                "Sunucudaki proje klasöründeki env dosyasına ve projenin açık oturumlarının klasörlerine yazılır; böylece ajanların çalıştırdığı uygulama değerleri bulur."
            )
        ) {
            EnvEditor(project: project, initialFile: nil)
        }
    }
}

/// The same editor in a sheet, opened from an env file in a session's Files panel.
struct EnvEditorSheet: View {
    let projectID: String
    let file: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Environment variables", "Ortam değişkenleri")).font(.title2.weight(.semibold))
            if let project = model.store.project(projectID) {
                ScrollView { EnvEditor(project: project, initialFile: file) }
            }
            HStack {
                Spacer()
                Button(L("Close", "Kapat")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 520)
        .background(Color.kervanCanvas)
    }
}

/// Edits one env file of a project: its variables, what an example file or an agent says is missing, and whether
/// the project's red lines keep agents out of it.
struct EnvEditor: View {
    let project: ProjectInfo
    let initialFile: String?
    @Environment(AppModel.self) private var model
    @State private var file: String?
    @State private var entries: [ProjectEnv.Entry] = []
    @State private var loadedEntries: [ProjectEnv.Entry] = []
    @State private var revealed: Set<UUID> = []
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?
    @State private var saved = false
    @State private var newFileName = ""
    @State private var addingFile = false

    private var env: ProjectEnv? {
        guard let env = model.store.projectEnvs[project.id], file == nil || env.file == file else { return nil }
        return env
    }
    private var dirty: Bool { entries.map { [$0.key, $0.value] } != loadedEntries.map { [$0.key, $0.value] } }
    private var requests: [EnvRequest] { project.envRequests ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if loading && env == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L("Reading the env file…", "Env dosyası okunuyor…")).foregroundStyle(.secondary)
                }
            } else if let env {
                header(env)
                if !requests.isEmpty { agentRequests }
                missing(env)
                rows
                footer(env)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.kervanCoral).font(.callout)
            }
        }
        .task(id: project.id) { await load(initialFile) }
    }

    private func header(_ env: ProjectEnv) -> some View {
        HStack(spacing: 8) {
            Picker(L("File", "Dosya"), selection: Binding(get: { env.file }, set: { name in Task { await load(name) } })) {
                ForEach(Array(Set(env.files + [env.file])).sorted(by: Self.envOrder), id: \.self) { name in
                    Text(verbatim: name).tag(name)
                }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(dirty)
            .help(dirty ? L("Save or undo your changes first", "Önce değişikliklerinizi kaydedin ya da geri alın") : "")
            if !env.exists {
                Text(L("new file", "yeni dosya")).font(.caption).foregroundStyle(.secondary)
            }
            Button(L("Other file…", "Başka dosya…")) { addingFile = true }
                .buttonStyle(.borderless)
                .disabled(dirty)
                .popover(isPresented: $addingFile) { newFilePopover }
            Spacer()
            protection(env)
        }
    }

    @ViewBuilder private func protection(_ env: ProjectEnv) -> some View {
        if let pattern = env.protectedBy {
            Label(L("Agents can't read it", "Ajanlar okuyamaz"), systemImage: "lock.shield")
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.kervanLapis)
                .help(L("A red line of this project (\(pattern)) keeps agents out of this file. Apps they run still load it.", "Bu projenin bir kırmızı çizgisi (\(pattern)) ajanları bu dosyadan uzak tutar. Çalıştırdıkları uygulama onu yine yükler."))
        } else {
            Button {
                Task { await protectEnvFiles() }
            } label: {
                Label(L("Keep agents out", "Ajanlardan koru"), systemImage: "lock.open")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.kervanSaffron)
            .help(L("Adds .env and .env.* to the project's red lines: agents can no longer read these files, though the apps they run still load them.", ".env ve .env.* dosyalarını projenin kırmızı çizgilerine ekler: ajanlar bu dosyaları artık okuyamaz, çalıştırdıkları uygulamalar ise yüklemeye devam eder."))
        }
    }

    private var newFilePopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(L("File name", "Dosya adı"), text: $newFileName, prompt: Text(verbatim: ".env.local"))
                .font(.body.monospaced())
                .frame(width: 200)
                .onSubmit(openNewFile)
            HStack {
                Spacer()
                Button(L("Open", "Aç"), action: openNewFile)
                    .disabled(!Self.isEnvName(newFileName))
            }
        }
        .padding(12)
    }

    private var agentRequests: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(requests) { request in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "hand.raised").foregroundStyle(Color.kervanSaffron)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("An agent needs \(request.keys.joined(separator: ", "))", "Bir ajan \(request.keys.joined(separator: ", ")) istiyor"))
                            .font(.callout.weight(.medium))
                        Text(request.reason).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L("Fill in", "Doldur")) { add(request.keys) }
                        .disabled(request.keys.allSatisfy { key in entries.contains { $0.key == key } })
                    if model.store.session(request.sessionId) != nil {
                        Button(L("Session", "Oturum")) { model.selectedSessionID = request.sessionId }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
        .padding(10)
        .background(Color.kervanSaffron.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder private func missing(_ env: ProjectEnv) -> some View {
        let notAdded = env.missing.filter { key in !entries.contains { $0.key == key } }
        if !notAdded.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
                Text(env.example.map { L("\($0) also lists: \(notAdded.joined(separator: ", "))", "\($0) dosyasında bunlar da var: \(notAdded.joined(separator: ", "))") }
                    ?? L("Still missing: \(notAdded.joined(separator: ", "))", "Hâlâ eksik: \(notAdded.joined(separator: ", "))"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(L("Add them", "Ekle")) { add(notAdded) }
            }
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 6) {
            if entries.isEmpty {
                Text(L("No variables yet.", "Henüz değişken yok.")).foregroundStyle(.secondary)
            }
            ForEach($entries) { $entry in
                row($entry)
            }
            Button {
                entries.append(ProjectEnv.Entry(key: "", value: ""))
            } label: {
                Label(L("Add variable", "Değişken ekle"), systemImage: "plus")
            }
            .buttonStyle(.borderless)
        }
    }

    private func row(_ entry: Binding<ProjectEnv.Entry>) -> some View {
        let id = entry.wrappedValue.id
        let secret = ProjectEnv.looksSecret(entry.wrappedValue.key)
        let hidden = secret && !revealed.contains(id)
        return HStack(spacing: 6) {
            TextField(L("NAME", "AD"), text: entry.key)
                .font(.callout.monospaced())
                .frame(width: 190)
            Group {
                if hidden {
                    SecureField(L("value", "değer"), text: entry.value)
                } else {
                    TextField(L("value", "değer"), text: entry.value)
                }
            }
            .font(.callout.monospaced())
            if secret {
                Button {
                    if revealed.contains(id) { revealed.remove(id) } else { revealed.insert(id) }
                } label: {
                    Image(systemName: hidden ? "eye" : "eye.slash")
                }
                .buttonStyle(.borderless)
                .help(hidden ? L("Show the value", "Değeri göster") : L("Hide the value", "Değeri gizle"))
            }
            Button {
                entries.removeAll { $0.id == id }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help(L("Remove", "Kaldır"))
        }
    }

    private func footer(_ env: ProjectEnv) -> some View {
        HStack(spacing: 8) {
            if saving {
                ProgressView().controlSize(.small)
            } else if saved && !dirty {
                Label(L("Saved", "Kaydedildi"), systemImage: "checkmark").foregroundStyle(.secondary).font(.callout)
            }
            Spacer()
            Button(L("Undo", "Geri al")) { entries = loadedEntries }
                .disabled(!dirty || saving)
            Button(L("Save \(env.file)", "\(env.file) dosyasını kaydet")) { Task { await save(env.file) } }
                .buttonStyle(.kervanPrimary)
                .disabled(!dirty || saving || entries.contains { $0.key.trimmingCharacters(in: .whitespaces).isEmpty })
        }
    }

    // MARK: Actions

    private func load(_ name: String?) async {
        loading = true
        defer { loading = false }
        if let failure = await model.store.loadEnv(project.id, file: name) {
            error = failure
            return
        }
        error = nil
        saved = false
        let env = model.store.projectEnvs[project.id]
        file = env?.file
        entries = env?.entries ?? []
        loadedEntries = entries
        revealed = []
    }

    private func save(_ name: String) async {
        saving = true
        defer { saving = false }
        let cleaned = entries.map { ProjectEnv.Entry(key: $0.key.trimmingCharacters(in: .whitespaces), value: $0.value) }
        if let failure = await model.store.saveEnv(project.id, file: name, entries: cleaned) {
            error = failure
            return
        }
        error = nil
        saved = true
        entries = model.store.projectEnvs[project.id]?.entries ?? cleaned
        loadedEntries = entries
    }

    private func add(_ keys: [String]) {
        for key in keys where !entries.contains(where: { $0.key == key }) {
            entries.append(ProjectEnv.Entry(key: key, value: ""))
        }
    }

    private func openNewFile() {
        let name = newFileName.trimmingCharacters(in: .whitespaces)
        guard Self.isEnvName(name) else { return }
        addingFile = false
        newFileName = ""
        Task { await load(name) }
    }

    private func protectEnvFiles() async {
        var lines = project.redLines ?? RedLines()
        for path in RedLines.envPaths where !lines.paths.contains(path) { lines.paths.append(path) }
        var input = ProjectInput(id: project.id, name: project.name, instructions: project.instructions)
        input.redLines = lines
        if let failure = await model.store.saveProject(input) {
            error = failure
            return
        }
        await load(file)
    }

    static func isEnvName(_ name: String) -> Bool {
        name.range(of: #"^\.env(\.[A-Za-z0-9_-]+)*$"#, options: .regularExpression) != nil
    }

    /// `.env` first, then the rest by name.
    static func envOrder(_ a: String, _ b: String) -> Bool {
        if a == ".env" { return b != ".env" }
        if b == ".env" { return false }
        return a < b
    }
}

/// What no agent in the project may do, shown on the project page; edited in the project's settings.
struct ProjectRedLinesSection: View {
    let project: ProjectInfo
    let edit: () -> Void

    var body: some View {
        SettingsCard(
            title: L("Red lines", "Kırmızı çizgiler"),
            footer: L(
                "Agents don't get past the files: Kervan refuses and stops them, and Claude Code refuses them by itself too. Rules are told to every agent as rules it must never break.",
                "Ajanlar dosyalara geçemez: Kervan reddeder ve durdurur, Claude Code da kendi başına reddeder. Kurallar her ajana asla çiğnenmeyecek kurallar olarak söylenir."
            )
        ) {
            let lines = project.redLines ?? RedLines()
            if lines.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Text(L("None yet. Agents may read every file in the project, env files included.", "Henüz yok. Ajanlar projedeki her dosyayı okuyabilir, env dosyaları da dahil."))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(L("Draw red lines…", "Kırmızı çizgi çiz…"), action: edit)
                }
            } else {
                if !lines.paths.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Files agents can't touch", "Ajanların dokunamayacağı dosyalar")).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            ForEach(lines.paths, id: \.self) { path in
                                Label(path, systemImage: "lock")
                                    .font(.caption.monospaced())
                                    .padding(.vertical, 3)
                                    .padding(.horizontal, 7)
                                    .background(Color.kervanCoral.opacity(0.12), in: Capsule())
                            }
                        }
                    }
                }
                if !lines.rules.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Rules", "Kurallar")).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        ForEach(lines.rules, id: \.self) { rule in
                            Label(rule, systemImage: "nosign").font(.callout)
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button(L("Edit…", "Düzenle…"), action: edit)
                }
            }
        }
    }
}
