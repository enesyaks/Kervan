import Foundation

/// What the user typed ("kervan", "kervan:7420", "ws://100.66.1.2") normalised to the socket URL.
public struct ServerAddress: Equatable, Sendable {
    public static let defaultPort = 7420
    public static let socketPath = "/v1/ws"

    public let url: URL

    public var host: String { url.host() ?? "" }

    public init?(_ input: String) {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "ws://" + text }

        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty
        else { return nil }

        switch scheme {
        case "ws", "http": components.scheme = "ws"
        case "wss", "https": components.scheme = "wss"
        default: return nil
        }
        if components.port == nil { components.port = Self.defaultPort }
        components.path = Self.socketPath
        components.query = nil
        components.fragment = nil

        guard let url = components.url else { return nil }
        self.url = url
    }
}

/// Adding a node: the one command that sets a new machine up, and how the app runs it over SSH.
public enum NodeSetup {
    /// `host:port` of the address the app itself uses, the default for nodes too.
    public static func hub(of address: ServerAddress) -> String {
        "\(address.host):\(address.url.port ?? ServerAddress.defaultPort)"
    }

    /// `curl -fsSL 'http://<hub>/v1/node/install?code=…' | sudo bash`. `hub` is host:port as the new machine can reach it.
    public static func command(hub: String, code: String, sudo: String = "sudo") -> String {
        let base = hub.contains("://") ? hub : "http://\(hub)"
        var components = URLComponents(string: base)!
        if components.scheme == "wss" { components.scheme = "https" } else if components.scheme == "ws" { components.scheme = "http" }
        components.path = "/v1/node/install"
        components.queryItems = [URLQueryItem(name: "code", value: code)]
        return "curl -fsSL '\(components.url!.absoluteString)' | \(sudo) bash"
    }

    public static func command(address: ServerAddress, code: String, sudo: String = "sudo") -> String {
        var components = URLComponents(url: address.url, resolvingAgainstBaseURL: false)!
        let scheme = components.scheme == "wss" ? "https" : "http"
        components.scheme = nil
        return command(hub: "\(scheme)://\(hub(of: address))", code: code, sudo: sudo)
    }

    /// ssh arguments that never wait for a password: the Mac's SSH key, and `sudo -n` on the other side.
    public static func sshArguments(user: String, host: String, hub: String, code: String) -> [String] {
        [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=accept-new",
            "\(user)@\(host)",
            // pipefail: when curl can't reach the hub, the run must fail, not end as an empty, "successful" bash.
            "bash -o pipefail -c \"\(command(hub: hub, code: code, sudo: "sudo -n"))\"",
        ]
    }

    /// The hub's LAN address on the same network as `target`, when `target` is a LAN IPv4 address there.
    public static func lanHub(for target: String, in addresses: [HubAddress]) -> HubAddress? {
        guard let ip = ipv4(target.trimmingCharacters(in: .whitespaces)) else { return nil }
        return addresses.first { address in
            guard address.kind == .lan, let network = address.network else { return false }
            let parts = network.split(separator: "/")
            guard parts.count == 2, let base = ipv4(String(parts[0])), let bits = UInt32(parts[1]), bits <= 32 else { return false }
            let mask: UInt32 = bits == 0 ? 0 : ~UInt32(0) << (32 - bits)
            return ip & mask == base & mask
        }
    }

    static func ipv4(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard let byte = UInt8(part) else { return nil }
            value = value << 8 | UInt32(byte)
        }
        return value
    }

    /// True when the hub answers /health at `hub` (host:port) within a few seconds, from this Mac.
    public static func isReachable(_ hub: String, timeout: TimeInterval = 3) async -> Bool {
        guard let url = URL(string: "http://\(hub)/health") else { return false }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// The hub-side firewall rule that lets machines on `network` reach the hub's port.
    public static func firewallCommand(network: String, port: Int) -> String {
        "sudo ufw allow from \(network) to any port \(port) proto tcp"
    }

    public static let tailscaleCommand = "curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale up"

    /// Why an SSH install failed, in the user's words, from what ssh, curl and the script printed.
    public static func explain(output: String) -> String {
        if output.contains("a password is required") || output.contains("a terminal is required") {
            return "Bu makinede sudo parola istiyor. Komutu o makinede kendiniz çalıştırın; parola orada sorulur."
        }
        if output.contains("Permission denied") {
            return "SSH bağlantısı reddedildi. Mac'inizin SSH anahtarını o makineye ekleyin (ssh-copy-id) ya da komutu kendiniz çalıştırın."
        }
        // macOS answers an app without Local Network permission with "No route to host", even when Terminal gets through.
        if output.contains("No route to host") {
            return "Mac bu uygulamanın yerel ağa çıkmasına izin vermiyor olabilir. Sistem Ayarları › Gizlilik ve Güvenlik › Yerel Ağ'da Kervan'ı açın, sonra yeniden deneyin. İzin açıksa makinenin aynı ağda ve açık olduğunu kontrol edin."
        }
        if output.contains("Could not resolve hostname") || output.contains("ssh: connect to host") {
            return "Makineye ulaşılamadı. Adresi ve makinenin açık olduğunu kontrol edin."
        }
        // curl on the new machine, fetching from the hub.
        if output.contains("Could not resolve host") {
            return "Yeni makine hub'ı bu adla bulamadı. Ayarlar › Ajanlar › Node'lar'dan hub için yerel ağ IP'sini seçin ya da makineyi Tailscale ağına katın."
        }
        if output.contains("Failed to connect") || output.contains("Connection timed out") || output.contains("Connection refused")
            || output.contains("can't reach the hub") || output.contains("hub'a ulaşamıyor") {
            return "Yeni makine hub'a bağlanamadı. Yerel ağ adresi seçtiyseniz hub'ın güvenlik duvarına izin ekleyin (Ayarlar › Ajanlar › Node'lar'daki komut)."
        }
        return "Kurulum tamamlanamadı. Ayrıntılar aşağıdaki çıktıda."
    }
}

public enum Backoff {
    /// 1, 2, 4, 8, 16, 30, 30… seconds for attempt 1, 2, 3…
    public static func delay(attempt: Int) -> TimeInterval {
        min(30, pow(2, Double(max(attempt, 1) - 1)))
    }
}

/// Which way new nodes reach the hub, stored as a kind so it follows the hub when its IP changes:
/// "" the name the app uses (Tailscale), "lan" / "tailscale" the hub's current address of that kind,
/// anything else an address the user typed.
public enum NodeHubChoice {
    public static let key = "nodeHub"
    public static let lan = "lan"
    public static let tailscale = "tailscale"

    public static func resolve(_ stored: String, appHub: String, addresses: [HubAddress]) -> String {
        let trimmed = stored.trimmingCharacters(in: .whitespaces)
        switch trimmed {
        case "": return appHub
        case lan: return addresses.first { $0.kind == .lan }?.address ?? appHub
        case tailscale: return addresses.first { $0.kind == .tailscale }?.address ?? appHub
        default: return trimmed
        }
    }

    /// An address saved by an earlier version becomes its kind, so it no longer pins an old IP.
    public static func migrate(_ stored: String, addresses: [HubAddress]) -> String {
        guard let match = addresses.first(where: { $0.address == stored }) else { return stored }
        return match.kind == .lan ? lan : tailscale
    }

    /// The fix to run on a node that can't find the hub: point it at `hub` and restart it.
    public static func repairCommand(hub: String) -> String {
        "sudo sed -i 's#^KERVAN_HUB_URL=.*#KERVAN_HUB_URL=ws://\(hub)#' /etc/kervan/node.env && sudo systemctl restart kervan-node"
    }
}
