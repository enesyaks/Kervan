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

    public static func runArguments(user: String, host: String, access: Access) -> [String] {
        ssh(user, host, "sudo -n env ACCESS=\(access.rawValue) bash \(remoteFolder)/hub-setup.sh")
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
