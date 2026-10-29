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
            HStack {
                Text("Node'lar").font(.headline)
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
                    Section {
                        Picker("Kurulum", selection: $method) {
                            Text("Komutu kendim çalıştırırım").tag(Method.command)
                            Text("Uygulama SSH ile kursun").tag(Method.ssh)
                        }
                        .pickerStyle(.radioGroup)
                    }

                    if method == .command {
                        Section {
                            let command = NodeSetup.command(address: address, code: invite.code)
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
                            Text("sudo parolanızı orada sorar. Komuttaki kod tek kullanımlık ve 30 dakika geçerli.")
                        }
                    } else {
                        Section {
                            TextField("Adres", text: $host, prompt: Text("gpu-makinesi ya da 100.x.y.z"))
                                .font(.body.monospaced())
                            TextField("Kullanıcı", text: $user)
                                .font(.body.monospaced())
                            HStack {
                                Button(installer.isRunning ? "Kuruluyor…" : "Kur") {
                                    installer.run(NodeSetup.sshArguments(user: user, host: host, address: address, code: invite.code))
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
                            Text("Mac'inizin SSH anahtarıyla bağlanır; parola sormaz. O makinede sudo parola istiyorsa komutu kendiniz çalıştırın.")
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
