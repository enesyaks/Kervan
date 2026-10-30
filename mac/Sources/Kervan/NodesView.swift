import AppKit
import KervanKit
import SwiftUI

/// Settings › Ajanlar: the machines running kervan-node for this server, adding and removing them.
struct NodesSection: View {
    @Environment(AppModel.self) private var model
    @State private var adding = false
    @State private var removing: NodeInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.connection.state.isConnected, let address = model.activeAddress {
                HubConnectionCard(appHub: NodeSetup.hub(of: address))
                    .padding(.bottom, 10)
            }
            HStack {
                Text("Bağlı makineler").font(.headline)
                Spacer()
                Button("Node ekle…") { adding = true }
                    .disabled(!model.connection.state.isConnected)
            }
            if model.store.nodeInfos.isEmpty {
                Text("Ajanları başka makinelerde de çalıştırabilirsiniz. Node ekle'ye basın; kurulumu uygulama hazırlar.")
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
                    Button("Kaldır", role: .destructive) { removing = node }.buttonStyle(.borderless)
                }
                .padding(12)
                .softSurface(radius: Radius.chip)
            }
            if !model.store.nodeInfos.isEmpty {
                Text("Bir ajanı node'da çalıştırmak için düzenleyip Node alanından seçin.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $adding) { AddNodeSheet().environment(model) }
        .confirmationDialog(
            "\(removing?.name ?? "") node'u kaldırılsın mı?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
        ) {
            Button("Node'u kaldır", role: .destructive) {
                if let node = removing { Task { await model.store.removeNode(node.name) } }
            }
        } message: {
            Text("Bağlantısı kesilir ve anahtarı geçersiz olur. O makinedeki kurulum yerinde kalır; tekrar eklemek için yeni bir davet gerekir.")
        }
    }

    /// "bağlı, v0.1.0, 2 ajan" or "bağlı değil, en son 5 dk önce".
    private static func detail(_ node: NodeInfo, agents: Int) -> String {
        var parts = [node.connected ? "bağlı" : "bağlı değil"]
        if !node.connected, let seen = node.lastSeen.flatMap(Self.parse) {
            parts.append("en son " + seen.formatted(.relative(presentation: .named).locale(Locale(identifier: "tr_TR"))))
        }
        if let version = node.version { parts.append("v\(version)") }
        parts.append(agents == 0 ? "atanmış ajan yok" : "\(agents) ajan")
        return parts.joined(separator: ", ")
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
        let hub = model.activeAddress.map { NodeHubChoice.resolve(storedHub, appHub: NodeSetup.hub(of: $0)) } ?? ""

        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Node adı", text: $name, prompt: Text("gpu"))
                        .font(.body.monospaced())
                        .disabled(invite != nil)
                        .onChange(of: name) { name = name.lowercased() }
                } footer: {
                    Text("Uygulamada ajanın yanında görünür, ör. \"Claude Code (gpu)\". Küçük harf, rakam ve '-'.")
                }

                if invite == nil {
                    Section("Neler olacak") {
                        Label("Yeni makineye Node.js, Kervan ve kervan-node servisi kurulur. Genelde 2–4 dakika sürer.", systemImage: "shippingbox")
                        Label("Makine hub'a kendine özel bir anahtarla bağlanır; Node'lar sekmesinden istediğiniz an kaldırabilirsiniz.", systemImage: "key")
                        Label("Hub'a \(hub) adresinden ulaşır. Makine Tailscale'de değilse Node'lar sekmesinden yerel ağ adresini seçin.", systemImage: "network")
                        Label("Makine Ubuntu ya da Debian olmalı. Parolanız uygulamaya hiç girilmez.", systemImage: "lock")
                    }
                    .labelStyle(GuideLabelStyle())
                }

                if let invite {
                    if !connected {
                        Section {
                            Picker("Kurulum", selection: $method) {
                                Text("Uygulama SSH ile kursun").tag(Method.ssh)
                                Text("Komutu kendim çalıştırırım").tag(Method.command)
                            }
                            .pickerStyle(.radioGroup)
                            .disabled(installer.isRunning)
                        }
                    }

                    if method == .command && !connected {
                        Section {
                            let command = NodeSetup.command(hub: hub, code: invite.code)
                            Label("Komutu kopyalayın.", systemImage: "1.circle")
                            Text(command)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.kervanWell, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
                            Button(copied ? "Kopyalandı" : "Komutu kopyala") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(command, forType: .string)
                                copied = true
                            }
                            Label("Yeni makinede bir terminal açıp yapıştırın; sudo parolanızı orada sorar.", systemImage: "2.circle")
                            Label("Kurulum bitince bu sayfa kendiliğinden güncellenir.", systemImage: "3.circle")
                        } header: {
                            Text("Yeni makinede çalıştırın")
                        } footer: {
                            Text("Kod tek kullanımlık ve 30 dakika geçerli.")
                        }
                    }

                    if method == .ssh && !connected {
                        Section {
                            TextField("Adres", text: $host, prompt: Text("ör. 192.168.1.27"))
                                .font(.body.monospaced())
                                .disabled(installer.isRunning)
                            TextField("Kullanıcı", text: $user)
                                .font(.body.monospaced())
                                .disabled(installer.isRunning)
                            if let suggestion = NodeSetup.lanHub(for: host, in: model.store.hubAddresses), suggestion.address != hub {
                                VStack(alignment: .leading, spacing: 8) {
                                    Label("Bu makine hub ile aynı yerel ağda. Tailscale'de değilse hub'a yerel ağ adresinden (\(suggestion.address)) bağlanmalı.", systemImage: "lightbulb")
                                        .font(.callout)
                                        .foregroundStyle(Color.kervanSaffron)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Button("Yerel ağ adresini kullan") { storedHub = suggestion.address }
                                }
                            }
                            if let lan = model.store.hubAddresses.first(where: { $0.address == hub && $0.kind == .lan }) {
                                LanCheck(hub: lan)
                            }
                            HStack {
                                Button(installer.failure == nil ? "Kur" : "Yeniden dene") {
                                    installer.run(NodeSetup.sshArguments(user: user, host: host, hub: hub, code: invite.code))
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(host.isEmpty || user.isEmpty || installer.isRunning)
                                Spacer()
                            }
                        } header: {
                            Text("Hangi makine?")
                        } footer: {
                            Text("Mac'inizin SSH anahtarıyla bağlanır; parola sormaz.")
                        }
                    }

                    if installer.started || connected {
                        Section("Kurulum") {
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
                                DisclosureGroup("Ayrıntılı çıktı") {
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
                                Text("Makinenin bağlanması bekleniyor…").foregroundStyle(.secondary)
                            }
                        }
                    }

                    if connected {
                        Section("Sıradaki adımlar") {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Bu makinedeki ajanlar için API anahtarı ekleyin", systemImage: "1.circle")
                                    .font(.callout.weight(.medium))
                                Guidance(
                                    text: "Node'da şu dosyaya ANTHROPIC_API_KEY=…, OPENAI_API_KEY=… ya da GEMINI_API_KEY=… satırlarını ekleyip servisi yeniden başlatın:",
                                    command: "sudo nano /etc/kervan/node.env && sudo systemctl restart kervan-node"
                                )
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Bir ajanı bu node'da çalıştırın", systemImage: "2.circle")
                                    .font(.callout.weight(.medium))
                                Text("Ajanlar sekmesinde bir ajanı düzenleyip Node alanından '\(name)' seçin. Uygulamada \"Claude Code (\(name))\" gibi görünür.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Button("Ajanlar sekmesine git") {
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
                    Label("'\(name)' bağlandı.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color.kervanOasis)
                }
                Spacer()
                if invite == nil {
                    Button("Vazgeç", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Devam") { Task { await model.store.inviteNode(name) } }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(!Self.isValid(name) || model.store.nodeInfos.contains { $0.name == name && $0.connected })
                } else {
                    Button(connected ? "Bitti" : "Kapat") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
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
                            Text(step == .connected && running ? "Servis açıldı; makinenin hub'a bağlanması bekleniyor." : step.detail)
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
private struct GuideLabelStyle: LabelStyle {
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
            failure = "ssh başlatılamadı: \(error.localizedDescription)"
        }
    }

    func stop() {
        if process?.isRunning == true { process?.terminate() }
    }
}

/// Which hub address new nodes are given: the app's own (usually the Tailscale name) unless the user picks another.
enum NodeHubChoice {
    static let key = "nodeHub"

    static func resolve(_ stored: String, appHub: String) -> String {
        let trimmed = stored.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? appHub : trimmed
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
        let hub = NodeHubChoice.resolve(stored, appHub: appHub)
        let lan = addresses.first { $0.address == hub && $0.kind == .lan }
        let known = stored.isEmpty || addresses.contains { $0.address == stored }

        SettingsCard(title: "Node'lar hub'a nasıl bağlansın?") {
            Picker("Adres", selection: Binding(
                get: { custom || !known ? "custom" : stored },
                set: { value in
                    custom = value == "custom"
                    if !custom { stored = value }
                }
            )) {
                Text("Tailscale adıyla: \(appHub) (önerilen)").tag("")
                ForEach(addresses) { address in
                    Text(address.kind == .lan ? "Yerel ağdan: \(address.address)" : "Tailscale IP'siyle: \(address.address)").tag(address.address)
                }
                Text("Başka bir adres").tag("custom")
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            if custom || !known {
                TextField("host:port", text: $stored, prompt: Text("ör. 192.168.1.21:7420"))
                    .font(.body.monospaced())
            }

            Divider()

            if let lan {
                LanCheck(hub: lan)
            } else if stored.isEmpty || addresses.contains(where: { $0.address == hub && $0.kind == .tailscale }) {
                Guidance(
                    text: "Yeni makinenin de aynı Tailscale ağında olması gerekir. Değilse o makinede bir kez şunu çalıştırın ve açılan bağlantıdan giriş yapın:",
                    command: NodeSetup.tailscaleCommand
                )
            } else {
                Text("Yeni makinenin bu adrese ulaşabildiğinden emin olun; hub'ın güvenlik duvarı da bu bağlantıya izin vermeli.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A one-time step: what it is for, and the command to copy.
private struct Guidance: View {
    let text: String
    let command: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 8) {
                Text(command)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.kervanWell, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
                Button(copied ? "Kopyalandı" : "Kopyala") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copied = true
                }
            }
        }
        .onChange(of: command) { copied = false }
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
                    Text("Hub'ın yerel ağdan erişilebilir olduğu kontrol ediliyor…").font(.callout).foregroundStyle(.secondary)
                }
            case true?:
                Label("Hub yerel ağdan erişilebilir.", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(Color.kervanOasis)
            case false?:
                Label("Hub yerel ağdan kapalı görünüyor.", systemImage: "lock.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Color.kervanSaffron)
                Guidance(
                    text: "Hub güvenlik için 7420 portunu yalnızca Tailscale'e açıyor. Yerel ağdaki makineler bağlanabilsin diye hub'da (VM'de) bir kez şunu çalıştırın; sudo parolanızı orada sorar. Yerel ağda trafik şifrelenmez, yalnızca güvendiğiniz ağlarda kullanın.",
                    command: NodeSetup.firewallCommand(network: hub.network ?? "192.168.1.0/24", port: Int(hub.address.split(separator: ":").last ?? "") ?? ServerAddress.defaultPort)
                )
                Button("Tekrar kontrol et") { attempt += 1 }
            }
        }
        .task(id: "\(hub.address)-\(attempt)") {
            reachable = nil
            reachable = await NodeSetup.isReachable(hub.address)
        }
    }
}
