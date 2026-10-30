import AppKit
import KervanKit
import SwiftUI

/// The panel next to a chat: its files, what the agent changed, a shell in its folder, and server ports.
struct SessionInspector: View {
    let sessionID: String
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Picker("Panel", selection: $model.panel) {
                ForEach(SessionPanel.allCases) { panel in
                    Label(panel.title, systemImage: panel.symbol).tag(panel)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .help(model.panel.title)

            switch model.panel {
            case .files: FilesPanel(sessionID: sessionID)
            case .changes: ChangesPanel(sessionID: sessionID)
            case .terminal: TerminalPanel(sessionID: sessionID)
            case .preview: PreviewPanel()
            }
        }
        // Long lists scroll inside the panel; they never make the window taller.
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
    }
}

private struct PanelHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            trailing
        }
        .padding(12)
    }
}

private struct PanelMessage: View {
    let text: String
    var symbol: String?
    var tint: Color = .secondary

    var body: some View {
        Group {
            if let symbol {
                Label(text, systemImage: symbol)
            } else {
                Text(text)
            }
        }
        .font(.callout)
        .foregroundStyle(tint)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Changes

/// What the agent changed in the folder, file by file, with ways to undo it or commit it.
struct ChangesPanel: View {
    let sessionID: String
    @Environment(AppModel.self) private var model
    @State private var sinceTurn = false
    @State private var open: Set<String> = []
    @State private var error: String?
    @State private var working = false
    @State private var commitMessage = ""
    @State private var confirmRevertAll = false

    var body: some View {
        let store = model.store
        let changes = store.changes[sessionID]
        let busy = [.running, .waiting].contains(store.session(sessionID)?.status)

        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: "Değişiklikler") {
                Button {
                    Task { await load() }
                } label: {
                    Label("Yenile", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Yenile")
            }
            Picker("Kapsam", selection: $sinceTurn) {
                Text("Tüm oturum").tag(false)
                Text("Son mesaj").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Divider()

            if let error {
                PanelMessage(text: error, symbol: "exclamationmark.triangle", tint: .kervanCoral)
            }
            if let changes {
                if changes.files.isEmpty {
                    PanelMessage(text: changes.sinceSeq == nil
                        ? "İlk mesajınızdan sonra ajanın değiştirdiği dosyalar burada görünür."
                        : "Bu aralıkta değişen dosya yok.")
                } else {
                    summary(changes)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            let patches = changes.patches
                            ForEach(changes.files) { file in
                                fileRow(file, patch: patches[file.path], since: changes.sinceSeq, busy: busy)
                            }
                            if changes.truncated {
                                Text("Fark çok uzun; ilk kısmı gösteriliyor.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                    }
                    if changes.repository {
                        commitBox(changes)
                    }
                }
            } else if error == nil {
                ProgressView().frame(maxWidth: .infinity).padding()
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .task(id: "\(sessionID)-\(sinceTurn)-\(store.session(sessionID)?.status.rawValue ?? "")") { await load() }
        .confirmationDialog("Bütün değişiklikler geri alınsın mı?", isPresented: $confirmRevertAll) {
            Button("Hepsini geri al", role: .destructive) {
                if let seq = changes?.sinceSeq { Task { await revert(seq: seq, paths: []) } }
            }
        } message: {
            Text("Dosyalar \(sinceTurn ? "son mesajınızdan" : "ilk mesajınızdan") önceki hâline döner; ajanın sonradan oluşturduğu dosyalar silinir. Ajana bir sonraki mesajınızda söylenir.")
        }
    }

    private func summary(_ changes: ChangeSet) -> some View {
        let added = changes.files.reduce(0) { $0 + $1.additions }
        let removed = changes.files.reduce(0) { $0 + $1.deletions }
        return HStack(spacing: 8) {
            Text("\(changes.files.count) dosya").font(.callout.weight(.medium))
            LineCounts(added: added, removed: removed)
            Spacer()
            if changes.sinceSeq != nil {
                Button("Hepsini geri al") { confirmRevertAll = true }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.kervanCoral)
                    .disabled(working || [.running, .waiting].contains(model.store.session(sessionID)?.status))
                    .help("Ajan çalışırken geri alınamaz")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    private func fileRow(_ file: ChangedFile, patch: String?, since: Int?, busy: Bool) -> some View {
        let isOpen = open.contains(file.path)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    if isOpen { open.remove(file.path) } else { open.insert(file.path) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                            .foregroundStyle(.secondary)
                        Text(Self.badge(file.status))
                            .font(.caption2.weight(.bold).monospaced())
                            .foregroundStyle(Self.tint(file.status))
                            .frame(width: 12)
                        Text(file.path)
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer(minLength: 4)
                        LineCounts(added: file.additions, removed: file.deletions)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(file.path), \(Self.statusName(file.status))")
                if let since {
                    Button {
                        Task { await revert(seq: since, paths: [file.path]) }
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .disabled(working || busy)
                    .help("Bu dosyayı geri al")
                    .accessibilityLabel("\(file.path) dosyasını geri al")
                }
            }
            if isOpen {
                if let patch, !DiffLine.parse(patch: patch).isEmpty {
                    DiffLinesView(lines: DiffLine.parse(patch: patch), limit: 200)
                } else {
                    Text("İkili dosya ya da fark gösterilemiyor.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func commitBox(_ changes: ChangeSet) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
                Text(changes.branch ?? "git").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            TextField("Commit mesajı", text: $commitMessage, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
            HStack {
                Text("Klasördeki bütün değişiklikler commit edilir.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Commit") { Task { await commit() } }
                    .buttonStyle(.borderedProminent)
                    .tint(.kervanLapis)
                    .disabled(commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
            }
        }
        .padding(12)
    }

    private func load() async {
        error = await model.store.loadChanges(sessionID, sinceTurn: sinceTurn)
    }

    private func revert(seq: Int, paths: [String]) async {
        working = true
        defer { working = false }
        error = await model.store.revert(sessionID, toBefore: seq, paths: paths)
        await load()
    }

    private func commit() async {
        working = true
        defer { working = false }
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if let failure = await model.store.commit(sessionID, message: message) {
            error = failure == "nothing to commit" ? "Commit edilecek değişiklik yok." : failure
        } else {
            commitMessage = ""
            error = nil
        }
        await load()
    }

    private static func badge(_ status: ChangedFile.Status) -> String {
        switch status {
        case .added: "A"
        case .modified: "M"
        case .deleted: "D"
        }
    }

    private static func statusName(_ status: ChangedFile.Status) -> String {
        switch status {
        case .added: "eklendi"
        case .modified: "değişti"
        case .deleted: "silindi"
        }
    }

    private static func tint(_ status: ChangedFile.Status) -> Color {
        switch status {
        case .added: .kervanOasis
        case .modified: .kervanSaffron
        case .deleted: .kervanCoral
        }
    }
}

// MARK: Terminal

/// A shell in the session's folder on the server, for commands of your own.
struct TerminalPanel: View {
    let sessionID: String
    @Environment(AppModel.self) private var model
    @State private var line = ""
    @State private var error: String?
    @State private var history: [String] = []
    @State private var back = 0
    @FocusState private var focused: Bool

    var body: some View {
        let terminal = model.store.terminals[sessionID]
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: "Terminal") {
                Button("Ctrl-C") { Task { await model.store.typeInTerminal(sessionID, "\u{3}") } }
                    .buttonStyle(.borderless)
                    .font(.caption.monospaced())
                    .help("Çalışan komutu durdur")
                    .disabled(terminal == nil || terminal?.exited == true)
                Button {
                    model.store.clearTerminal(sessionID)
                } label: {
                    Label("Temizle", systemImage: "eraser")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Ekranı temizle")
            }
            Divider()
            if let error {
                PanelMessage(text: error, symbol: "exclamationmark.triangle", tint: .kervanCoral)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(terminal?.output ?? "")
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    Color.clear.frame(height: 1).id("end")
                }
                .background(Color.kervanWell.opacity(0.45))
                .onChange(of: terminal?.output.count) { proxy.scrollTo("end", anchor: .bottom) }
                .onTapGesture { focused = true }
            }
            if terminal?.exited == true {
                HStack {
                    Text("Kabuk kapandı.").font(.callout).foregroundStyle(.secondary)
                    Button("Yeniden aç") { Task { await open() } }.buttonStyle(.link)
                }
                .padding(10)
            } else {
                HStack(spacing: 6) {
                    Text("$").font(.callout.monospaced()).foregroundStyle(.secondary)
                    TextField("Komut", text: $line)
                        .textFieldStyle(.plain)
                        .font(.callout.monospaced())
                        .focused($focused)
                        .onSubmit(run)
                        .onKeyPress(.upArrow) { recall(1) }
                        .onKeyPress(.downArrow) { recall(-1) }
                        .disabled(terminal == nil)
                }
                .padding(10)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .task(id: sessionID) { await open() }
    }

    private func open() async {
        error = await model.store.openTerminal(sessionID)
        focused = true
    }

    private func run() {
        let command = line
        line = ""
        back = 0
        if !command.trimmingCharacters(in: .whitespaces).isEmpty { history.append(command) }
        Task { await model.store.typeInTerminal(sessionID, command + "\n") }
        focused = true
    }

    private func recall(_ step: Int) -> KeyPress.Result {
        guard !history.isEmpty else { return .ignored }
        back = min(max(back + step, 0), history.count)
        line = back == 0 ? "" : history[history.count - back]
        return .handled
    }
}

// MARK: Preview

/// Ports something listens on, on the server; one click makes a port answer on this Mac and opens it.
struct PreviewPanel: View {
    @Environment(AppModel.self) private var model
    @State private var error: String?
    @State private var custom = ""

    var body: some View {
        let ports = model.store.ports
        let forwards = model.forwarder.forwards
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: "Önizleme") {
                Button {
                    Task { await model.store.loadPorts() }
                } label: {
                    Label("Yenile", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Portları yeniden tara")
            }
            Divider()
            Text("Ajanın sunucuda başlattığı geliştirme sunucularını bu Mac'te localhost olarak açar.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(12)
            if let error {
                PanelMessage(text: error, symbol: "exclamationmark.triangle", tint: .kervanCoral)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let ports, ports.isEmpty {
                        Text("Sunucuda dinleyen port yok. Ajandan geliştirme sunucusunu başlatmasını isteyin.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else if ports == nil {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                    ForEach(ports ?? []) { port in
                        portRow(port.port, process: port.process, forward: forwards[port.port])
                    }
                    ForEach(forwards.values.filter { forward in !(ports ?? []).contains { $0.port == forward.remote } }) { forward in
                        portRow(forward.remote, process: nil, forward: forward)
                    }
                    HStack(spacing: 6) {
                        TextField("Port", text: $custom, prompt: Text("Başka bir port, ör. 8000"))
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { if let port = Int(custom) { open(port) } }
                        Button("Aç") { if let port = Int(custom) { open(port) } }
                            .disabled(Int(custom).map { !(1...65535).contains($0) } ?? true)
                    }
                    .padding(.top, 6)
                }
                .padding(12)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .task { await model.store.loadPorts() }
    }

    private func portRow(_ port: Int, process: String?, forward: PortForwarder.Forward?) -> some View {
        HStack(spacing: 10) {
            StatusDot(color: forward == nil ? .secondary.opacity(0.5) : .kervanOasis)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: ":\(port)").font(.callout.monospaced().weight(.medium))
                Text(forward.map { "localhost:\($0.local) üzerinden açık" } ?? process ?? "dinliyor")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let forward {
                Button("Aç") { NSWorkspace.shared.open(forward.url) }
                Button {
                    model.forwarder.stop(port)
                } label: {
                    Image(systemName: "stop.circle")
                }
                .buttonStyle(.borderless)
                .help("Yönlendirmeyi durdur")
                .accessibilityLabel("Port \(port) yönlendirmesini durdur")
            } else {
                Button("Tarayıcıda aç") { open(port) }
                    .buttonStyle(.borderedProminent)
                    .tint(.kervanLapis)
            }
        }
        .controlSize(.small)
        .padding(10)
        .softSurface(radius: Radius.chip, lift: false)
        .accessibilityElement(children: .contain)
    }

    private func open(_ port: Int) {
        error = nil
        guard let request = model.tunnelRequest(port: port) else { return }
        Task {
            do {
                let forward = try await model.forwarder.open(port, request: request)
                NSWorkspace.shared.open(forward.url)
                custom = ""
            } catch {
                self.error = "Port \(port) açılamadı: \(error.localizedDescription)"
            }
        }
    }
}
