import AppKit
import Foundation
import KervanKit
import SwiftUI

/// Runs infra/mac-node-setup.sh through macOS's administrator prompt and follows what it writes to a log.
@MainActor
@Observable
final class MacNodeRunner {
    private(set) var output = ""
    private(set) var isRunning = false
    private(set) var startedAt: Date?
    private(set) var failure: String?
    private(set) var succeeded = false
    /// The prompt closed without a password; nothing was changed. What macOS said, for the details.
    private(set) var cancelled = false
    private(set) var cancelDetail = ""
    /// macOS is showing its prompt: the script hasn't written anything yet.
    var waitingForPassword: Bool { isRunning && output.isEmpty }

    private var task: Task<Void, Never>?

    static var script: String? { Bundle.main.url(forResource: "mac-node-setup", withExtension: "sh")?.path }

    func reset() {
        output = ""
        failure = nil
        succeeded = false
        cancelled = false
        cancelDetail = ""
        startedAt = nil
    }

    func run(command: (_ log: String) -> String) {
        reset()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kervan-node-\(UUID().uuidString)")
        let log = folder.appendingPathComponent("setup.log")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data().write(to: log)
        } catch {
            failure = error.localizedDescription
            return
        }
        let arguments = MacNode.adminArguments(for: command(log.path))
        // The prompt belongs to this app; from behind other windows it can be missed.
        NSApp.activate(ignoringOtherApps: true)
        startedAt = Date()
        isRunning = true
        task = Task { [weak self] in
            let follow = Task { [weak self] in
                while !Task.isCancelled {
                    self?.output = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            let result = await Self.osascript(arguments)
            follow.cancel()
            guard let self else { return }
            self.output = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            try? FileManager.default.removeItem(at: folder)
            self.isRunning = false
            if result.status == 0 {
                self.succeeded = true
            } else if MacNode.wasCancelled(result.error) {
                self.cancelled = true
                self.cancelDetail = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
                self.startedAt = nil
            } else {
                let lastLine = self.output.split(separator: "\n").last.map(String.init)
                self.failure = lastLine ?? L("Setup stopped without saying why.", "Kurulum nedenini söylemeden durdu.")
            }
        }
    }

    private static func osascript(_ arguments: [String]) async -> (status: Int32, error: String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = arguments
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { finished in
                let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                continuation.resume(returning: (finished.terminationStatus, text))
            }
            do { try process.run() } catch { continuation.resume(returning: (1, error.localizedDescription)) }
        }
    }
}

/// Settings › Nodes: whether this Mac is a node, and setting it up or removing it.
struct MacNodeCard: View {
    @Environment(AppModel.self) private var model
    @State private var settingUp = false
    @State private var confirmingRemoval = false
    @State private var installed = MacNode.isInstalled()
    @State private var remover = MacNodeRunner()
    @State private var awakeRunner = MacNodeRunner()
    @State private var keepAwake = FileManager.default.fileExists(atPath: MacNode.keepAwakeService)

    private var name: String? { MacNode.installedName() }

