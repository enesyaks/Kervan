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

    var body: some View {
        let session = model.store.session(sessionID)
        let status = session?.status ?? .unknown
        let agentName = (session?.agent ?? "").agentDisplayName
        let items = model.store.transcript(for: sessionID)

        VStack(spacing: 0) {
            if !model.connection.state.isConnected {
                Banner(text: "Sunucuyla bağlantı koptu. Yeniden bağlanılıyor…", systemImage: "wifi.exclamationmark", tint: .kervanSaffron)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if items.isEmpty {
                            EmptySession(status: status, agentName: agentName)
                        }
                        ForEach(items) { item in
                            TranscriptRow(item: item, agentName: agentName) { requestId, choice in
                                Task { await model.store.respond(sessionID, requestId: requestId, optionId: choice.optionId) }
                            }
                            .id(item.id)
                        }
                        if status == .running {
                            HStack(spacing: 8) {
                                CaravanDots()
                                Text("\(agentName) yanıtlıyor…").foregroundStyle(.secondary)
                            }
                        }
                        if status == .error {
                            Banner(text: "Bu oturum sona erdi. Devam etmek için yeni bir oturum başlatın.", systemImage: "xmark.octagon", tint: .red)
                        }
                        Color.clear.frame(height: 1).id(Self.bottom)
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear { proxy.scrollTo(Self.bottom, anchor: .bottom) }
                .onChange(of: Self.scrollKey(items, status)) {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                        proxy.scrollTo(Self.bottom, anchor: .bottom)
                    }
                }
            }

            if let error = model.store.lastError {
                Banner(text: error, systemImage: "exclamationmark.triangle", tint: .red) {
                    model.store.lastError = nil
                }
            }

            Composer(
                draft: $draft,
                attachments: attachments,
                status: status,
                canSend: model.connection.state.isConnected && attachments.allSatisfy(\.isReady),
                send: send,
                stop: stop,
                attach: chooseFiles,
                remove: { id in attachments.removeAll { $0.id == id } }
            )
        }
        .overlay { if dropTargeted { DropHint() } }
        .dropDestination(for: URL.self) { urls, _ in
            attach(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .navigationTitle(session?.title ?? "Oturum")
        .navigationSubtitle("\(agentName), \(status.label.lowercased())")
        .inspector(isPresented: Bindable(model).showFiles) {
            FilesPanel(sessionID: sessionID)
                .inspectorColumnWidth(min: 240, ideal: 300)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    model.showFiles.toggle()
                } label: {
                    Label("Dosyalar", systemImage: "folder")
                }
                .help("Oturumun çalışma klasörünü göster")
            }
        }
    }

    private static let bottom = "bottom"

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
        let paths = attachments.map(\.remotePath)
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
                Text("\(agentName) başlatılıyor…").foregroundStyle(.secondary)
            }
        case .idle:
            Text("Oturum hazır. \(agentName)'dan ne yapmasını istediğinizi yazın.")
                .foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }
}

private struct TranscriptRow: View {
    let item: TranscriptItem
    let agentName: String
    let respond: (String, PermissionChoice) -> Void

    var body: some View {
        switch item {
        case .user(_, let text, let attached):
            VStack(alignment: .leading, spacing: 8) {
                Text(text).textSelection(.enabled)
                if !attached.isEmpty {
                    FlowChips(names: attached.map { $0.split(separator: "/").last.map(String.init) ?? $0 })
                }
            }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.kervanLapis.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .leading) {
                    UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8)
                        .fill(Color.kervanLapis)
                        .frame(width: 3)
                }
                .accessibilityLabel("Siz: \(text)")

        case .agent(_, let text):
            Text(Self.markdown(text))
                .textSelection(.enabled)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

        case .thought(_, let text):
            DisclosureGroup("Düşünme") {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .foregroundStyle(.secondary)

        case .tool(_, _, let title, let kind, let status):
            ToolRow(title: title, kind: kind, status: status)

        case .permission(_, let prompt):
            PermissionCard(prompt: prompt, agentName: agentName) { respond(prompt.requestId, $0) }

        case .stopped(_, let reason):
            Label(Self.stopText(reason), systemImage: "stop.circle")
                .font(.callout)
                .foregroundStyle(.secondary)

        case .notice(_, let text):
            Label(text, systemImage: "arrow.triangle.2.circlepath")
                .font(.callout)
                .foregroundStyle(.secondary)

        case .error(_, let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
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
        case "interrupted": "Sunucu yeniden başladığı için yarıda kaldı. Devam etmek için yeni bir mesaj yazın."
        default: "Tur bitti: \(reason)"
        }
    }
}

private struct ToolRow: View {
    let title: String
    let kind: String
    let status: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: Self.symbol(kind))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(title)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            Text(Self.statusLabel(status))
                .font(.caption)
                .foregroundStyle(Self.statusTint(status))
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator))
        .accessibilityElement(children: .combine)
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
        case "failed": .red
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
            Label("\(agentName) izin istiyor", systemImage: "hand.raised.fill")
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
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            }

            HStack(spacing: 8) {
                ForEach(Self.ordered(prompt.options)) { option in
                    if option.kind == "allow_once" {
                        Button(Self.label(option)) { choose(option) }.buttonStyle(.borderedProminent)
                    } else {
                        Button(Self.label(option)) { choose(option) }
                    }
                }
            }
            .controlSize(.large)
        }
        .padding(14)
        .background(Color.kervanSaffron.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.kervanSaffron.opacity(0.5)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(agentName) izin istiyor: \(prompt.title)")
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
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
                }
                .buttonStyle(.borderless)
                .controlSize(.large)
                .help("Dosya ekle; sohbete sürükleyip bırakabilirsiniz de")
                .accessibilityLabel("Dosya ekle")
                .padding(.bottom, 8)

                TextField("Bir görev ya da soru yazın", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($focused)
                    .onSubmit(send)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .background(.background, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(focused ? Color.kervanLapis.opacity(0.6) : Color(nsColor: .separatorColor)))

                if status == .running || status == .waiting {
                    Button("Durdur", action: stop)
                        .keyboardShortcut(".", modifiers: .command)
                        .controlSize(.large)
                } else {
                    Button("Gönder", action: send)
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!canSend || status != .idle || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Text("↩ gönderir, ⌥↩ yeni satır açar.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 12)
        .background(.bar)
        .onAppear { focused = true }
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
        .padding(.horizontal, 32)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08))
    }
}
