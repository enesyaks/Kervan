import AppKit
import KervanKit
import SwiftUI

struct ChatView: View {
    let sessionID: String
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft = ""
    @State private var attachments: [Attachment] = []
    @State private var dropTargeted = false
    @State private var highlighted: Int?
    @State private var rewinding: Rewind?
    @State private var fileNames: [String] = []

    var body: some View {
        let session = model.store.session(sessionID)
        let status = session?.status ?? .unknown
        let agentName = model.store.agentName(session?.agent ?? "")
        let items = model.store.transcript(for: sessionID)
        let checkpoints = model.store.checkpoints(for: sessionID)
        let free = status == .idle && model.connection.state.isConnected

        VStack(spacing: 0) {
            if !model.connection.state.isConnected {
                Banner(text: "Bağlantı bir anlığına koptu; arka planda yeniden bağlanıyoruz. İşleriniz sunucuda sürüyor.", systemImage: "wifi.exclamationmark", tint: .kervanSaffron)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if let leadID = session?.parentId {
                            LeadLink(leadTitle: model.store.session(leadID)?.title ?? "Ana ajan", branch: session?.branch) {
                                model.selectedSessionID = leadID
                            }
                        }
                        if items.isEmpty {
                            EmptySession(status: status, agentName: agentName)
                        }
                        let resumable = Transcript.resumable(items)
                        ForEach(items) { item in
                            row(item, resumable: resumable == item.id && status == .idle, canAct: free, canRewind: checkpoints.contains(item.id), agentName: agentName)
                        }
                        if status == .running {
                            HStack(spacing: 8) {
                                CaravanDots()
                                Text("\(agentName) üzerinde çalışıyor…").foregroundStyle(.secondary)
                            }
                        }
                        if status == .error {
                            Banner(text: "Bu oturumun ajanı durdu. Yeni bir oturum açarak kaldığınız yerden devam edebilirsiniz.", systemImage: "pause.circle", tint: .kervanCoral)
                        }
                        Color.clear.frame(height: 1).id(Self.bottom)
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 28)
                    .frame(maxWidth: .infinity)
                    .animation(Motion.pick(Motion.smooth, reduce: reduceMotion), value: items.count)
                }
                .background(Color.kervanCanvas)
                .onAppear { proxy.scrollTo(Self.bottom, anchor: .bottom) }
                .task(id: model.focus?.seq) {
                    guard let focus = model.focus, focus.sessionID == sessionID else { return }
                    // The row for a seq is the message that contains it: the last row starting at or before it.
                    guard let target = items.last(where: { $0.id <= focus.seq })?.id else { return }
                    try? await Task.sleep(for: .milliseconds(100)) // let the history lay out first
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                        proxy.scrollTo(target, anchor: .center)
                        highlighted = target
                    }
                    // Clearing focus changes this task's id and cancels it, so the fade-out runs on its own.
                    model.focus = nil
                    Task {
                        try? await Task.sleep(for: .seconds(2.5))
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.4)) {
                            if highlighted == target { highlighted = nil }
                        }
                    }
                }
                .onChange(of: Self.scrollKey(items, status)) {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                        proxy.scrollTo(Self.bottom, anchor: .bottom)
                    }
                }
            }

            if let error = model.store.lastError {
                Banner(text: error, systemImage: "exclamationmark.triangle", tint: .kervanCoral) {
                    model.store.lastError = nil
                }
            }

            if let plan = model.store.plan(for: sessionID) {
                PlanCard(entries: plan)
                    .frame(maxWidth: 760)
                    .padding(.horizontal, 28)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity)
                    .background(Color.kervanCanvas)
            }

            Composer(
                draft: $draft,
                attachments: attachments,
                status: status,
                canSend: model.connection.state.isConnected && attachments.allSatisfy(\.isReady),
                send: send,
                stop: stop,
                attach: chooseFiles,
                remove: { id in attachments.removeAll { $0.id == id } },
                options: session.map { ConfigOption.ordered($0.config) } ?? [],
                choose: { option, value in Task { await model.store.setConfig(sessionID, configId: option.id, value: value) } },
                suggestions: suggestions,
                pick: pick,
                paste: pasteImage,
                needFiles: { Task { await loadFileNames() } }
            )
        }
        .overlay { if dropTargeted { DropHint() } }
        .dropDestination(for: URL.self) { urls, _ in
            attach(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .navigationTitle(session?.title ?? "Oturum")
        .navigationSubtitle(
            ["\(agentName), \(status.label.lowercased())", session.flatMap(model.store.costSummary)]
                .compactMap { $0 }
                .joined(separator: ", ")
        )
        .inspector(isPresented: Bindable(model).showFiles) {
            SessionInspector(sessionID: sessionID)
                .inspectorColumnWidth(min: 280, ideal: 360, max: 640)
        }
        .toolbar { tools }
        .alert(
            "Dosyalar geri sarılsın mı?",
            isPresented: Binding(get: { rewinding != nil }, set: { if !$0 { rewinding = nil } }),
            presenting: rewinding
        ) { pending in
            Button(pending.thenEdit ? "Geri sar ve düzenle" : "Geri sar", role: .destructive) { rewind(pending) }
            Button("Vazgeç", role: .cancel) {}
        } message: { _ in
            Text("Klasördeki dosyalar bu mesajdan önceki hâline döner; ajanın sonradan oluşturduğu dosyalar silinir. Konuşma silinmez; ajana bir sonraki mesajınızda söylenir.")
        }
    }

    private func row(_ item: TranscriptItem, resumable: Bool, canAct: Bool, canRewind: Bool, agentName: String) -> some View {
        let lit = highlighted == item.id
        return TranscriptRow(
            item: item,
            agentName: agentName,
            senderName: senderName,
            terminal: model.store.isTerminal(sessionID),
            resume: resumable ? { Task { await model.store.resume(sessionID) } } : nil,
            act: canAct ? { action in act(action, on: item) } : nil,
            canRewind: canRewind
        ) { requestId, choice in
            Task { await model.store.respond(sessionID, requestId: requestId, optionId: choice.optionId) }
        }
        .padding(lit ? 6 : 0)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.kervanLapis.opacity(lit ? 0.14 : 0)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.kervanLapis.opacity(lit ? 0.7 : 0), lineWidth: 1.5))
        .id(item.id)
        .transition(.arrive(reduce: reduceMotion))
    }

    @ToolbarContentBuilder
    private var tools: some ToolbarContent {
            if Crew.of(sessionID, sessions: model.store.sessions, teams: model.store.teams) != nil {
                ToolbarItem {
                    Button {
                        model.showCrew = true
                    } label: {
                        Label("Takım görünümü", systemImage: "rectangle.split.3x1")
                    }
                    .help("Takımdaki bütün ajanları yan yana göster (⌥⌘T)")
                    .keyboardShortcut("t", modifiers: [.command, .option])
                }
            }
            ToolbarItem {
                Button {
                    model.showPanel(.changes)
                } label: {
                    Label("Değişiklikler", systemImage: "plusminus")
                }
                .help("Ajanın değiştirdiği dosyalar (⌥⌘D)")
                .keyboardShortcut("d", modifiers: [.command, .option])
            }
            ToolbarItem {
                Button {
                    model.showFiles.toggle()
                } label: {
                    Label("Panel", systemImage: "sidebar.right")
                }
                .help("Dosyalar, değişiklikler, terminal ve önizleme (⌥⌘0)")
                .keyboardShortcut("0", modifiers: [.command, .option])
            }
    }

    /// A message the user chose to rewind to, waiting for their yes.
    private struct Rewind: Equatable {
        let seq: Int
        let text: String
        let thenEdit: Bool
    }

    private func act(_ action: MessageAction, on item: TranscriptItem) {
        guard case .user(let seq, let text, _, _) = item else { return }
        switch action {
        case .resend:
            draft = text
            send()
        case .edit:
            rewinding = Rewind(seq: seq, text: text, thenEdit: true)
        case .rewind:
            rewinding = Rewind(seq: seq, text: text, thenEdit: false)
        }
    }

    private func rewind(_ pending: Rewind) {
        Task {
            if let failure = await model.store.revert(sessionID, toBefore: pending.seq) {
                model.store.lastError = failure
                return
            }
            if pending.thenEdit { draft = pending.text }
        }
    }

    // MARK: Suggestions

    /// Slash commands while the draft is "/…", workspace files after an "@".
    private var suggestions: [Suggestion] {
        if let commands = Transcript.suggestions(for: draft, in: model.store.commands(for: sessionID)) {
            return commands.prefix(30).map {
                Suggestion(id: "/" + $0.name, title: "/" + $0.name, detail: $0.description, symbol: "command", insert: "/\($0.name) ")
            }
        }
        if let word = Transcript.mention(in: draft) {
            let typed = word.lowercased()
            return fileNames
                .filter { typed.isEmpty || $0.lowercased().contains(typed) }
                .sorted { ($0.lowercased().hasPrefix(typed) ? 0 : 1, $0.count) < ($1.lowercased().hasPrefix(typed) ? 0 : 1, $1.count) }
                .prefix(30)
                .map { Suggestion(id: "@" + $0, title: $0, detail: "", symbol: "doc", insert: "@\($0) ", file: $0) }
        }
        return []
    }

    private func pick(_ suggestion: Suggestion) {
        if suggestion.file != nil, let at = draft.lastIndex(of: "@") {
            draft = String(draft[..<at]) + suggestion.insert
        } else {
            draft = suggestion.insert
        }
    }

    /// The workspace's files, for "@" suggestions; fetched when the first "@" is typed.
    private func loadFileNames() async {
        guard fileNames.isEmpty, let client = model.fileClient else { return }
        if let listing = try? await client.list(sessionID: sessionID) {
            fileNames = listing.entries.filter { $0.type == .file }.map(\.path)
        }
    }

    /// ⌘V with a picture on the pasteboard: it is uploaded and attached like a dropped file.
    private func pasteImage() -> Bool {
        guard let file = PastedImage.take() else { return false }
        attach([file])
        return true
    }

    private static let bottom = "bottom"

    /// Who wrote a message the user didn't: the lead agent's session title.
    private func senderName(_ sessionID: String) -> String {
        model.store.session(sessionID)?.title ?? "Ana ajan"
    }

    /// Changes whenever the transcript grows, including chunks appended to the last message.
    private static func scrollKey(_ items: [TranscriptItem], _ status: SessionStatus) -> String {
        let tail: Int = switch items.last {
        case .agent(_, let text)?, .thought(_, let text)?: text.count
        default: 0
        }
        return "\(items.count)-\(tail)-\(status.rawValue)"
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, model.store.session(sessionID)?.status == .idle, attachments.allSatisfy(\.isReady) else { return }
        // Files mentioned with "@" go along as attachments, so the agent gets them as files, not just names.
        let mentioned = fileNames.filter { text.contains("@\($0)") }
        let paths = Array(NSOrderedSet(array: attachments.map(\.remotePath) + mentioned)) as? [String] ?? attachments.map(\.remotePath)
        draft = ""
        attachments = []
        model.store.lastError = nil
        Task { await model.store.prompt(sessionID, text: text, attachments: paths) }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Ekle"
        if panel.runModal() == .OK { attach(panel.urls) }
    }

    /// Uploads each file to `uploads/` right away; the message can be sent once all are ready.
    private func attach(_ urls: [URL]) {
        guard let client = model.fileClient else { return }
        for url in urls where url.isFileURL {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                model.store.lastError = "Klasörler henüz eklenemiyor: \(url.lastPathComponent)"
                continue
            }
            let attachment = Attachment(name: url.lastPathComponent, taken: Set(attachments.map(\.remotePath)))
            attachments.append(attachment)
            Task {
                let state: Attachment.State
                do {
                    try await client.upload(sessionID: sessionID, file: url, to: attachment.remotePath)
                    state = .ready
                } catch {
                    state = .failed(error.localizedDescription)
                }
                if let index = attachments.firstIndex(where: { $0.id == attachment.id }) { attachments[index].state = state }
            }
        }
    }

    private func stop() {
        Task { await model.store.cancel(sessionID) }
    }
}

