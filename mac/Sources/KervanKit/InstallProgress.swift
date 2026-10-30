import Foundation

/// The stages of setting up a node, as the install script reports them ("==> …" lines).
public enum InstallStep: Int, CaseIterable, Comparable, Sendable {
    case connecting, checkingHub, packages, files, joining, service, connected

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var title: String {
        switch self {
        case .connecting: L("Connecting to the machine", "Makineye bağlanılıyor")
        case .checkingHub: L("Checking access to the hub", "Hub'a erişim kontrol ediliyor")
        case .packages: L("Installing packages and Node.js", "Gerekli paketler ve Node.js kuruluyor")
        case .files: L("Downloading Kervan", "Kervan kodu indiriliyor")
        case .joining: L("Joining the hub", "Hub'a katılınıyor")
        case .service: L("Starting the service", "Servis başlatılıyor")
        case .connected: L("Node connected", "Node bağlandı")
        }
    }

    /// One line on what is happening, for the step in progress.
    public var detail: String {
        switch self {
        case .connecting: L("Connecting with your Mac's SSH key.", "Mac'inizin SSH anahtarıyla bağlanıyor.")
        case .checkingHub: L("Checking that the new machine can reach the hub.", "Yeni makinenin hub'a ulaşabildiği deneniyor.")
        case .packages: L("The longest step; it can take a few minutes depending on the machine.", "En uzun adım bu; makinenin hızına göre birkaç dakika sürebilir.")
        case .files: L("Getting the code from the hub and installing its dependencies.", "Kod hub'dan alınıyor ve bağımlılıkları kuruluyor.")
        case .joining: L("Trading the invite code for a key of this machine's own.", "Davet kodu, bu makineye özel bir anahtarla takas ediliyor.")
        case .service: L("Installing and starting the kervan-node service.", "kervan-node servisi kuruluyor ve açılıyor.")
        case .connected: L("The node is connected to the hub and ready to run agents.", "Node hub'a bağlandı ve ajan çalıştırmaya hazır.")
        }
    }

    /// The furthest stage the script's output shows it has reached.
    public static func reached(in output: String) -> InstallStep {
        var step = InstallStep.connecting
        for line in output.split(whereSeparator: \.isNewline) where line.hasPrefix("==>") {
            let text = line.lowercased()
            let found: InstallStep? =
                text.contains("hub kontrol") || text.contains("checking the hub") ? .checkingHub
                : text.contains("paketler") || text.contains("packages") || text.contains("node.js") ? .packages
                : text.contains("kullanıcı") || text.contains("kervan kodu") || text.contains("user and") || text.contains("kervan code") ? .files
                : text.contains("katılınıyor") || text.contains("joining") ? .joining
                : text.contains("servis") || text.contains("service") ? .service
                : nil
            if let found, found > step { step = found }
        }
        return step
    }
}
