import KervanKit
import SwiftUI

struct ChatView: View {
    let sessionID: String
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft = ""

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
                            TranscriptRow(item: item).id(item.id)
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

            Composer(draft: $draft, status: status, canSend: model.connection.state.isConnected, send: send, stop: stop)
        }
        .navigationTitle(session?.title ?? "Oturum")
        .navigationSubtitle("\(agentName), \(status.label.lowercased())")
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
        guard !text.isEmpty, model.store.session(sessionID)?.status == .idle else { return }
        draft = ""
        model.store.lastError = nil
        Task { await model.store.prompt(sessionID, text: text) }
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

    var body: some View {
        switch item {
        case .user(_, let text):
            Text(text)
                .textSelection(.enabled)
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

        case .permissionRejected(_, let title):
            Label {
                Text("İzin istendi: \(title). Onay ekranı henüz olmadığı için reddedildi.")
            } icon: {
                Image(systemName: "hand.raised")
            }
            .font(.callout)
            .foregroundStyle(Color.kervanSaffron)

        case .stopped(_, let reason):
            Label(Self.stopText(reason), systemImage: "stop.circle")
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

    private static func symbol(_ kind: String) -> String {
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

private struct Composer: View {
    @Binding var draft: String
    let status: SessionStatus
    let canSend: Bool
    let send: () -> Void
    let stop: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Bir görev ya da soru yazın", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($focused)
                    .onSubmit(send)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .background(.background, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(focused ? Color.kervanLapis.opacity(0.6) : Color(nsColor: .separatorColor)))

                if status == .running {
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
