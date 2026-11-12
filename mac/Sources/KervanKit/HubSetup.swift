import Foundation
import Security

/// Setting up a hub on a new machine from the app: what runs over SSH, and how to read its progress.
public enum HubSetup {
    public enum Access: String, CaseIterable, Sendable {
        /// Reachable over Tailscale only, which encrypts the traffic.
        case tailscale
        /// An existing hub: its code and service are replaced and its settings stay. The home network closes if
        /// Tailscale is up there; if not it stays open, so an update never locks anyone out.
        case update
        /// Installs rootless Podman so agents can build in containers, and restarts the service; nothing else.
        case podman
    }

    public static let remoteFolder = "/tmp/kervan-setup"

    /// A fresh access token, 64 hex characters.
    public static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func ssh(_ user: String, _ host: String, _ command: String) -> [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=accept-new", "\(user)@\(host)", command]
    }

    /// Unpacks the setup files sent on stdin into a folder only the SSH user can read.
    public static func uploadArguments(user: String, host: String) -> [String] {
        ssh(user, host, "rm -rf \(remoteFolder) && mkdir -m 700 \(remoteFolder) && tar -xzf - -C \(remoteFolder)")
    }

    /// The server's MagicDNS name, once it has one; asked over SSH, which stays open on the home network.
    /// The first DNSName in the status is the machine's own; its peers come later.
    public static func tailscaleAddressArguments(user: String, host: String) -> [String] {
        ssh(user, host, "tailscale status --json 2>/dev/null | grep -m1 '\"DNSName\"' | cut -d'\"' -f4")
    }

    /// Succeeds when sudo works without a password there, so the app can run the setup itself.
    public static func sudoCheckArguments(user: String, host: String) -> [String] {
        ssh(user, host, "sudo -n true")
    }

    /// Succeeds while the token is still there. The setup script removes it as it exits, so once it is gone a run
    /// started in the user's Terminal has finished, well or badly; the app can stop waiting blind for the one that failed.
    public static func tokenCheckArguments(user: String, host: String) -> [String] {
        ssh(user, host, "test -e \(remoteFolder)/token")
    }

    public static func runArguments(user: String, host: String, access: Access) -> [String] {
        ssh(user, host, "sudo -n env ACCESS=\(access.rawValue) bash \(remoteFolder)/hub-setup.sh")
    }

    /// Lets this Mac log in to the machine without a password from now on. Terminal asks for the machine's password
    /// once. A Mac with no SSH key yet gets one first, or ssh-copy-id would only say "No identities found".
    public static func copyKeyCommand(user: String, host: String) -> String {
        // The key names ssh-copy-id looks for, tested one by one: a glob that matches nothing makes zsh print an error.
        "test -e ~/.ssh/id_ed25519.pub -o -e ~/.ssh/id_rsa.pub -o -e ~/.ssh/id_ecdsa.pub || { mkdir -p ~/.ssh && ssh-keygen -q -t ed25519 -N '' -f ~/.ssh/id_ed25519; }; ssh-copy-id \(user)@\(host)"
    }

    /// For the Mac's own Terminal when sudo needs a password: it is typed there, never into the app.
    public static func terminalCommand(user: String, host: String, access: Access) -> String {
        "ssh -t \(user)@\(host) \"sudo env ACCESS=\(access.rawValue) bash \(remoteFolder)/hub-setup.sh\""
    }

    /// The Tailscale sign-in link `tailscale up` prints, if it has.
    public static func tailscaleLoginURL(in output: String) -> URL? {
        guard let range = output.range(of: #"https://login\.tailscale\.com/\S+"#, options: .regularExpression) else { return nil }
        return URL(string: String(output[range]))
    }
}

/// Why this Mac's SSH key can't log in on its own, and what puts that right. The app runs ssh with no terminal to ask
/// in, so a key with a passphrase is no use to it unless the ssh agent already holds it, and ssh-copy-id can't help:
/// the server may well have the key and still be refused, because this side can't open it.
public enum SSHKeys {
    /// The private keys ssh tries by default, most preferred first.
    public static let defaultKeys = ["id_ed25519", "id_ecdsa", "id_rsa"]

    /// The key to unlock: this Mac has keys, none of them opens without a passphrase, and the agent holds none.
    public static func lockedKey(present: [String], unlocked: Set<String>, agentHasKeys: Bool) -> String? {
        guard !agentHasKeys, !present.isEmpty, !present.contains(where: unlocked.contains) else { return nil }
        return defaultKeys.first(where: present.contains) ?? present.first
    }

    /// Puts the key in the ssh agent with its passphrase kept in the Keychain (Terminal asks for it once), and has ssh
    /// take it from there after a restart too, unless ~/.ssh/config already says so.
    public static func unlockCommand(key: String) -> String {
        "ssh-add --apple-use-keychain ~/.ssh/\(key) && { grep -qs 'UseKeychain yes' ~/.ssh/config || printf '\\nHost *\\n  UseKeychain yes\\n  AddKeysToAgent yes\\n' >> ~/.ssh/config; }"
    }

