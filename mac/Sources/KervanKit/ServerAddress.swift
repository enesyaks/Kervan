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
            command(hub: hub, code: code, sudo: "sudo -n"),
        ]
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
