import AppKit
import KervanKit
import SwiftUI

/// Signs a builtin agent in on the server with the user's own account (a Claude or ChatGPT subscription) instead of
/// an API key. The server runs the agent's login and this view opens its page on the Mac: for Codex it shows the code
/// to enter there, for Claude it takes back the code the page shows. The login stays on the server.
struct AgentAccountSignIn: View {
    let agentID: String
    /// The agent can already work (signed in, or given a key).
    let ready: Bool
    /// Settings: one line with a small button, rather than the onboarding card's large one.
    var compact = false

    @Environment(AppModel.self) private var model
    @State private var prompt: AgentLoginPrompt?
    @State private var code = ""
    @State private var working = false
    @State private var failure: String?
    @State private var copied = false

    static func offers(_ agentID: String) -> Bool { ["claude", "codex"].contains(agentID) }

    private var account: String { agentID == "claude" ? L("Claude account", "Claude hesabı") : "ChatGPT" }
    private var outcome: AgentLoginOutcome? { model.store.agentLoginOutcomes[agentID] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let prompt {
                if prompt.needsCode { pasteCode(prompt) } else { enterCode(prompt) }
            } else if !ready {
                start
            } else if compact {
                HStack(spacing: 8) {
                    Text(L("Can work now. Signed in with an account or a key on the server.", "Şu an çalışabilir. Sunucuda bir hesapla ya da anahtarla giriş yapılmış."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Sign in again…", "Yeniden giriş yap…")) { Task { await begin() } }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .disabled(working || !model.connection.state.isConnected)
                }
            }
            if let error = failure ?? outcome.flatMap({ if case .failed(let why) = $0 { why } else { nil } }) {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Color.kervanCoral)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .onChange(of: outcome) { _, outcome in
            // The server says how it ended; the waiting part goes away either way.
            if outcome != nil {
                prompt = nil
                code = ""
                working = false
            }
        }
        .onDisappear {
            if prompt != nil { Task { await model.store.cancelAgentLogin(agentID) } }
        }
    }

    @ViewBuilder
    private var start: some View {
        if compact {
            HStack(spacing: 8) {
                Text(L("Not signed in", "Giriş yapılmamış")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("Sign in with \(account)…", "\(account) ile giriş yap…")) { Task { await begin() } }
                    .font(.caption)
                    .disabled(working || !model.connection.state.isConnected)
            }
        } else {
            HStack(spacing: 10) {
                Button {
                    Task { await begin() }
                } label: {
                    HStack(spacing: 6) {
                        if working { ProgressView().controlSize(.small).tint(.white) }
                        Text(L("Sign in with \(account)", "\(account) ile giriş yap"))
                    }
                }
                .buttonStyle(AccountPillStyle())
                .disabled(working || !model.connection.state.isConnected)
                Text(agentID == "claude" ? L("Uses your Claude Pro or Max plan.", "Claude Pro ya da Max planınızı kullanır.") : L("Uses your ChatGPT plan.", "ChatGPT planınızı kullanır."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Claude: sign in on the page, then paste the code it shows.
    private func pasteCode(_ prompt: AgentLoginPrompt) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Sign in on the page that opened, then paste the code it shows here:", "Açılan sayfada giriş yapın, sonra gösterdiği kodu buraya yapıştırın:"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField(L("Code", "Kod"), text: $code, prompt: Text(L("Paste the code", "Kodu yapıştırın")))
                    .textFieldStyle(.plain)
                    .font(.body.monospaced())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.kervanWell, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
                    .onSubmit { Task { await finish() } }
                Button(L("Finish", "Bitir")) { Task { await finish() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
            }
            footer(prompt, waiting: working ? L("Signing in…", "Giriş yapılıyor…") : nil)
        }
        .padding(12)
        .background(Color.kervanLapis.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    /// Codex: enter the code on the page and approve; the server notices by itself.
    private func enterCode(_ prompt: AgentLoginPrompt) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Enter this code on the page that opened:", "Açılan sayfaya bu kodu girin:"))
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Text(prompt.code ?? "")
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .tracking(2)
                    .textSelection(.enabled)
                    .accessibilityLabel((prompt.code ?? "").map(String.init).joined(separator: " "))
                Button(copied ? L("Copied", "Kopyalandı") : L("Copy", "Kopyala")) { copy(prompt.code ?? "") }
                    .buttonStyle(.borderless)
            }
            footer(prompt, waiting: L("Waiting for you to approve it…", "Onaylamanız bekleniyor…"))
        }
        .padding(12)
        .background(Color.kervanLapis.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    private func footer(_ prompt: AgentLoginPrompt, waiting: String?) -> some View {
        HStack(spacing: 8) {
            if let waiting {
                ProgressView().controlSize(.small)
                Text(waiting).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(L("Open the page again", "Sayfayı yeniden aç")) { NSWorkspace.shared.open(prompt.url) }
                .buttonStyle(.borderless)
                .font(.caption)
            Button(L("Cancel", "Vazgeç")) {
                self.prompt = nil
                code = ""
                working = false
                Task { await model.store.cancelAgentLogin(agentID) }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }

    private func begin() async {
        working = true
        failure = nil
        switch await model.store.startAgentLogin(agentID) {
        case .success(let started):
            prompt = started
            if let code = started.code { copy(code) }
            NSWorkspace.shared.open(started.url)
        case .failure(let error):
            failure = error.message
        }
        working = false
    }

    private func finish() async {
        let typed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, !working else { return }
        working = true
        failure = nil
        if let error = await model.store.sendAgentLoginCode(agentID, code: typed) {
            failure = error
            working = false
        }
        // Otherwise the outcome arrives from the server and closes this.
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
    }
}

/// The account button: lapis, smaller than the step's main button, since it sits inside a card.
private struct AccountPillStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.callout, design: .rounded).weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.kervanLapis.opacity(isEnabled ? 1 : 0.45), in: Capsule())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(Motion.fast, value: configuration.isPressed)
            .contentShape(Capsule())
    }
}