    /// Looks at this Mac: which default keys there are, which open without a passphrase, whether the agent has any.
    /// Runs two small programs, so call it off the main thread.
    public static func probe(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let folder = home.appendingPathComponent(".ssh")
        let present = defaultKeys.filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
        guard !present.isEmpty else { return nil }
        // -P "" tries an empty passphrase and fails at once on a key that has one; nothing waits for typing.
        let unlocked = Set(present.filter { run("/usr/bin/ssh-keygen", ["-y", "-P", "", "-f", folder.appendingPathComponent($0).path]) == 0 })
        // 0: it holds keys; 1: it holds none; 2: there is no agent.
        let agentHasKeys = run("/usr/bin/ssh-add", ["-l"]) == 0
        return lockedKey(present: present, unlocked: unlocked, agentHasKeys: agentHasKeys)
    }

    private static func run(_ program: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

    /// What the app says instead of "add your key with ssh-copy-id" when the key is locked.
    public static var lockedMessage: String {
        L(
            "The SSH connection was refused because this Mac's SSH key has a passphrase, and Kervan can't type it. Unlock the key once, as below, then try again.",
            "SSH bağlantısı reddedildi, çünkü bu Mac'in SSH anahtarı parolalı ve Kervan parolayı giremez. Anahtarı aşağıdaki gibi bir kez açın, sonra yeniden deneyin."
        )
    }
}

/// The stages of setting up a hub, as hub-setup.sh reports them.
public enum HubSetupStep: Int, CaseIterable, Comparable, Sendable {
    case uploading, packages, files, settings, firewall, service, tailscaleLogin, ready

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var title: String {
        switch self {
        case .uploading: L("Sending the setup files", "Kurulum dosyaları makineye gönderiliyor")
        case .packages: L("Installing packages and Node.js", "Gerekli paketler ve Node.js kuruluyor")
        case .files: L("Installing Kervan", "Kervan kuruluyor")
        case .settings: L("Writing settings and the access key", "Ayarlar ve erişim anahtarı yazılıyor")
        case .firewall: L("Setting up the firewall", "Güvenlik duvarı ayarlanıyor")
        case .service: L("Starting the Kervan service", "Kervan servisi başlatılıyor")
        case .tailscaleLogin: L("Tailscale sign-in", "Tailscale girişi")
        case .ready: L("Server ready", "Sunucu hazır")
        }
    }

    public var detail: String {
        switch self {
        case .uploading: L("Connects with your Mac's SSH key and copies Kervan to the machine.", "Mac'inizin SSH anahtarıyla bağlanıp Kervan'ı makineye kopyalıyor.")
        case .packages: L("The longest step; it can take a few minutes depending on the machine.", "En uzun adım bu; makinenin hızına göre birkaç dakika sürebilir.")
        case .files: L("Preparing the kervan user, folders and dependencies.", "Kervan kullanıcısı, klasörler ve bağımlılıklar hazırlanıyor.")
        case .settings: L("The key the app made is written to the server; on your Mac only you can read it.", "Uygulamanın ürettiği anahtar sunucuya yazılıyor; Mac'inizde onu yalnızca siz okuyabilirsiniz.")
        case .firewall: L("Only SSH and Kervan's port are opened.", "Yalnızca SSH ve Kervan'ın portu açılıyor.")
        case .service: L("The server is starting; waiting for it to answer.", "Sunucu açılıyor ve yanıt vermesi bekleniyor.")
        case .tailscaleLogin: L("Sign in with your Tailscale account at the link that opens.", "Açılan bağlantıdan Tailscale hesabınızla giriş yapın.")
        case .ready: L("The app is connecting to the server.", "Uygulama sunucuya bağlanıyor.")
        }
    }

    public static func reached(in output: String) -> HubSetupStep {
        var step = HubSetupStep.uploading
        for line in output.split(whereSeparator: \.isNewline) where line.hasPrefix("==>") {
            let text = line.lowercased()
            // English since 0.2; the Turkish markers are what older setup scripts print.
            let signIn = text.contains("sign-in") || text.contains("giriş")
            let found: HubSetupStep? =
                text.contains("packages") || text.contains("paketler") || text.contains("node.js") ? .packages
                : text.contains("user and") || text.contains("kervan code") || text.contains("kullanıcı") || text.contains("kervan kodu") ? .files
                : text.contains("settings") || text.contains("ayarlar") || text.contains("==> tailscale") && !signIn ? .settings
                : text.contains("firewall") || text.contains("güvenlik") ? .firewall
                : text.contains("service") || text.contains("servis") ? .service
                : signIn ? .tailscaleLogin
                : text.contains("ready") || text.contains("hazır") ? .ready
                : nil
            if let found, found > step { step = found }
        }
        return step
    }
}
