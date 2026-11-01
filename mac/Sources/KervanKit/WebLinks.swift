import Foundation

/// An address a browser can open the web client at, and how far it reaches.
public struct WebLink: Equatable, Sendable, Identifiable {
    public enum Reach: Sendable, Equatable {
        /// Over Tailscale: from anywhere the phone or computer is signed in to the same tailnet.
        case tailscale
        /// Only from the same local network.
        case lan
        /// The address this app connects to, when the hub reported nothing better.
        case current
    }

    public let url: String
    public let reach: Reach
    /// True for a MagicDNS name rather than an IP.
    public let isName: Bool
    public var id: String { url }

    public init(url: String, reach: Reach, isName: Bool = false) {
        self.url = url
        self.reach = reach
        self.isName = isName
    }
}

/// Which http:// addresses to offer for the web client and for links in phone alerts.
public enum WebLinks {
    /// Tailscale first (its IP, then its MagicDNS name), then LAN addresses. When the hub reported none,
    /// the address the app uses. `current` is the app's server URL (ws:// or http://).
    public static func all(addresses: [HubAddress], current: URL?) -> [WebLink] {
        var links: [WebLink] = []
        for address in addresses where address.kind == .tailscale {
            links.append(WebLink(url: "http://\(address.address)", reach: .tailscale))
            if let host = address.host, !host.isEmpty, let port = port(of: address.address) {
                links.append(WebLink(url: "http://\(host):\(port)", reach: .tailscale, isName: true))
            }
        }
        for address in addresses where address.kind == .lan {
            links.append(WebLink(url: "http://\(address.address)", reach: .lan))
        }
        if links.isEmpty, let fallback = http(current) {
            links.append(WebLink(url: fallback, reach: currentReach(current)))
        }
        var seen = Set<String>()
        return links.filter { seen.insert($0.url).inserted }
    }

    /// The single best address for a link that must work away from home: Tailscale's IP, then LAN, then the app's.
    public static func preferred(addresses: [HubAddress], current: URL?) -> String? {
        let links = all(addresses: addresses, current: current)
        return (links.first { $0.reach == .tailscale && !$0.isName } ?? links.first { $0.reach == .tailscale } ?? links.first)?.url
    }

    /// True when the hub has a Tailscale address, i.e. the web client works away from home.
    public static func hasTailscale(_ addresses: [HubAddress]) -> Bool {
        addresses.contains { $0.kind == .tailscale }
    }

    static func http(_ url: URL?) -> String? {
        guard let url, let host = url.host(), !host.isEmpty else { return nil }
        let port = url.port ?? ServerAddress.defaultPort
        return "http://\(host.contains(":") ? "[\(host)]" : host):\(port)"
    }

    private static func port(of address: String) -> String? {
        guard let colon = address.lastIndex(of: ":") else { return nil }
        let port = address[address.index(after: colon)...]
        return port.isEmpty ? nil : String(port)
    }

    /// A Tailscale IP (100.64.0.0/10) or a *.ts.net name reaches from anywhere; anything else, assume home only.
    private static func currentReach(_ url: URL?) -> WebLink.Reach {
        guard let host = url?.host()?.lowercased() else { return .current }
        if host.hasSuffix(".ts.net") { return .tailscale }
        if let ip = NodeSetup.ipv4(host), ip >> 24 == 100, (ip >> 16) & 0xFF >= 64, (ip >> 16) & 0xFF <= 127 { return .tailscale }
        return .current
    }
}