private struct EmptySession: View {
    let status: SessionStatus
    let agentName: String

    var body: some View {
        switch status {
        case .starting:
            HStack(spacing: 8) {
                CaravanDots()
                Text("\(agentName) hazırlanıyor…").foregroundStyle(.secondary)
            }
        case .idle:
            Text("\(agentName) hazır. Aklınızdakini yazın; birlikte başlayalım.")
                .foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }
}

/// Top of a helper's chat: who started it, and the way back.
private struct LeadLink: View {
    let leadTitle: String
    let branch: String?
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right").foregroundStyle(Color.kervanSaffron)
                Text("Bu yardımcıyı \(leadTitle) başlattı.").foregroundStyle(.secondary)
                Button("Ana ajana git", action: open).buttonStyle(.link)
            }
            if let branch {
                BranchLabel(branch: branch)
                    .help("Yardımcı kendi worktree'sinde bu dalda çalışıyor; ana ajan birleştirene kadar değişiklikleri orada kalır.")
            }
        }
        .font(.callout)
    }
}

struct BranchLabel: View {
    let branch: String

    var body: some View {
        Label(branch, systemImage: "arrow.triangle.branch")
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .accessibilityLabel("Dal: \(branch)")
    }
}

/// What can be done with one of your messages from the chat.
enum MessageAction {
    /// Put the folder back to before it, and the text in the composer to change and send again.
    case edit
    /// Put the folder back to before it.
    case rewind
    /// Send the same text again.
    case resend
}

