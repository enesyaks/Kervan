import AppKit
import KervanKit
import SwiftUI

/// Settings › Ajanlar: the machines running kervan-node for this server, adding and removing them.
struct NodesSection: View {
    @Environment(AppModel.self) private var model
    @AppStorage(NodeHubChoice.key) private var storedHub = ""
    @State private var adding = false
    @State private var removing: NodeInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MacNodeCard()
            if model.connection.state.isConnected, let address = model.activeAddress {
                HubConnectionCard(appHub: NodeSetup.hub(of: address))
                    .padding(.bottom, 10)
            }
            HStack {
                Text(L("Connected machines", "Bağlı makineler")).font(.headline)
                Spacer()
                Button(L("Add node…", "Node ekle…")) { adding = true }
                    .disabled(!model.connection.state.isConnected)
            }
            if model.store.nodeInfos.isEmpty {
                Text(L("You can run agents on other machines too. Click Add node; the app prepares the setup.", "Ajanları başka makinelerde de çalıştırabilirsiniz. Node ekle'ye basın; kurulumu uygulama hazırlar."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.store.nodeInfos) { node in
                let agents = model.store.agents.filter { $0.node == node.name }
                HStack(spacing: 10) {
                    StatusDot(color: node.connected ? Color.kervanOasis : Color.secondary.opacity(0.5))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(node.name).font(.body.monospaced())
                        Text(Self.detail(node, agents: agents.count))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L("Remove", "Kaldır"), role: .destructive) { removing = node }.buttonStyle(.borderless)
                }
                .padding(12)
                .softSurface(radius: Radius.chip)
                if let via = node.via, !node.connected, let address = model.activeAddress,
                   !Self.stillServes(via, appHub: NodeSetup.hub(of: address), addresses: model.store.hubAddresses) {
                    let hub = NodeHubChoice.resolve(storedHub, appHub: NodeSetup.hub(of: address), addresses: model.store.hubAddresses)
                    LostNodeHint(via: via, hub: hub)
                }
            }
            if !model.store.nodeInfos.isEmpty {
                Text(L("To run an agent on a node, edit it and pick the node in the Node field.", "Bir ajanı node'da çalıştırmak için düzenleyip Node alanından seçin."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $adding) { AddNodeSheet().environment(model) }
        .confirmationDialog(
            L("Remove node \(removing?.name ?? "")?", "\(removing?.name ?? "") node'u kaldırılsın mı?"),
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
        ) {
            Button(L("Remove node", "Node'u kaldır"), role: .destructive) {
                if let node = removing { Task { await model.store.removeNode(node.name) } }
            }
        } message: {
            Text(L("It's disconnected and its key stops working. The installation on that machine stays; adding it again needs a new invite.", "Bağlantısı kesilir ve anahtarı geçersiz olur. O makinedeki kurulum yerinde kalır; tekrar eklemek için yeni bir davet gerekir."))
        }
    }

    /// "bağlı, v0.1.0, 2 ajan" or "bağlı değil, en son 5 dk önce".
    private static func detail(_ node: NodeInfo, agents: Int) -> String {
        var parts = [node.connected ? L("connected", "bağlı") : L("not connected", "bağlı değil")]
        if !node.connected, let seen = node.lastSeen.flatMap(Self.parse) {
            parts.append(L("last seen ", "en son ") + seen.formatted(.relative(presentation: .named).locale(Language.shared.locale)))
        }
        if let version = node.version { parts.append("v\(version)") }
        parts.append(agents == 0 ? L("no agents assigned", "atanmış ajan yok") : L("\(agents) agents", "\(agents) ajan"))
        return parts.joined(separator: ", ")
    }

    /// Whether the hub still answers at the address a node last used (its name, or one of its current IPs).
    private static func stillServes(_ via: String, appHub: String, addresses: [HubAddress]) -> Bool {
        via == appHub || addresses.contains { $0.address == via } || via.contains(".local:")
    }

    private static func parse(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// Name the node, see what setting it up involves, then either copy one command to run on it or let the app
/// run it over SSH while showing each stage; once it connects, the sheet says what to do next.
private struct AddNodeSheet: View {
    enum Method: Hashable { case command, ssh }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var method: Method = .ssh
    @State private var host = ""
    @State private var user = NSUserName()
    @State private var installer = SSHInstaller()
    @State private var copied = false
    @AppStorage(NodeHubChoice.key) private var storedHub = ""
    @AppStorage(SettingsTab.key) private var settingsTab = SettingsTab.general

    var body: some View {
        let invite = model.store.nodeInvite.flatMap { $0.name == name ? $0 : nil }
        let connected = model.store.nodeInfos.contains { $0.name == name && $0.connected }
        let hub = model.activeAddress.map {
            NodeHubChoice.resolve(storedHub, appHub: NodeSetup.hub(of: $0), addresses: model.store.hubAddresses)
        } ?? ""

        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField(L("Node name", "Node adı"), text: $name, prompt: Text("gpu"))
                        .font(.body.monospaced())
                        .disabled(invite != nil)
                        .onChange(of: name) { name = name.lowercased() }
                } footer: {
                    Text(L("Shown next to the agent in the app, e.g. \"Claude Code (gpu)\". Lowercase letters, digits and '-'.", "Uygulamada ajanın yanında görünür, ör. \"Claude Code (gpu)\". Küçük harf, rakam ve '-'."))
                }

                if invite == nil {
                    Section(L("What happens", "Neler olacak")) {
                        Label(L("Node.js, Kervan and the kervan-node service are installed on the new machine. It usually takes 2–4 minutes.", "Yeni makineye Node.js, Kervan ve kervan-node servisi kurulur. Genelde 2–4 dakika sürer."), systemImage: "shippingbox")
                        Label(L("The machine connects to the hub with a key of its own; you can remove it any time from the Nodes tab.", "Makine hub'a kendine özel bir anahtarla bağlanır; Node'lar sekmesinden istediğiniz an kaldırabilirsiniz."), systemImage: "key")
                        Label(L("It reaches the hub at \(hub). If the machine isn't on Tailscale, pick the local network address in the Nodes tab.", "Hub'a \(hub) adresinden ulaşır. Makine Tailscale'de değilse Node'lar sekmesinden yerel ağ adresini seçin."), systemImage: "network")
                        Label(L("The machine must run Ubuntu or Debian. Your password never goes into the app.", "Makine Ubuntu ya da Debian olmalı. Parolanız uygulamaya hiç girilmez."), systemImage: "lock")
                    }
                    .labelStyle(GuideLabelStyle())
                }

                if let invite {
                    if !connected {
                        Section {
                            Picker(L("Setup", "Kurulum"), selection: $method) {
                                Text(L("Let the app install over SSH", "Uygulama SSH ile kursun")).tag(Method.ssh)
                                Text(L("I'll run the command myself", "Komutu kendim çalıştırırım")).tag(Method.command)
                            }
                            .pickerStyle(.radioGroup)
                            .disabled(installer.isRunning)
                        }
                    }

                    if method == .command && !connected {
                        Section {
                            let command = NodeSetup.command(hub: hub, code: invite.code)
                            Label(L("Copy the command.", "Komutu kopyalayın."), systemImage: "1.circle")
                            Text(command)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.kervanWell, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
                            Button(copied ? L("Copied", "Kopyalandı") : L("Copy command", "Komutu kopyala")) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(command, forType: .string)
                                copied = true
                            }
                            Label(L("Open a terminal on the new machine and paste it; sudo asks for your password there.", "Yeni makinede bir terminal açıp yapıştırın; sudo parolanızı orada sorar."), systemImage: "2.circle")
                            Label(L("This page updates by itself when setup is done.", "Kurulum bitince bu sayfa kendiliğinden güncellenir."), systemImage: "3.circle")
                        } header: {
                            Text(L("Run on the new machine", "Yeni makinede çalıştırın"))
                        } footer: {
                            Text(L("The code works once and expires in 30 minutes.", "Kod tek kullanımlık ve 30 dakika geçerli."))
                        }
                    }

                    if method == .ssh && !connected {
                        Section {
                            TextField(L("Address", "Adres"), text: $host, prompt: Text(L("e.g. 192.168.1.27", "ör. 192.168.1.27")))
                                .font(.body.monospaced())
                                .disabled(installer.isRunning)
                            TextField(L("User", "Kullanıcı"), text: $user)
                                .font(.body.monospaced())
                                .disabled(installer.isRunning)
                            if let suggestion = NodeSetup.lanHub(for: host, in: model.store.hubAddresses), suggestion.address != hub {
                                VStack(alignment: .leading, spacing: 8) {
                                    Label(L("This machine is on the hub's local network. If it isn't on Tailscale, it should reach the hub at its local address (\(suggestion.address)).", "Bu makine hub ile aynı yerel ağda. Tailscale'de değilse hub'a yerel ağ adresinden (\(suggestion.address)) bağlanmalı."), systemImage: "lightbulb")
                                        .font(.callout)
                                        .foregroundStyle(Color.kervanSaffron)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Button(L("Use the local address", "Yerel ağ adresini kullan")) { storedHub = suggestion.kind == .lan ? NodeHubChoice.lan : NodeHubChoice.tailscale }
                                }
                            }
                            if let lan = model.store.hubAddresses.first(where: { $0.address == hub && $0.kind == .lan }) {
                                LanCheck(hub: lan)
                            }
                            HStack {
                                Button(installer.failure == nil ? L("Install", "Kur") : L("Try again", "Yeniden dene")) {
                                    installer.run(NodeSetup.sshArguments(user: user, host: host, hub: hub, code: invite.code))
                                }
                                .buttonStyle(.kervanPrimary)
                                .disabled(host.isEmpty || user.isEmpty || installer.isRunning)
                                Spacer()
                            }
                        } header: {
                            Text(L("Which machine?", "Hangi makine?"))
                        } footer: {
                            Text(L("Connects with your Mac's SSH key; no password is asked.", "Mac'inizin SSH anahtarıyla bağlanır; parola sormaz."))
                        }
                    }

                    if installer.started || connected {
                        Section(L("Setup", "Kurulum")) {
                            InstallProgressList(
                                reached: connected ? .connected : (installer.succeeded ? .connected : InstallStep.reached(in: installer.output)),
                                running: installer.isRunning || (installer.succeeded && !connected),
                                failed: installer.failure != nil,
                                connected: connected,
                                startedAt: installer.startedAt
                            )
                            if let failure = installer.failure {
                                Label(failure, systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.kervanCoral)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if !installer.output.isEmpty {
                                DisclosureGroup(L("Detailed output", "Ayrıntılı çıktı")) {
                                    ScrollView {
                                        Text(installer.output)
                                            .font(.caption.monospaced())
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .frame(height: 120)
                                    .defaultScrollAnchor(.bottom)
                                }
                            }
                        }
                    } else if method == .command && invite.code.isEmpty == false && !connected {
                        Section {
                            HStack(spacing: 8) {
                                CaravanDots()
                                Text(L("Waiting for the machine to connect…", "Makinenin bağlanması bekleniyor…")).foregroundStyle(.secondary)
                            }
                        }
                    }

                    if connected {
                        Section(L("Next steps", "Sıradaki adımlar")) {
                            VStack(alignment: .leading, spacing: 8) {
                                Label(L("Add API keys for the agents on this machine", "Bu makinedeki ajanlar için API anahtarı ekleyin"), systemImage: "1.circle")
                                    .font(.callout.weight(.medium))
                                Guidance(
                                    text: L("On the node, add ANTHROPIC_API_KEY=…, OPENAI_API_KEY=… or GEMINI_API_KEY=… lines to this file and restart the service:", "Node'da şu dosyaya ANTHROPIC_API_KEY=…, OPENAI_API_KEY=… ya da GEMINI_API_KEY=… satırlarını ekleyip servisi yeniden başlatın:"),
                                    command: "sudo nano /etc/kervan/node.env && sudo systemctl restart kervan-node"
                                )
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                Label(L("Run an agent on this node", "Bir ajanı bu node'da çalıştırın"), systemImage: "2.circle")
                                    .font(.callout.weight(.medium))
                                Text(L("In the Agents tab, edit an agent and pick '\(name)' in the Node field. It shows up as \"Claude Code (\(name))\".", "Ajanlar sekmesinde bir ajanı düzenleyip Node alanından '\(name)' seçin. Uygulamada \"Claude Code (\(name))\" gibi görünür."))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Button(L("Go to the Agents tab", "Ajanlar sekmesine git")) {
                                    settingsTab = SettingsTab.agents
                                    dismiss()
                                }
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
                if invite == nil {
                    Button(L("Cancel", "Vazgeç"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(L("Continue", "Devam")) { Task { await model.store.inviteNode(name) } }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.kervanPrimary)
                        .disabled(!Self.isValid(name) || model.store.nodeInfos.contains { $0.name == name && $0.connected })
                } else {
                    Button(connected ? L("Done", "Bitti") : L("Close", "Kapat")) { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.kervanPrimary)
                }
            }
            .padding(16)
        }
        .frame(width: 560, height: 460) // fits under the Settings window; the form scrolls
        .background(Color.kervanCanvas)
        .onDisappear { installer.stop() }
    }

    private static func isValid(_ name: String) -> Bool {
        name != "local" && name.range(of: "^[a-z0-9][a-z0-9-]{0,31}$", options: .regularExpression) != nil
    }
}

/// Each install stage with its state: done, in progress (with time spent), failed, or still to come.
private struct InstallProgressList: View {
    let reached: InstallStep
    let running: Bool
    let failed: Bool
    let connected: Bool
    let startedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(InstallStep.allCases, id: \.self) { step in
                let done = step < reached || (connected && step == .connected)
                let current = step == reached && !done
                HStack(alignment: .top, spacing: 10) {
                    Group {
                        if done {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.kervanOasis)
                        } else if current && failed {
                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.kervanCoral)
                        } else if current && running {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "circle").foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title)
                            .font(.callout.weight(current ? .semibold : .regular))
                            .foregroundStyle(done || current ? .primary : .secondary)
                        if current {
                            Text(step == .connected && running ? L("The service is running; waiting for the machine to connect to the hub.", "Servis açıldı; makinenin hub'a bağlanması bekleniyor.") : step.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if current && running, let startedAt {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let seconds = Int(context.date.timeIntervalSince(startedAt))
                            Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Icons in a calm accent, text wrapping freely: for short guidance lists.
struct GuideLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            configuration.icon.foregroundStyle(Color.kervanLapis).frame(width: 18)
            configuration.title.fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Runs the install command on another machine with the system ssh, showing what it prints.
@MainActor
@Observable
final class SSHInstaller {
    private(set) var output = ""
    private(set) var isRunning = false
    private(set) var failure: String?
    private(set) var startedAt: Date?
    private(set) var succeeded = false
    var started: Bool { startedAt != nil }
    private var process: Process?

    func run(_ arguments: [String]) {
        output = ""
        failure = nil
        succeeded = false
        startedAt = Date()
        isRunning = true
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard !text.isEmpty else { return }
            Task { @MainActor in self?.output += text }
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor in
                guard let self else { return }
                pipe.fileHandleForReading.readabilityHandler = nil
                self.isRunning = false
                if status == 0 { self.succeeded = true } else { self.failure = NodeSetup.explain(output: self.output) }
            }
        }
        do {
            try process.run()
            self.process = process
        } catch {
            isRunning = false
            failure = L("Couldn't start ssh: \(error.localizedDescription)", "ssh başlatılamadı: \(error.localizedDescription)")
        }
    }

    func stop() {
        if process?.isRunning == true { process?.terminate() }
    }
}

/// Settings › Ajanlar: how new nodes reach the hub, with what each way needs done once.
private struct HubConnectionCard: View {
    let appHub: String
    @Environment(AppModel.self) private var model
    @AppStorage(NodeHubChoice.key) private var stored = ""
    @State private var custom = false

    var body: some View {
        let addresses = model.store.hubAddresses
        let hub = NodeHubChoice.resolve(stored, appHub: appHub, addresses: addresses)
        let lan = addresses.first { $0.address == hub && $0.kind == .lan }
        let lanNow = addresses.first { $0.kind == .lan }
        let tailscaleNow = addresses.first { $0.kind == .tailscale }
        let known = [NodeHubChoice.lan, NodeHubChoice.tailscale, ""].contains(stored)

        SettingsCard(
            title: L("How should nodes reach the hub?", "Node'lar hub'a nasıl bağlansın?"),
            footer: L("The choice is kept as a kind of address, so a new hub IP is picked up. Installed nodes know all of the hub's addresses and try the others if one changes.", "Seçim adres türü olarak saklanır; hub'ın IP'si değişirse yeni adresi kullanılır. Kurulan node'lar hub'ın bütün adreslerini bilir ve biri değişirse diğerlerini dener.")
        ) {
            Picker(L("Address", "Adres"), selection: Binding(
                get: { custom || !known ? "custom" : stored },
                set: { value in
                    custom = value == "custom"
                    if !custom { stored = value }
                }
            )) {
                Text(L("By Tailscale name: \(appHub) (recommended)", "Tailscale adıyla: \(appHub) (önerilen)")).tag("")
                if let tailscaleNow {
                    Text(L("By Tailscale IP (now \(tailscaleNow.address))", "Tailscale IP'siyle (şu an \(tailscaleNow.address))")).tag(NodeHubChoice.tailscale)
                }
                if let lanNow {
                    Text(L("Over the local network (now \(lanNow.address))", "Yerel ağdan (şu an \(lanNow.address))")).tag(NodeHubChoice.lan)
                }
                Text(L("Another address", "Başka bir adres")).tag("custom")
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .onAppear { stored = NodeHubChoice.migrate(stored, addresses: addresses) }
            .onChange(of: addresses) { stored = NodeHubChoice.migrate(stored, addresses: addresses) }

            if custom || !known {
                TextField("host:port", text: $stored, prompt: Text(L("e.g. 192.168.1.21:7420", "ör. 192.168.1.21:7420")))
                    .font(.body.monospaced())
            }

            Divider()

            if let lan {
                LanCheck(hub: lan)
            } else if stored.isEmpty || stored == NodeHubChoice.tailscale {
                Guidance(
                    text: L("The new machine must be on the same Tailscale network. If it isn't, run this once on it and sign in at the link it shows:", "Yeni makinenin de aynı Tailscale ağında olması gerekir. Değilse o makinede bir kez şunu çalıştırın ve açılan bağlantıdan giriş yapın:"),
                    command: NodeSetup.tailscaleCommand
                )
            } else {
                Text(L("Make sure the new machine can reach this address; the hub's firewall must allow it too.", "Yeni makinenin bu adrese ulaşabildiğinden emin olun; hub'ın güvenlik duvarı da bu bağlantıya izin vermeli."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A one-time step: what it is for, and the command to copy.
struct Guidance: View {
    let text: String
    let command: String
    /// It's meant for this Mac, so it can be started from here. The password is typed in Terminal, never in the app.
    var runsHere = false
    /// Runs before Terminal opens, for a command whose files have to be put back first; it answers with what went wrong.
    var prepare: (() async -> String?)?
    @State private var copied = false
    @State private var failure: String?

    private static let screen = Color(light: 0x16202E, dark: 0x0B111A)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: "$").foregroundStyle(Color.kervanOasis)
                    Text(command)
                        .foregroundStyle(.white.opacity(0.92))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout.monospaced())
                HStack(spacing: 8) {
                    Spacer()
                    Button(copied ? L("Copied", "Kopyalandı") : L("Copy", "Kopyala")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                        copied = true
                    }
                    .buttonStyle(.bordered)
                    .environment(\.colorScheme, .dark)
                    if runsHere {
                        Button {
                            Task {
                                failure = await prepare?()
                                if failure == nil { failure = TerminalRun.open(command) }
                            }
                        } label: {
                            Label(L("Run in Terminal", "Terminal'de çalıştır"), systemImage: "play.fill")
                        }
                        .buttonStyle(.kervanPrimary)
                        .tint(.kervanOasis)
                    }
                }
                .controlSize(.small)
            }
            .padding(12)
            .background(Self.screen, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Color.kervanCoral)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: command) { copied = false }
    }
}

/// Starts a command in the Mac's own Terminal, through a small script Terminal opens. Doing it there keeps any password
/// out of the app, and needs no permission to control Terminal.
enum TerminalRun {
    /// What the script holds: it removes itself, runs the command, and says when it's done.
    static func script(for command: String) -> String {
        "#!/bin/zsh\nrm -f \"$0\"\n\(command)\nprint\nprint 'You can close this window.'\n"
    }

    /// Nil when Terminal was told to run it, otherwise why it couldn't be.
    @MainActor static func open(_ command: String) -> String? {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kervan-\(UUID().uuidString).command")
        do {
            try script(for: command).write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        } catch {
            return L("Couldn't prepare the command: \(error.localizedDescription)", "Komut hazırlanamadı: \(error.localizedDescription)")
        }
        guard NSWorkspace.shared.open(file) else {
            try? FileManager.default.removeItem(at: file)
            return L("Terminal didn't open. Copy the command and run it there.", "Terminal açılmadı. Komutu kopyalayıp orada çalıştırın.")
        }
        return nil
    }
}

/// Whether the hub answers on its LAN address, tried from this Mac; if not, the one-time firewall rule to open it.
private struct LanCheck: View {
    let hub: HubAddress
    @State private var reachable: Bool?
    @State private var attempt = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch reachable {
            case nil:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L("Checking that the hub is reachable on the local network…", "Hub'ın yerel ağdan erişilebilir olduğu kontrol ediliyor…")).font(.callout).foregroundStyle(.secondary)
                }
            case true?:
                Label(L("The hub is reachable on the local network.", "Hub yerel ağdan erişilebilir."), systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(Color.kervanOasis)
            case false?:
                Label(L("The hub looks closed to the local network.", "Hub yerel ağdan kapalı görünüyor."), systemImage: "lock.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Color.kervanSaffron)
                Guidance(
                    text: L("For safety the hub opens port 7420 only to Tailscale. To let machines on the local network connect, run this once on the hub; sudo asks for your password there. Traffic on the local network isn't encrypted, so use this only on networks you trust.", "Hub güvenlik için 7420 portunu yalnızca Tailscale'e açıyor. Yerel ağdaki makineler bağlanabilsin diye hub'da (VM'de) bir kez şunu çalıştırın; sudo parolanızı orada sorar. Yerel ağda trafik şifrelenmez, yalnızca güvendiğiniz ağlarda kullanın."),
                    command: NodeSetup.firewallCommand(network: hub.network ?? "192.168.1.0/24", port: Int(hub.address.split(separator: ":").last ?? "") ?? ServerAddress.defaultPort)
                )
                Button(L("Check again", "Tekrar kontrol et")) { attempt += 1 }
            }
        }
        .task(id: "\(hub.address)-\(attempt)") {
            reachable = nil
            reachable = await NodeSetup.isReachable(hub.address)
        }
    }
}

/// Shown under an offline node whose last route to the hub is gone, e.g. after the hub got a new IP.
private struct LostNodeHint: View {
    let via: String
    let hub: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L("This node was reaching the hub at \(via); the hub isn't there any more.", "Bu node hub'a \(via) adresinden bağlanıyordu; hub artık o adreste değil."), systemImage: "arrow.triangle.branch")
                .font(.callout.weight(.medium))
                .foregroundStyle(Color.kervanSaffron)
                .fixedSize(horizontal: false, vertical: true)
            Guidance(
                text: L("The node tries the hub's other known addresses by itself. If it doesn't connect within a few minutes, run this on the node:", "Node, hub'ın bildiği diğer adreslerini kendisi dener. Birkaç dakika içinde bağlanmazsa node'da şunu çalıştırın:"),
                command: NodeHubChoice.repairCommand(hub: hub)
            )
        }
        .padding(12)
        .background(Color.kervanSaffron.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
    }
}
