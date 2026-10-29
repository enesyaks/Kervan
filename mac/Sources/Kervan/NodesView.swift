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
                HStack(spacing: 8) {
                    Circle()
                        .fill(node.connected ? Color.kervanOasis : Color.secondary.opacity(0.5))
                        .frame(width: 7, height: 7)
        .background(Color.kervanCanvas)
                    Text(node.name).font(.body.monospaced())
                    Text(node.connected ? "bağlı" : "bağlı değil").foregroundStyle(.secondary)
                    Spacer()
                    if let version = node.version {
                        Text("v\(version)").font(.caption).foregroundStyle(.tertiary)
                    }
                    Button("Kaldır", role: .destructive) { removing = node }.buttonStyle(.borderless)
                }
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
}

/// Name the node, then either copy one command to run on it, or let the app run it over SSH.
private struct AddNodeSheet: View {
    enum Method: Hashable { case command, ssh }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var method: Method = .command
    @State private var host = ""
    @State private var user = NSUserName()
    @State private var installer = SSHInstaller()
    @State private var copied = false
    @AppStorage(NodeHubChoice.key) private var storedHub = ""

    var body: some View {
        let invite = model.store.nodeInvite.flatMap { $0.name == name ? $0 : nil }
        let connected = model.store.nodeInfos.contains { $0.name == name && $0.connected }

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
                    Section {
                        Text("Yeni makine Ubuntu ya da Debian olmalı ve bu sunucuyla aynı Tailscale ağında bulunmalı.")
                            .foregroundStyle(.secondary)
                    }
                }

                if let invite, let address = model.activeAddress {
                    let hub = NodeHubChoice.resolve(storedHub, appHub: NodeSetup.hub(of: address))
                    Section {
                        Picker("Kurulum", selection: $method) {
                            Text("Komutu kendim çalıştırırım").tag(Method.command)
                            Text("Uygulama SSH ile kursun").tag(Method.ssh)
                        }
                        .pickerStyle(.radioGroup)
                    }

                    if method == .command {
                        Section {
                            let command = NodeSetup.command(hub: hub, code: invite.code)
                            Text(command)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                            Button(copied ? "Kopyalandı" : "Komutu kopyala") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(command, forType: .string)
                                copied = true
                            }
                        } header: {
                            Text("Bu komutu yeni makinede çalıştırın")
                        } footer: {
                            Text("Node hub'a \(hub) adresiyle bağlanacak; Node'lar bölümünden değiştirebilirsiniz. sudo parolanızı orada sorar. Kod tek kullanımlık ve 30 dakika geçerli.")
                        }
                    } else {
                        Section {
                            TextField("Adres", text: $host, prompt: Text("gpu-makinesi ya da 100.x.y.z"))
                                .font(.body.monospaced())
                            TextField("Kullanıcı", text: $user)
                                .font(.body.monospaced())
                            HStack {
                                Button(installer.isRunning ? "Kuruluyor…" : "Kur") {
                                    installer.run(NodeSetup.sshArguments(user: user, host: host, hub: hub, code: invite.code))
                                }
                                .disabled(host.isEmpty || user.isEmpty || installer.isRunning || connected)
                                if installer.isRunning { ProgressView().controlSize(.small) }
                            }
                            if let failure = installer.failure {
                                Label(failure, systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.kervanCoral)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if !installer.output.isEmpty {
                                ScrollView {
                                    Text(installer.output)
                                        .font(.caption.monospaced())
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(height: 120)
                                .defaultScrollAnchor(.bottom)
                            }
                        } footer: {
                            Text("Mac'inizin SSH anahtarıyla bağlanır; parola sormaz. Node hub'a \(hub) adresiyle bağlanacak.")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            HStack(spacing: 8) {
                if connected {
                    Label("'\(name)' bağlandı. Artık ajanları bu node'a atayabilirsiniz.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color.kervanOasis)
                } else if invite != nil {
                    CaravanDots()
                    Text("'\(name)' bekleniyor…").foregroundStyle(.secondary)
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
        .frame(width: 540, height: 420) // fits under the Settings window; the form scrolls
        .background(Color.kervanCanvas)
        .onDisappear { installer.stop() }
    }

    private static func isValid(_ name: String) -> Bool {
        name != "local" && name.range(of: "^[a-z0-9][a-z0-9-]{0,31}$", options: .regularExpression) != nil
    }
}

/// Runs the install command on another machine with the system ssh, showing what it prints.
@MainActor
@Observable
final class SSHInstaller {
    private(set) var output = ""
    private(set) var isRunning = false
    private(set) var failure: String?
    private var process: Process?

    func run(_ arguments: [String]) {
        output = ""
        failure = nil
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
                if status != 0 { self.failure = NodeSetup.explain(output: self.output) }
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
                Guidance(
                    text: "Hub güvenlik için 7420 portunu yalnızca Tailscale'e açıyor. Yerel ağdaki makinelerin bağlanabilmesi için hub'da bir kez şunu çalıştırın. Yerel ağda trafik şifrelenmez; yalnızca evinizdeki gibi güvendiğiniz ağlarda kullanın.",
                    command: NodeSetup.firewallCommand(network: lan.network ?? "192.168.1.0/24", port: Int(lan.address.split(separator: ":").last ?? "") ?? ServerAddress.defaultPort)
                )
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