struct TranscriptRow: View {
    let item: TranscriptItem
    let agentName: String
    let senderName: (String) -> String
    /// A terminal agent: its answers are shown as they were printed.
    var terminal = false
    /// Set on a turn a server restart cut off, while the agent is free: continues it.
    var resume: (() -> Void)?
    /// Set on your own messages while the agent is free; `canRewind` when the folder was saved before it.
    var act: ((MessageAction) -> Void)?
    var canRewind = false
    let respond: (String, PermissionChoice) -> Void
    @State private var hovering = false

    var body: some View {
        switch item {
        case .user(_, let text, let attached, let from) where from == nil && act != nil:
            userBubble(text: text, attached: attached, from: nil)
                .overlay(alignment: .bottomLeading) {
                    if hovering { actions(text) }
                }
                .onHover { hovering = $0 }
                .contextMenu { menu(text) }
        case .user(_, let text, let attached, let from):
            userBubble(text: text, attached: attached, from: from)
        default:
            content
        }
    }

    @ViewBuilder
    private func menu(_ text: String) -> some View {
        if canRewind {
            Button("Düzenle ve yeniden gönder") { act?(.edit) }
            Button("Dosyaları bu mesajdan önceye geri sar") { act?(.rewind) }
        }
        Button("Aynı mesajı yeniden gönder") { act?(.resend) }
        Divider()
        Button("Kopyala") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    /// Small buttons beside the bubble on hover; the same actions are in its context menu.
    private func actions(_ text: String) -> some View {
        HStack(spacing: 2) {
            if canRewind {
                iconButton("pencil", "Düzenle ve yeniden gönder: dosyalar bu mesajdan önceki hâline döner") { act?(.edit) }
                iconButton("arrow.uturn.backward", "Dosyaları bu mesajdan önceye geri sar") { act?(.rewind) }
            }
            iconButton("arrow.clockwise", "Aynı mesajı yeniden gönder") { act?(.resend) }
            iconButton("doc.on.doc", "Kopyala") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
        .padding(3)
        .softSurface(radius: Radius.chip)
        .transition(.opacity)
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(SoftPressStyle())
        .help(help)
        .accessibilityLabel(help)
    }

    private func userBubble(text: String, attached: [String], from: String?) -> some View {
        // Your words sit on the right in a soft bubble; a lead's instructions to a helper get its gold.
        let accent = from == nil ? Color.kervanLapis : Color.kervanSaffron
        return HStack {
            Spacer(minLength: 64)
            VStack(alignment: .trailing, spacing: 8) {
                if let from {
                    Label(senderName(from), systemImage: "flag.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.kervanSaffron)
                }
                Text(text)
                    .font(.system(size: 14, design: .rounded))
                    .textSelection(.enabled)
                    .lineSpacing(3)
                if !attached.isEmpty {
                    FlowChips(names: attached.map { $0.split(separator: "/").last.map(String.init) ?? $0 })
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .background(accent.opacity(0.16), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(from.map { "Ana ajan \(senderName($0)): \(text)" } ?? "Siz: \(text)")
        .accessibilityActions {
            if act != nil && from == nil {
                if canRewind {
                    Button("Düzenle ve yeniden gönder") { act?(.edit) }
                    Button("Dosyaları bu mesajdan önceye geri sar") { act?(.rewind) }
                }
                Button("Aynı mesajı yeniden gönder") { act?(.resend) }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch item {
        case .user:
            EmptyView() // drawn by `body`

        case .agent(_, let text) where terminal:
            Text(text.trimmingCharacters(in: .newlines))
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.kervanWell, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))

        case .agent(_, let text):
            Text(Self.markdown(text))
                .font(.system(size: 14, design: .rounded))
                .textSelection(.enabled)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)

        case .thought(_, let text):
            DisclosureGroup("Düşünme") {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .foregroundStyle(.secondary)

        case .tool(_, _, let title, let kind, let status, let diffs):
            ToolRow(title: title, kind: kind, status: status, diffs: diffs)

        case .permission(_, let prompt):
            PermissionCard(prompt: prompt, agentName: agentName) { respond(prompt.requestId, $0) }

        case .stopped(_, let reason):
            HStack(spacing: 10) {
                Label(Self.stopText(reason), systemImage: "stop.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let resume {
                    Button("Devam et", action: resume)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Ajana kaldığı yerden sürdürmesini söyler")
                }
            }

        case .notice(_, let text):
            Label(text, systemImage: "arrow.triangle.2.circlepath")
                .font(.callout)
                .foregroundStyle(.secondary)

        case .error(_, let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.kervanCoral)
        }
    }

    private static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    private static func stopText(_ reason: String) -> String {
        switch reason {
        case "cancelled": "Durduruldu."
        case "max_tokens": "Yanıt uzunluk sınırına ulaştı."
        case "max_turn_requests": "Adım sınırına ulaşıldı."
        case "refusal": "Ajan bu isteği yanıtlamadı."
        case "interrupted": "Sunucu yeniden başladığı için yarıda kaldı."
        default: "Tur bitti: \(reason)"
        }
    }
}

/// One tool call; an edit with a reported diff opens to show the changed lines.
private struct ToolRow: View {
    let title: String
    let kind: String
    let status: String
    var diffs: [FileDiff] = []
    @State private var open = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let lines = diffs.map { (path: $0.path, lines: $0.lines, truncated: $0.truncated) }
        let added = lines.reduce(0) { $0 + $1.lines.filter { $0.kind == .added }.count }
        let removed = lines.reduce(0) { $0 + $1.lines.filter { $0.kind == .removed }.count }
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(Motion.pick(Motion.fast, reduce: reduceMotion)) { open.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: Self.symbol(kind))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(title)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 12)
                    if !diffs.isEmpty {
                        LineCounts(added: added, removed: removed)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(open ? 0 : -90))
                    }
                    Text(Self.statusLabel(status))
                        .font(.caption)
                        .foregroundStyle(Self.statusTint(status))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(diffs.isEmpty)
            .accessibilityElement(children: .combine)
            .accessibilityHint(diffs.isEmpty ? "" : open ? "Farkı gizler" : "Değişen satırları gösterir")

            if open {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, diff in
                    VStack(alignment: .leading, spacing: 4) {
                        if lines.count > 1 || diff.path != title {
                            Text(diff.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        if diff.lines.isEmpty {
                            Text("İçerik aynı kaldı.").font(.caption).foregroundStyle(.secondary)
                        } else {
                            DiffLinesView(lines: diff.lines)
                        }
                        if diff.truncated {
                            Text("Dosya uzun; farkın tamamı Değişiklikler panelinde.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color.kervanWell.opacity(0.7), in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
    }

    private static func symbol(_ kind: String) -> String { toolSymbol(kind) }

    private static func statusLabel(_ status: String) -> String {
        switch status {
        case "pending": "Bekliyor"
        case "in_progress": "Çalışıyor"
        case "completed": "Tamam"
        case "failed": "Başarısız"
        default: status
        }
    }

    private static func statusTint(_ status: String) -> Color {
        switch status {
        case "in_progress": .kervanSaffron
        case "completed": .kervanOasis
        case "failed": .kervanCoral
        default: .secondary
        }
    }
}

private func toolSymbol(_ kind: String) -> String {
    switch kind {
    case "read": "doc.text"
    case "edit": "pencil"
    case "delete": "trash"
    case "move": "arrow.right.doc.on.clipboard"
    case "search": "magnifyingglass"
    case "execute": "terminal"
    case "think": "brain"
    case "fetch": "globe"
    default: "wrench.and.screwdriver"
    }
}

/// An open request asks; an answered one shrinks to a single line recording the decision.
private struct PermissionCard: View {
    let prompt: PermissionPrompt
    let agentName: String
    let choose: (PermissionChoice) -> Void

    var body: some View {
        if let resolution = prompt.resolution {
            resolvedLine(resolution)
        } else {
            openCard
        }
    }

    private var openCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("\(agentName) onayınızı bekliyor", systemImage: "hand.raised.fill")
                .font(.headline)
                .foregroundStyle(Color.kervanSaffron)

            Label {
                Text(prompt.title).font(.callout.monospaced())
            } icon: {
                Image(systemName: toolSymbol(prompt.toolKind)).foregroundStyle(.secondary)
            }

            if let detail = prompt.detail, detail != prompt.title {
                Text(detail)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.kervanWell, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
            }

            HStack(spacing: 8) {
                ForEach(Self.ordered(prompt.options)) { option in
                    if option.kind == "allow_once" {
                        Button(Self.label(option)) { choose(option) }.buttonStyle(.borderedProminent).tint(.kervanLapis)
                    } else {
                        Button(Self.label(option)) { choose(option) }
                    }
                }
            }
            .controlSize(.large)
        }
        .padding(16)
        .background(Color.kervanSaffron.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.card + 2, style: .continuous))
        .softSurface(radius: Radius.card + 2)
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card + 2, style: .continuous)
                .strokeBorder(Color.kervanSaffron.opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(agentName) onayınızı bekliyor: \(prompt.title)")
    }

    private func resolvedLine(_ resolution: PermissionPrompt.Resolution) -> some View {
        let (text, symbol, tint): (String, String, Color) = switch resolution {
        case .chose(let option) where option.allows:
            (option.kind == "allow_always" ? "Her zaman izin verildi" : "İzin verildi", "checkmark.shield", .kervanOasis)
        case .chose:
            ("Reddedildi", "xmark.shield", .secondary)
        case .cancelled:
            ("İptal edildi", "xmark.shield", .secondary)
        }
        return Label {
            Text("\(text): ") + Text(prompt.title).font(.callout.monospaced())
        } icon: {
            Image(systemName: symbol)
        }
        .font(.callout)
        .foregroundStyle(tint)
    }

    /// Allow first, the one-off before the permanent one, then rejections.
    private static func ordered(_ options: [PermissionChoice]) -> [PermissionChoice] {
        let rank = ["allow_once": 0, "allow_always": 1, "reject_once": 2, "reject_always": 3]
        return options.sorted { (rank[$0.kind] ?? 4) < (rank[$1.kind] ?? 4) }
    }

    private static func label(_ option: PermissionChoice) -> String {
        switch option.kind {
        case "allow_once": "İzin ver"
        case "allow_always": "Her zaman izin ver"
        case "reject_once": "Reddet"
        case "reject_always": "Her zaman reddet"
        default: option.name
        }
    }
}

private struct Composer: View {
    @Binding var draft: String
    let attachments: [Attachment]
    let status: SessionStatus
    let canSend: Bool
    let send: () -> Void
    let stop: () -> Void
    let attach: () -> Void
    let remove: (Attachment.ID) -> Void
    /// The agent's settings (model, effort, mode), shown under the text field.
    let options: [ConfigOption]
    let choose: (ConfigOption, String) -> Void
    /// Slash commands or files matching what is being typed.
    let suggestions: [Suggestion]
    let pick: (Suggestion) -> Void
    /// ⌘V: takes a picture from the pasteboard if there is one; false lets the text field paste text.
    let paste: () -> Bool
    /// Asked for once an "@" is typed, to load the folder's file names.
    let needFiles: () -> Void
    @FocusState private var focused: Bool
    @State private var selected = 0
    /// Escape hides the suggestions until the draft changes again.
    @State private var dismissed = false
    @State private var pasteMonitor: Any?

    private var showing: Bool { !suggestions.isEmpty && !dismissed && focused }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showing {
                SuggestionList(suggestions: suggestions, selected: min(selected, suggestions.count - 1)) { choice($0) }
                    .transition(.opacity)
            }
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(attachments) { attachment in
                            AttachmentChip(attachment: attachment) { remove(attachment.id) }
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                Button(action: attach) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SoftPressStyle())
                .help("Dosya ekle; sohbete sürükleyip bırakabilirsiniz de")
                .accessibilityLabel("Dosya ekle")

                TextField("Ne yapmak istersiniz?", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, design: .rounded))
                    .lineLimit(1...8)
                    .focused($focused)
                    .onSubmit(submit)
                    .onKeyPress(.downArrow) { move(1) }
                    .onKeyPress(.upArrow) { move(-1) }
                    .onKeyPress(.tab) { showing ? (choice(suggestions[min(selected, suggestions.count - 1)]), KeyPress.Result.handled).1 : .ignored }
                    .onKeyPress(.escape) {
                        guard showing else { return .ignored }
                        dismissed = true
                        return .handled
                    }
                    .padding(.vertical, 7)
                    .onChange(of: draft) {
                        dismissed = false
                        selected = 0
                        if Transcript.mention(in: draft) != nil { needFiles() }
                    }

                Button(action: dictate) {
                    Image(systemName: "mic")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SoftPressStyle())
                .help("Sesle yazın (macOS dikte)")
                .accessibilityLabel("Dikte")

                let busy = status == .running || status == .waiting
                let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let ready = canSend && status == .idle && !empty
                Button(action: busy ? stop : send) {
                    Image(systemName: busy ? "stop.fill" : "arrow.up")
                        .font(.system(size: busy ? 11 : 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(busy ? Color.kervanSaffron : (ready ? Color.kervanLapis : Color.secondary.opacity(0.35))))
                        .contentShape(Circle())
                }
                .buttonStyle(SoftPressStyle())
                .keyboardShortcut(busy ? KeyboardShortcut(".", modifiers: .command) : KeyboardShortcut(.return, modifiers: .command))
                .disabled(!busy && !ready)
                .help(busy ? "Durdur (⌘.)" : "Gönder (↩)")
                .accessibilityLabel(busy ? "Durdur" : "Gönder")
            }
            .padding(.leading, 6)
            .padding(.trailing, 8)
            .padding(.vertical, 6)
            .softSurface(radius: Radius.composer)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.composer, style: .continuous)
                    .strokeBorder(Color.kervanLapis.opacity(focused ? 0.45 : 0), lineWidth: 1.5)
            )
            .animation(Motion.fast, value: focused)
            HStack(spacing: 14) {
                ForEach(options) { option in
                    SettingMenu(option: option) { choose(option, $0) }
                }
                Spacer()
                Text("/ komut, @ dosya. ↩ gönderir, ⌥↩ yeni satır.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
        }
        .frame(maxWidth: 760)
        .padding(.horizontal, 28)
        .padding(.top, 6)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
        .background(Color.kervanCanvas)
        .onAppear {
            focused = true
            // ⌘V with a screenshot on the pasteboard attaches it; text pastes as usual.
            pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard focused, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                      event.charactersIgnoringModifiers == "v", paste()
                else { return event }
                return nil
            }
        }
        .onDisappear {
            if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
            pasteMonitor = nil
        }
    }

    /// Return picks the highlighted suggestion while the list shows; otherwise it sends.
    private func submit() {
        if showing {
            choice(suggestions[min(selected, suggestions.count - 1)])
        } else {
            send()
        }
    }

    private func choice(_ suggestion: Suggestion) {
        pick(suggestion)
        focused = true
    }

    private func move(_ step: Int) -> KeyPress.Result {
        guard showing else { return .ignored }
        selected = (selected + step + suggestions.count) % suggestions.count
        return .handled
    }

    /// Starts macOS dictation in the text field (the same as pressing the dictation key).
    private func dictate() {
        focused = true
        DispatchQueue.main.async {
            NSApp.sendAction(Selector(("startDictation:")), to: nil, from: nil)
        }
    }
}

/// One agent setting under the composer: the current choice, and a menu of the others.
private struct SettingMenu: View {
    let option: ConfigOption
    let choose: (String) -> Void

    var body: some View {
        Menu {
            Picker(option.name, selection: Binding(get: { option.value }, set: choose)) {
                ForEach(option.choices) { choice in
                    if let description = choice.description, !description.isEmpty {
                        Text("\(choice.name) — \(description)").tag(choice.value)
                    } else {
                        Text(choice.name).tag(choice.value)
                    }
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(option.current?.name ?? option.value, systemImage: Self.symbol(option.category))
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(option.name)
        .accessibilityLabel("\(option.name): \(option.current?.name ?? option.value)")
    }

    private static func symbol(_ category: String?) -> String {
        switch category {
        case "model": "cpu"
        case "thought_level": "brain"
        case "mode": "slider.horizontal.3"
        default: "gearshape"
        }
    }
}

struct Banner: View {
    let text: String
    let systemImage: String
    let tint: Color
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let dismiss {
                Button("Kapat", action: dismiss).buttonStyle(.link)
            }
        }
        .font(.callout)
        .foregroundStyle(tint)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}
