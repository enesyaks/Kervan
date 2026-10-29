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
    /// `curl -fsSL 'http://kervan:7420/v1/node/install?code=…' | sudo bash`, at the address the app uses.
    public static func command(address: ServerAddress, code: String, sudo: String = "sudo") -> String {
        var components = URLComponents(url: address.url, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "wss" ? "https" : "http"
        components.path = "/v1/node/install"
        components.queryItems = [URLQueryItem(name: "code", value: code)]
        return "curl -fsSL '\(components.url!.absoluteString)' | \(sudo) bash"
    }

    /// ssh arguments that never wait for a password: the Mac's SSH key, and `sudo -n` on the other side.
    public static func sshArguments(user: String, host: String, address: ServerAddress, code: String) -> [String] {
        [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=accept-new",
            "\(user)@\(host)",
            command(address: address, code: code, sudo: "sudo -n"),
        ]
    }

    /// Why an SSH install failed, in the user's words, from what ssh and the script printed.
    public static func explain(output: String) -> String {
        if output.contains("a password is required") || output.contains("a terminal is required") {
            return "Bu makinede sudo parola istiyor. Komutu o makinede kendiniz çalıştırın; parola orada sorulur."
        }
        if output.contains("Permission denied") {
            return "SSH bağlantısı reddedildi. Mac'inizin SSH anahtarını o makineye ekleyin (ssh-copy-id) ya da komutu kendiniz çalıştırın."
        }
        if output.contains("Could not resolve hostname") || output.contains("timed out") || output.contains("No route to host") {
            return "Makineye ulaşılamadı. Adresi ve makinenin Tailscale ağında olduğunu kontrol edin."
        }
        if output.contains("can't reach the hub") || output.contains("hub'a ulaşamıyor") {
            return "Makine hub'a ulaşamıyor. Önce aynı Tailscale ağına katın (sudo tailscale up)."
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