    /// Why setup can't start now, if so.
    private var blocked: String? {
        if !model.connection.state.isConnected { return L("Connect to your server first.", "Önce sunucunuza bağlanın.") }
        if model.outdatedServer != nil { return L("Update your server first, so the node gets the current code.", "Node güncel kodu alsın diye önce sunucunuzu güncelleyin.") }
        if MacNodeRunner.script == nil { return L("This copy of the app has no setup files.", "Bu uygulamada kurulum dosyaları yok.") }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("This Mac", "Bu Mac")).font(.headline)
            if installed {
                installedRow
            } else {
                Text(L(
                    "Start agents from your phone or another device and run them here, with this Mac's Ollama models.",
                    "Ajanları telefonunuzdan ya da başka bir cihazdan başlatın, burada bu Mac'in Ollama modelleriyle çalışsın."
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Button(L("Use this Mac as a node…", "Bu Mac'i node yap…")) { settingUp = true }
                    .disabled(blocked != nil)
                if let blocked {
                    Text(blocked).font(.caption).foregroundStyle(.secondary)
                }
            }
            // Here rather than in the installed row: removal can fail after the service, and with it that row, is gone.
            if let failure = remover.failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.kervanCoral)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 10)
        .sheet(isPresented: $settingUp, onDismiss: { installed = MacNode.isInstalled() }) {
            MacNodeSheet(update: installed ? name : nil).environment(model)
        }
        .confirmationDialog(L("Stop using this Mac as a node?", "Bu Mac node olarak kullanılmasın mı?"), isPresented: $confirmingRemoval) {
            Button(L("Remove node", "Node'u kaldır"), role: .destructive) { remove() }
        } message: {
            Text(L(
                "This deletes the node's user and folder, with the agents' sign-ins and whatever they saved there. Your own files aren't touched. macOS asks for your password.",
                "Node'un kullanıcısı ve klasörü, ajanların girişleri ve orada kaydettikleriyle birlikte silinir. Kendi dosyalarınıza dokunulmaz. macOS parolanızı sorar."
            ))
        }
        .onChange(of: remover.isRunning) { _, running in
            guard !running else { return }
            installed = MacNode.isInstalled()
        }
    }

    @ViewBuilder private var installedRow: some View {
        let nodeName = name
        let node = model.store.nodeInfos.first { $0.name == nodeName }
        HStack(spacing: 10) {
            StatusDot(color: node?.connected == true ? Color.kervanOasis : Color.secondary.opacity(0.5))
            VStack(alignment: .leading, spacing: 2) {
                Text(nodeName ?? L("Installed", "Kurulu")).font(.body.monospaced())
                Text(status(of: node)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let node, let version = node.version, version != KervanVersion.current {
                Button(L("Update…", "Güncelle…")) { settingUp = true }.disabled(blocked != nil)
            } else if node == nil {
                Button(L("Connect here…", "Buraya bağla…")) { settingUp = true }.disabled(blocked != nil)
            }
            Button(L("Remove…", "Kaldır…"), role: .destructive) { confirmingRemoval = true }
                .buttonStyle(.borderless)
                .disabled(remover.isRunning || MacNodeRunner.script == nil)
        }
        .padding(12)
        .softSurface(radius: Radius.chip)
        Toggle(isOn: Binding(get: { keepAwake }, set: { setKeepAwake($0) })) {
            Text(L("Keep this Mac awake while plugged in", "Prizdeyken bu Mac'i uyanık tut"))
            Text(L(
                "So its agents stay reachable. Only on power; a closed lid without an external display still sleeps, and nothing can wake the Mac from your phone. macOS asks for your password.",
                "Ajanlarına ulaşılabilsin diye. Yalnızca prizdeyken çalışır; harici ekran yoksa kapak kapanınca Mac yine uyur ve telefondan uyandırılamaz. macOS parolanızı sorar."
            ))
        }
        .toggleStyle(.checkbox)
        .disabled(awakeRunner.isRunning || MacNodeRunner.script == nil)
        if let failure = awakeRunner.failure {
            Label(failure, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.kervanCoral)
        }
        if remover.isRunning {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("Removing…", "Kaldırılıyor…")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func status(of node: NodeInfo?) -> String {
        guard let node else {
            return L("Installed, but this server doesn't know it. It may belong to another server.", "Kurulu, ama bu sunucu onu tanımıyor. Başka bir sunucuya ait olabilir.")
        }
        if node.connected, let version = node.version { return L("Connected, v\(version)", "Bağlı, v\(version)") }
        return node.connected ? L("Connected", "Bağlı") : L("Not connected. It connects again by itself when it can.", "Bağlı değil. Olabildiğinde kendiliğinden yeniden bağlanır.")
    }

    private func setKeepAwake(_ on: Bool) {
        guard let script = MacNodeRunner.script else { return }
        awakeRunner.run { MacNode.keepAwakeCommand(script: script, on: on, log: $0) }
        Task {
            while awakeRunner.isRunning { try? await Task.sleep(for: .milliseconds(200)) }
            // What's on disk, not what was asked: a closed prompt changes nothing.
            keepAwake = FileManager.default.fileExists(atPath: MacNode.keepAwakeService)
        }
    }

    private func remove() {
        guard let script = MacNodeRunner.script else { return }
        let nodeName = name
        remover.run { MacNode.removeCommand(script: script, log: $0) }
        Task {
            while remover.isRunning { try? await Task.sleep(for: .milliseconds(200)) }
            // The hub keeps the node's key until it's told; if the prompt was closed nothing has changed.
            if remover.succeeded, let nodeName, model.store.nodeInfos.contains(where: { $0.name == nodeName }) {
                await model.store.removeNode(nodeName)
            }
        }
    }
}

/// What making this Mac a node means, then the setup itself.
private struct MacNodeSheet: View {
    /// The node's name when reinstalling over an existing one.
    let update: String?

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsTab.key) private var settingsTab = SettingsTab.general
    @State private var name = ""
    @State private var runner = MacNodeRunner()
    @State private var waitingForInvite = false

    var body: some View {
        let connected = runner.succeeded && model.store.nodeInfos.contains { $0.name == name && $0.connected }
        VStack(alignment: .leading, spacing: 0) {
            Form {
                if runner.cancelled {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(L("The password prompt closed, so nothing changed on this Mac. You can try again.", "Parola penceresi kapandı, bu Mac'te hiçbir şey değişmedi. Yeniden deneyebilirsiniz."), systemImage: "info.circle")
                                .fixedSize(horizontal: false, vertical: true)
                            if !runner.cancelDetail.isEmpty {
                                Text(runner.cancelDetail).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                }
                Section {
                    TextField(L("Name", "Ad"), text: $name, prompt: Text("macbook"))
                        .font(.body.monospaced())
                        .disabled(update != nil || runner.isRunning || runner.succeeded)
                        .onChange(of: name) { name = name.lowercased() }
                } footer: {
                    Text(L("Shown next to the agent, e.g. \"Qwen Code (\(name.isEmpty ? "macbook" : name))\". Lowercase letters, digits and '-'.", "Ajanın yanında görünür, ör. \"Qwen Code (\(name.isEmpty ? "macbook" : name))\". Küçük harf, rakam ve '-'."))
                }

                if runner.startedAt == nil {
                    Section(L("How it works", "Nasıl çalışır")) {
                        Label(L("Agents run here as a separate hidden user. It can't read your home folder, SSH keys or documents.", "Ajanlar burada ayrı, gizli bir kullanıcıyla çalışır. Bu kullanıcı ana klasörünüzü, SSH anahtarlarınızı ve belgelerinizi okuyamaz."), systemImage: "person.crop.circle.badge.checkmark")
                        Label(L("It starts with the Mac and connects out to your server. No port opens on this Mac.", "Mac ile birlikte başlar ve sunucunuza dışarı doğru bağlanır. Bu Mac'te port açılmaz."), systemImage: "arrow.up.forward.circle")
                        Label(L("macOS asks for your password once. It never reaches the app.", "macOS parolanızı bir kez sorar. Parola uygulamaya hiç ulaşmaz."), systemImage: "lock")
                    }
                    .labelStyle(GuideLabelStyle())

                    Section {
                        Label(L("Agents here can still use anything on this Mac that has no password, such as Ollama, which can also delete models, or a local database. Only allow commands you trust, including from your phone.", "Buradaki ajanlar bu Mac'te parolası olmayan her şeyi kullanmaya devam edebilir: örneğin model de silebilen Ollama ya da yerel bir veritabanı. Telefondan da olsa yalnızca güvendiğiniz komutlara izin verin."), systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Color.kervanSaffron)
                            .fixedSize(horizontal: false, vertical: true)
                    } header: {
                        Text(L("What it can still reach", "Hâlâ neye ulaşabilir"))
                    }

                    Section(L("What changes for you", "Sizin için ne değişir")) {
                        Label(L("Agents installed in your home folder can't be used. Add them again for the node.", "Ana klasörünüze kurulu ajanlar kullanılamaz. Node için yeniden eklenir."), systemImage: "shippingbox")
                        Label(L("Claude, Codex and Gemini ask you to sign in again, for the node.", "Claude, Codex ve Gemini, node için yeniden giriş ister."), systemImage: "person.badge.key")
                        Label(L("Sessions work in the node's own folder, not your project folders.", "Oturumlar proje klasörlerinizde değil, node'un kendi klasöründe çalışır."), systemImage: "folder")
                        Label(L("When this Mac sleeps, its agents are unavailable. The Changes and Terminal panels don't work for them yet.", "Bu Mac uyuduğunda ajanları kullanılamaz. Değişiklikler ve Terminal panelleri bu ajanlarda henüz çalışmaz."), systemImage: "moon")
                    }
                    .labelStyle(GuideLabelStyle())
                } else {
                    Section(L("Setup", "Kurulum")) {
                        if runner.waitingForPassword {
                            Label(L("macOS is asking for your password. If you don't see its window, look behind other windows.", "macOS parolanızı soruyor. Penceresini görmüyorsanız diğer pencerelerin arkasına bakın."), systemImage: "lock")
                                .foregroundStyle(Color.kervanSaffron)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        let reached = runner.succeeded ? MacNode.Step.allCases.count - 1 : MacNode.Step.reached(in: runner.output).rawValue
                        StepList(
                            steps: MacNode.Step.allCases.map { (title: $0.title, detail: $0.detail) },
                            reached: reached,
                            running: !runner.waitingForPassword && (runner.isRunning || (runner.succeeded && !connected)),
                            failed: runner.failure != nil,
                            startedAt: runner.waitingForPassword ? nil : runner.startedAt
                        )
                        if let failure = runner.failure {
                            Label(failure, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.kervanCoral)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !runner.output.isEmpty {
                            DisclosureGroup(L("Detailed output", "Ayrıntılı çıktı")) {
                                ScrollView {
                                    Text(runner.output)
                                        .font(.caption.monospaced())
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(height: 100)
                                .defaultScrollAnchor(.bottom)
                            }
                        }
                    }
                    if connected {
                        Section(L("Next", "Sıradaki")) {
                            Text(L("In the Agents tab, add an agent by command and pick '\(name)' as its node. It then shows up on your phone too.", "Ajanlar sekmesinde komutla bir ajan ekleyip node olarak '\(name)' seçin. Sonra telefonunuzda da görünür."))
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                            Button(L("Go to the Agents tab", "Ajanlar sekmesine git")) {
                                settingsTab = SettingsTab.agents
                                dismiss()
                            }
                        }
                    }
                }

            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            HStack(spacing: 8) {
                if connected {
                    Label(L("'\(name)' is connected.", "'\(name)' bağlandı."), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color.kervanOasis)
                }
                Spacer()
                if runner.succeeded {
                    Button(connected ? L("Done", "Bitti") : L("Close", "Kapat")) { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.kervanPrimary)
                } else {
                    Button(L("Cancel", "Vazgeç"), role: .cancel) { dismiss() }
                        .buttonStyle(.kervanQuiet)
                        .keyboardShortcut(.cancelAction)
                        .disabled(runner.isRunning)
                    Button(runner.failure == nil ? L("Set up this Mac", "Bu Mac'i kur") : L("Try again", "Yeniden dene")) {
                        waitingForInvite = true
                        Task { await model.store.inviteNode(name) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.kervanPrimary)
                    .disabled(!MacNode.isValidName(name) || runner.isRunning || waitingForInvite || nameTaken)
                }
            }
            .padding(16)
        }
        .frame(width: 560, height: 460) // fits under the Settings window; the form scrolls
        .background(Color.kervanCanvas)
        .onAppear { name = update ?? MacNode.suggestedName(from: Host.current().localizedName ?? ProcessInfo.processInfo.hostName) }
        .onChange(of: model.store.nodeInvite?.code) { _, code in
            guard waitingForInvite, let code, model.store.nodeInvite?.name == name else { return }
            waitingForInvite = false
            start(code: code)
        }
    }

    /// Another machine already uses this name on the server.
    private var nameTaken: Bool {
        update == nil && model.store.nodeInfos.contains { $0.name == name }
    }

    private func start(code: String) {
        guard let script = MacNodeRunner.script, let address = model.activeAddress else { return }
        let hub = NodeSetup.hub(of: address)
        let name = name
        runner.run { MacNode.installCommand(script: script, hub: hub, code: code, name: name, log: $0) }
    }
}
