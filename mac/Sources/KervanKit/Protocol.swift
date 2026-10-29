import Foundation

// Wire types for protocol v1. Spec: protocol/v1.md. Keep in sync with server/src/protocol.ts.

public let kervanProtocolVersion = 1

public struct PeerInfo: Codable, Equatable, Sendable {
    public var name: String
    public var version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

public enum ClientMessage: Encodable, Equatable, Sendable {
    case hello(client: PeerInfo)
    case ping(id: String)

    private enum CodingKeys: String, CodingKey {
        case type, `protocol`, client, id
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let client):
            try container.encode("hello", forKey: .type)
            try container.encode(kervanProtocolVersion, forKey: .protocol)
            try container.encode(client, forKey: .client)
        case .ping(let id):
            try container.encode("ping", forKey: .type)
            try container.encode(id, forKey: .id)
        }
    }

    public func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

public enum ServerMessage: Decodable, Equatable, Sendable {
    case welcome(protocolVersion: Int, server: PeerInfo)
    case pong(id: String)
    case error(code: String, message: String, id: String?)
    /// A type this client doesn't know yet. Ignored, so the server can add types without a version bump.
    case unknown(type: String)

    private enum CodingKeys: String, CodingKey {
        case type, `protocol`, server, id, code, message
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "welcome":
            self = .welcome(
                protocolVersion: try container.decode(Int.self, forKey: .protocol),
                server: try container.decode(PeerInfo.self, forKey: .server)
            )
        case "pong":
            self = .pong(id: try container.decode(String.self, forKey: .id))
        case "error":
            self = .error(
                code: try container.decode(String.self, forKey: .code),
                message: try container.decode(String.self, forKey: .message),
                id: try container.decodeIfPresent(String.self, forKey: .id)
            )
        default:
            self = .unknown(type: type)
        }
    }

    public static func decode(_ text: String) throws -> ServerMessage {
        try JSONDecoder().decode(ServerMessage.self, from: Data(text.utf8))
    }
}
