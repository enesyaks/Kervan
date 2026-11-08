import AppKit
import KervanKit
import SwiftUI

// MARK: App updates

/// Settings › General: this version, automatic checks, and installing a newer one.
struct UpdatesCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var updater = model.updater
        SettingsCard(title: L("Updates", "Güncellemeler")) {
            LabeledContent(L("Version", "Sürüm")) {
                Text(verbatim: "Kervan \(KervanVersion.current)").monospacedDigit()
            }
            Toggle(L("Check for updates automatically", "Güncellemeleri kendiliğinden denetle"), isOn: $updater.checksAutomatically)
            HStack(spacing: 10) {
                switch updater.state {
                case .idle, .upToDate, .failed:
                    Button(L("Check now", "Şimdi denetle")) { Task { await updater.check() } }
                case .checking:
                    ProgressView().controlSize(.small)
                    Text(L("Checking…", "Denetleniyor…")).foregroundStyle(.secondary)
                case .available(let release):
                    Button(L("Install Kervan \(release.version) and relaunch", "Kervan \(release.version) sürümünü kur ve yeniden aç")) {
                        updater.install(release)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.kervanLapis)
                    Link(L("What's new", "Yenilikler"), destination: release.page)
                case .downloading, .installing:
                    ProgressView().controlSize(.small)
                    Text(L("Downloading and checking the update…", "Güncelleme indiriliyor ve doğrulanıyor…")).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if case .upToDate = updater.state {
                Label(L("You have the latest version.", "En son sürümü kullanıyorsunuz."), systemImage: "checkmark.circle")
                    .foregroundStyle(Color.kervanOasis)
                    .font(.callout)
            }
            if case .failed(let message) = updater.state {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.kervanCoral)
                    .font(.callout)
            }
        }
    }
}

