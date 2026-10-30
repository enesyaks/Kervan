import Foundation
import Security

/// Setting up a hub on a new machine from the app: what runs over SSH, and how to read its progress.
public enum HubSetup {
    public enum Access: String, CaseIterable, Sendable {
        /// Reachable from this network only.
        case lan
        /// This network and Tailscale, for reaching it from anywhere.
        case both
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
        case .uploading: "Kurulum dosyaları makineye gönderiliyor"
        case .packages: "Gerekli paketler ve Node.js kuruluyor"
        case .files: "Kervan kuruluyor"
        case .settings: "Ayarlar ve erişim anahtarı yazılıyor"
        case .firewall: "Güvenlik duvarı ayarlanıyor"
        case .service: "Kervan servisi başlatılıyor"
        case .tailscaleLogin: "Tailscale girişi"
        case .ready: "Sunucu hazır"
        }
    }

    public var detail: String {
        switch self {
        case .uploading: "Mac'inizin SSH anahtarıyla bağlanıp Kervan'ı makineye kopyalıyor."
        case .packages: "En uzun adım bu; makinenin hızına göre birkaç dakika sürebilir."
        case .files: "Kervan kullanıcısı, klasörler ve bağımlılıklar hazırlanıyor."
        case .settings: "Uygulamanın ürettiği anahtar sunucuya yazılıyor; Mac'inizde Keychain'de duruyor."
        case .firewall: "Yalnızca SSH ve Kervan'ın portu açılıyor."
        case .service: "Sunucu açılıyor ve yanıt vermesi bekleniyor."
        case .tailscaleLogin: "Açılan bağlantıdan Tailscale hesabınızla giriş yapın."
        case .ready: "Uygulama sunucuya bağlanıyor."
        }
    }

    public static func reached(in output: String) -> HubSetupStep {
        var step = HubSetupStep.uploading
        for line in output.split(whereSeparator: \.isNewline) where line.hasPrefix("==>") {
            let text = line.lowercased()
            let found: HubSetupStep? =
                text.contains("paketler") || text.contains("node.js") ? .packages
                : text.contains("kullanıcı") || text.contains("kervan kodu") ? .files
                : text.contains("ayarlar") || text.contains("==> tailscale") && !text.contains("giriş") ? .settings
                : text.contains("güvenlik") ? .firewall
                : text.contains("servis") ? .service
                : text.contains("giriş") ? .tailscaleLogin
                : text.contains("hazır") ? .ready
                : nil
            if let found, found > step { step = found }
        }
        return step
    }
}
