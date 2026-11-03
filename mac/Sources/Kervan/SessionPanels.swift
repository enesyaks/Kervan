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
    @State private var proposing = false
    /// What the last pull request did, shown under the commit box.
    @State private var proposed: PullRequestInfo?

    var body: some View {
        let store = model.store
        let changes = store.changes[sessionID]
        let busy = [.running, .waiting].contains(store.session(sessionID)?.status)

        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: L("Changes", "Değişiklikler")) {
                Button {
                    Task { await load() }
                } label: {
                    Label(L("Refresh", "Yenile"), systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(L("Refresh", "Yenile"))
            }
            Picker(L("Scope", "Kapsam"), selection: $sinceTurn) {
                Text(L("Whole session", "Tüm oturum")).tag(false)
                Text(L("Last message", "Son mesaj")).tag(true)
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
                        ? L("Files the agent changes after your first message show up here.", "İlk mesajınızdan sonra ajanın değiştirdiği dosyalar burada görünür.")
                        : L("No files changed in this range.", "Bu aralıkta değişen dosya yok."))
                } else {
                    summary(changes)
                    if let review = store.latestReview(of: sessionID) {
                        ReviewCard(review: review, authorID: sessionID)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            let patches = changes.patches
                            ForEach(changes.files) { file in
                                fileRow(file, patch: patches[file.path], since: changes.sinceSeq, busy: busy)
                            }
                            if changes.truncated {
                                Text(L("The diff is very long; showing the first part.", "Fark çok uzun; ilk kısmı gösteriliyor.")).font(.caption).foregroundStyle(.secondary)
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
        .confirmationDialog(L("Revert all changes?", "Bütün değişiklikler geri alınsın mı?"), isPresented: $confirmRevertAll) {
            Button(L("Revert all", "Hepsini geri al"), role: .destructive) {
                if let seq = changes?.sinceSeq { Task { await revert(seq: seq, paths: []) } }
            }
        } message: {
            Text(L("Files go back to how they were before your \(sinceTurn ? "last" : "first") message; files the agent created since are deleted. The agent is told with your next message.", "Dosyalar \(sinceTurn ? "son mesajınızdan" : "ilk mesajınızdan") önceki hâline döner; ajanın sonradan oluşturduğu dosyalar silinir. Ajana bir sonraki mesajınızda söylenir."))
        }
    }

    private func summary(_ changes: ChangeSet) -> some View {
        let added = changes.files.reduce(0) { $0 + $1.additions }
        let removed = changes.files.reduce(0) { $0 + $1.deletions }
        return HStack(spacing: 8) {
            Text(fileCount(changes.files.count)).font(.callout.weight(.medium))
            LineCounts(added: added, removed: removed)
            Spacer()
            // A second opinion from another agent, on a copy of the files.
            Menu(L("Review with…", "İncelet…")) {
                ForEach(model.store.agents) { agent in
                    Button(agent.displayName) {
                        Task { error = await model.store.review(sessionID, agent: agent.id) }
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(working || [.running, .waiting].contains(model.store.session(sessionID)?.status))
            .help(L("Another agent reads these changes on a copy and lists problems, most severe first", "Başka bir ajan bu değişiklikleri bir kopyada okur ve sorunları önem sırasıyla listeler"))
            if changes.sinceSeq != nil {
                Button(L("Revert all", "Hepsini geri al")) { confirmRevertAll = true }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.kervanCoral)
                    .disabled(working || [.running, .waiting].contains(model.store.session(sessionID)?.status))
                    .help(L("Can't revert while the agent is working", "Ajan çalışırken geri alınamaz"))
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
                    .help(L("Revert this file", "Bu dosyayı geri al"))
                    .accessibilityLabel(L("Revert \(file.path)", "\(file.path) dosyasını geri al"))
                }
            }
            if isOpen {
                if let patch, !DiffLine.parse(patch: patch).isEmpty {
                    DiffLinesView(lines: DiffLine.parse(patch: patch), limit: 200)
                } else {
                    Text(L("Binary file, or the diff can't be shown.", "İkili dosya ya da fark gösterilemiyor.")).font(.caption).foregroundStyle(.secondary)
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
            TextField(L("Commit message", "Commit mesajı"), text: $commitMessage, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
            // On its own line: the panel can be as narrow as 280 points, and the buttons need their full names.
            Text(L("Commits every change in the folder.", "Klasördeki bütün değişiklikler commit edilir.")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L("Pull request…", "Pull request…")) { proposing = true }
                    .disabled(working)
                    .help(L("Push this work on a branch of its own and open a pull request", "Bu işi kendi branch'inde push edip pull request açar"))
                Button("Commit") { Task { await commit() } }
                    .buttonStyle(.borderedProminent)
                    .tint(.kervanLapis)
                    .disabled(commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
            }
            if let proposed {
                ProposedNote(pullRequest: proposed)
            }
        }
        .padding(12)
        .sheet(isPresented: $proposing) {
            PullRequestSheet(
                sessionID: sessionID,
                title: commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? model.store.session(sessionID)?.title ?? ""
                    : commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            ) { result in
                proposed = result
                commitMessage = ""
                Task { await load() }
            }
            .environment(model)
        }
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
            error = failure == "nothing to commit" ? L("Nothing to commit.", "Commit edilecek değişiklik yok.") : failure
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
        case .added: L("added", "eklendi")
        case .modified: L("changed", "değişti")
        case .deleted: L("deleted", "silindi")
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
                    .help(L("Stop the running command", "Çalışan komutu durdur"))
                    .disabled(terminal == nil || terminal?.exited == true)
                Button {
                    model.store.clearTerminal(sessionID)
                } label: {
                    Label(L("Clear", "Temizle"), systemImage: "eraser")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(L("Clear the screen", "Ekranı temizle"))
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
                    Text(L("The shell exited.", "Kabuk kapandı.")).font(.callout).foregroundStyle(.secondary)
                    Button(L("Reopen", "Yeniden aç")) { Task { await open() } }.buttonStyle(.link)
                }
                .padding(10)
            } else {
                HStack(spacing: 6) {
                    Text("$").font(.callout.monospaced()).foregroundStyle(.secondary)
                    TextField(L("Command", "Komut"), text: $line)
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
            PanelHeader(title: L("Preview", "Önizleme")) {
                Button {
                    Task { await model.store.loadPorts() }
                } label: {
                    Label(L("Refresh", "Yenile"), systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(L("Scan ports again", "Portları yeniden tara"))
            }
            Divider()
            Text(L("Opens dev servers the agent started on the server as localhost on this Mac.", "Ajanın sunucuda başlattığı geliştirme sunucularını bu Mac'te localhost olarak açar."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(12)
            if let error {
                PanelMessage(text: error, symbol: "exclamationmark.triangle", tint: .kervanCoral)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let ports, ports.isEmpty {
                        Text(L("Nothing is listening on the server. Ask the agent to start a dev server.", "Sunucuda dinleyen port yok. Ajandan geliştirme sunucusunu başlatmasını isteyin."))
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
                        TextField("Port", text: $custom, prompt: Text(L("Another port, e.g. 8000", "Başka bir port, ör. 8000")))
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { if let port = Int(custom) { open(port) } }
                        Button(L("Open", "Aç")) { if let port = Int(custom) { open(port) } }
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
                Text(forward.map { L("open at localhost:\($0.local)", "localhost:\($0.local) üzerinden açık") } ?? process ?? "dinliyor")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let forward {
                Button(L("Open", "Aç")) { NSWorkspace.shared.open(forward.url) }
                Button {
                    model.forwarder.stop(port)
                } label: {
                    Image(systemName: "stop.circle")
                }
                .buttonStyle(.borderless)
                .help(L("Stop forwarding", "Yönlendirmeyi durdur"))
                .accessibilityLabel(L("Stop forwarding port \(port)", "Port \(port) yönlendirmesini durdur"))
            } else {
                Button(L("Open in browser", "Tarayıcıda aç")) { open(port) }
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
                self.error = L("Couldn't open port \(port): \(error.localizedDescription)", "Port \(port) açılamadı: \(error.localizedDescription)")
            }
        }
    }
}

/// Above the diff: what the reviewing agent found, and one click to hand it to the agent that did the work.
private struct ReviewCard: View {
    let review: SessionInfo
    let authorID: String
    @Environment(AppModel.self) private var model
    @State private var sent = false

    var body: some View {
        let store = model.store
        let reviewer = store.agentName(review.agent)
        let author = store.session(authorID).map { store.agentName($0.agent) } ?? L("the agent", "ajan")
        let reviewing = [.starting, .running, .waiting].contains(review.status)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                StatusDot(color: review.status.tint, size: 7)
                Text(L("Review by \(reviewer)", "\(reviewer) incelemesi")).font(.callout.weight(.semibold))
                Spacer()
                Button(L("Open", "Aç")) { model.selectedSessionID = review.id }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            if !reviewing, let findings = store.findings(of: review.id) {
                ScrollView {
                    // Reviewers answer in Markdown; bold and code read better rendered than as asterisks.
                    Text((try? AttributedString(markdown: findings, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(findings))
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                HStack {
                    Spacer()
                    Button(sent ? L("Sent", "Gönderildi") : L("Send to \(author)", "\(author) ajanına gönder")) {
                        Task {
                            await store.prompt(authorID, text: "[Review by \(reviewer)]\n\n\(findings)")
                            sent = true
                        }
                    }
                    .disabled(sent || [.starting, .running, .waiting].contains(store.session(authorID)?.status))
                    .help(L("Sends the findings to the agent that made these changes, as one message", "Bulguları bu değişiklikleri yapan ajana tek mesaj olarak gönderir"))
                }
            } else if review.status == .error {
                Text(review.error ?? L("The review stopped with an error.", "İnceleme hatayla durdu.")).font(.caption).foregroundStyle(Color.kervanCoral)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(review.status == .waiting ? L("The reviewer is waiting for your approval.", "İnceleyen ajan onayınızı bekliyor.") : L("Reviewing…", "İnceleniyor…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .softSurface(radius: Radius.card)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .onChange(of: review.id) { sent = false }
    }
}