/// Above the connection status in the sidebar: a newer app, or a server older than this app.
struct SidebarNotices: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 6) {
            if let release = model.updater.available {
                notice(
                    L("Kervan \(release.version) is available", "Kervan \(release.version) çıktı"),
                    symbol: "arrow.down.circle",
                    tint: .kervanLapis
                ) {
                    UserDefaults.standard.set(SettingsTab.general, forKey: SettingsTab.key)
                    openSettings()
                }
            }
            if let version = model.outdatedServer {
                notice(
                    L("The server (\(version)) needs an update", "Sunucunun (\(version)) güncellenmesi gerekiyor"),
                    symbol: "server.rack",
                    tint: .kervanSaffron
                ) { model.showServerUpdate = true }
            }
            if let version = model.outdatedMacNode {
                notice(
                    L("This Mac's node (\(version)) needs an update", "Bu Mac'in node'u (\(version)) güncellenmeli"),
                    symbol: "laptopcomputer",
                    tint: .kervanSaffron
                ) {
                    UserDefaults.standard.set(SettingsTab.nodes, forKey: SettingsTab.key)
                    openSettings()
                }
            }
        }
        .padding(.horizontal, 10)
    }

    private func notice(_ text: String, symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(text, systemImage: symbol)
                .font(.callout.weight(.medium))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Server update

/// Brings the connected hub to the version this app carries, over SSH, keeping its token, settings and firewall.
struct ServerUpdateSheet: View {
    /// `.update` replaces the code; `.tailscale` also installs Tailscale on the server and signs it in, and closes the
    /// home network.
    var access: HubSetup.Access = .update

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("serverUpdateUser") private var user = "ubuntu"
    @State private var host = ""

    private var tailscale: Bool { access == .tailscale }
    private var steps: [HubSetupStep] {
        tailscale ? [.uploading, .packages, .files, .firewall, .service, .tailscaleLogin, .ready] : [.uploading, .packages, .files, .service, .ready]
    }

    var body: some View {
        let installer = model.serverUpdater
        let started = installer.started
        let failed = installer.failure != nil
        let done = installer.step == .ready && !installer.isRunning && !failed

        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(tailscale ? L("Set up Tailscale on the server", "Sunucuya Tailscale kur") : L("Update the server", "Sunucuyu güncelle")).font(.title2.weight(.semibold))
                Text(tailscale
                    ? L(
                        "Installs Tailscale on the server over SSH and signs it in with your account. Kervan then answers only over Tailscale, encrypted and from anywhere, and no longer on the home network, so this Mac needs Tailscale on too. Kervan restarts with the code this app carries; sessions and keys stay, running turns are cut off.",
                        "Tailscale'i sunucuya SSH ile kurar ve hesabınızla giriş yapar. Kervan bundan sonra yalnızca Tailscale üzerinden, şifreli ve her yerden yanıt verir, ev ağından vermez; bu yüzden bu Mac'te de Tailscale açık olmalı. Kervan bu uygulamanın taşıdığı kodla yeniden başlar; oturumlar ve anahtarlar kalır, süren turlar kesilir."
                    )
                    : L(
                        "The server runs \(model.outdatedServer ?? "an older version"); this app carries \(KervanVersion.current). The update replaces Kervan's code over SSH and restarts it. Settings, sessions and keys stay; running turns are cut off. If Tailscale is on the server, Kervan answers only over Tailscale from now on, and the app moves there by itself; this Mac needs Tailscale on too.",
                        "Sunucu \(model.outdatedServer ?? "eski bir sürüm") çalıştırıyor; bu uygulama \(KervanVersion.current) taşıyor. Güncelleme Kervan'ın kodunu SSH ile değiştirip yeniden başlatır. Ayarlar, oturumlar ve anahtarlar kalır; süren turlar kesilir. Sunucuda Tailscale varsa Kervan bundan sonra yalnızca Tailscale üzerinden yanıt verir ve uygulama oraya kendisi geçer; bu Mac'te de Tailscale açık olmalı."
                    ))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if !started {
                Form {
                    TextField(L("Server", "Sunucu"), text: $host)
                    TextField(L("SSH user", "SSH kullanıcısı"), text: $user)
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .frame(height: 124)
            } else {
                StepList(
                    steps: steps.map(installer.line),
                    reached: steps.firstIndex(of: installer.step) ?? steps.count - 1,
                    running: installer.isRunning || installer.waitingForTerminal,
                    failed: failed,
                    startedAt: installer.startedAt
                )
                if let url = installer.tailscaleURL {
                    Button(L("Sign in to Tailscale", "Tailscale'e giriş yap")) { NSWorkspace.shared.open(url) }
                        .buttonStyle(.borderedProminent)
                        .tint(.kervanLapis)
                }
                if let address = installer.waitingOnTailscale {
                    TailscaleHint(address: address)
                }
                if installer.waitingForTerminal {
                    Guidance(
                        text: tailscale
                            ? L(
                                "sudo needs a password on the server. Run this in Terminal; it asks for your password there and then prints Tailscale's sign-in link. This window carries on when it's done.",
                                "Sunucuda sudo parola istiyor. Terminal'de şunu çalıştırın; parolanız orada sorulur, ardından Tailscale'in giriş bağlantısı çıkar. Bitince bu pencere kendiliğinden devam eder."
                            )
                            : L(
                                "sudo needs a password on the server. Run this in Terminal; it asks for your password there, and this window carries on when it's done.",
                                "Sunucuda sudo parola istiyor. Terminal'de şunu çalıştırın; parolanız orada sorulur, bitince bu pencere kendiliğinden devam eder."
                            ),
                        command: HubSetup.terminalCommand(user: user, host: host, access: access),
                        runsHere: true,
                        // The script takes the token with it when it exits, so a second run needs the files again.
                        prepare: { await installer.resend() }
                    )
                }
                if let failure = installer.failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.kervanCoral)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if done {
                    Label(tailscale
                        ? L("Tailscale is set up. Its address shows up under Web access in a moment.", "Tailscale kuruldu. Adresi birazdan Web erişimi'nde görünür.")
                        : L("The server is updated and reconnecting.", "Sunucu güncellendi, yeniden bağlanılıyor."), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color.kervanOasis)
                }
            }

            HStack {
                Spacer()
                if installer.isRunning || installer.waitingForTerminal {
                    Button(L("Stop", "Durdur")) { installer.reset() }
                } else {
                    Button(done ? L("Done", "Bitti") : L("Cancel", "Vazgeç")) {
                        installer.reset()
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    if !done {
                        Button(failed ? L("Try again", "Yeniden dene") : (tailscale ? L("Set up", "Kur") : L("Update", "Güncelle"))) { start() }
                            .buttonStyle(.borderedProminent)
                            .tint(.kervanLapis)
                            .keyboardShortcut(.defaultAction)
                            .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || user.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(Color.kervanCanvas)
        .onAppear { if host.isEmpty { host = model.activeAddress?.host ?? "" } }
    }

    private func start() {
        guard let token = model.activeToken else { return }
        let host = host.trimmingCharacters(in: .whitespaces)
        let user = user.trimmingCharacters(in: .whitespaces)
        // The restart drops the connection, which comes back on its own, unless the server has moved to Tailscale.
        model.serverUpdater.run(user: user, host: host, access: access, token: token) { [model] token, reached in
            guard reached != host else { return }
            model.serverInput = reached
            model.tokenInput = token
            model.connect()
        }
    }
}

// MARK: Report a problem

/// Collects versions, recent errors and the server's redacted log, lets the user read and edit it all,
/// then opens a filled-in GitHub issue (or copies it).
struct ReportProblemSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var report: BugReport?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Report a problem", "Sorun bildir")).font(.title2.weight(.semibold))
            Text(L(
                "This opens a GitHub issue with the details below filled in. API keys and tokens are removed, but read it first: you can edit anything before it's sent, and nothing is sent until you submit it on GitHub.",
                "Bu, aşağıdaki bilgilerle doldurulmuş bir GitHub issue'su açar. API anahtarları ve token'lar çıkarılır, yine de önce okuyun: göndermeden önce her şeyi düzenleyebilirsiniz ve GitHub'da gönderene kadar hiçbir şey gitmez."
            ))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if let binding = Binding($report) {
                Form {
                    TextField(L("Title", "Başlık"), text: binding.title, prompt: Text(L("e.g. The terminal panel stays empty", "ör. Terminal paneli boş kalıyor")))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("What happened?", "Ne oldu?"))
                        TextEditor(text: binding.what).frame(height: 70)
                    }
                    LabeledContent(L("Versions", "Sürümler")) {
                        Text(binding.wrappedValue.versions).font(.caption).textSelection(.enabled)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Details and logs", "Ayrıntılar ve loglar"))
                        TextEditor(text: binding.logs)
                            .font(.caption.monospaced())
                            .frame(height: 180)
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L("Collecting details…", "Ayrıntılar toplanıyor…")).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            }

            HStack {
                Button(copied ? L("Copied", "Kopyalandı") : L("Copy", "Kopyala")) {
                    guard let report else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report.text, forType: .string)
                    copied = true
                }
                .disabled(report == nil)
                Spacer()
                Button(L("Cancel", "Vazgeç")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Open GitHub issue", "GitHub issue'su aç")) {
                    guard let report else { return }
                    NSWorkspace.shared.open(report.issueURL)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(.kervanLapis)
                .keyboardShortcut(.defaultAction)
                .disabled(report == nil || report?.title.trimmingCharacters(in: .whitespaces).isEmpty == true)
            }
        }
        .padding(24)
        .frame(width: 600)
        .background(Color.kervanCanvas)
        .task { await collect() }
    }

    private func collect() async {
        let server = model.connection.state.isConnected ? await model.store.diagnostics() : nil
        let os = ProcessInfo.processInfo.operatingSystemVersion
        report = BugReport.make(
            app: KervanVersion.current,
            macOS: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            language: Language.shared.isTurkish ? "Turkish UI" : "English UI",
            connection: model.connection.state.shortLabel,
            server: server,
            errors: recentErrors(),
            serverVersion: model.connection.state.server?.version
        )
    }

    /// The last errors the agents reported and the last request the server refused, newest last.
    private func recentErrors() -> [String] {
        var lines: [(at: String, text: String)] = []
        for (sessionID, events) in model.store.events {
            let agent = model.store.session(sessionID).map { model.store.agentName($0.agent) } ?? "?"
            for event in events.suffix(200) {
                if case .error(let message) = event.body { lines.append((event.at, "[\(event.at)] \(agent): \(message)")) }
            }
        }
        var result = lines.sorted { $0.at < $1.at }.suffix(10).map(\.text)
        if let lastError = model.store.lastError { result.append("Last refused request: \(lastError)") }
        return result.map { String($0.prefix(400)) }
    }
}
