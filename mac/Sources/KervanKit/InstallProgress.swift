import Foundation

/// The stages of setting up a node, as the install script reports them ("==> …" lines).
public enum InstallStep: Int, CaseIterable, Comparable, Sendable {
    case connecting, checkingHub, packages, files, joining, service, connected

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var title: String {
        switch self {
        case .connecting: "Makineye bağlanılıyor"
        case .checkingHub: "Hub'a erişim kontrol ediliyor"
        case .packages: "Gerekli paketler ve Node.js kuruluyor"
        case .files: "Kervan kodu indiriliyor"
        case .joining: "Hub'a katılınıyor"
        case .service: "Servis başlatılıyor"
        case .connected: "Node bağlandı"
        }
    }

    /// One line on what is happening, for the step in progress.
    public var detail: String {
        switch self {
        case .connecting: "Mac'inizin SSH anahtarıyla bağlanıyor."
        case .checkingHub: "Yeni makinenin hub'a ulaşabildiği deneniyor."
        case .packages: "En uzun adım bu; makinenin hızına göre birkaç dakika sürebilir."
        case .files: "Kod hub'dan alınıyor ve bağımlılıkları kuruluyor."
        case .joining: "Davet kodu, bu makineye özel bir anahtarla takas ediliyor."
        case .service: "kervan-node servisi kuruluyor ve açılıyor."
        case .connected: "Node hub'a bağlandı ve ajan çalıştırmaya hazır."
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
