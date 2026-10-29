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

public enum Backoff {
    /// 1, 2, 4, 8, 16, 30, 30… seconds for attempt 1, 2, 3…
    public static func delay(attempt: Int) -> TimeInterval {
        min(30, pow(2, Double(max(attempt, 1) - 1)))
    }
}
