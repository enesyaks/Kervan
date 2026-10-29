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

public struct PermissionChoice: Codable, Equatable, Sendable, Identifiable {
    public var optionId: String
    public var name: String
    /// allow_once | allow_always | reject_once | reject_always
    public var kind: String

    public var id: String { optionId }
    public var allows: Bool { kind.hasPrefix("allow") }

    public init(optionId: String, name: String, kind: String) {
        self.optionId = optionId
        self.name = name
        self.kind = kind
    }
}

public enum SessionStatus: String, Codable, Equatable, Sendable {
    /// `waiting`: blocked on a permission request the user hasn't answered.
    case starting, idle, running, waiting, error, closed, unknown

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SessionStatus(rawValue: raw) ?? .unknown
    }
}

public struct SessionInfo: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var agent: String
    public var title: String
    public var status: SessionStatus
    public var createdAt: String
    public var archived: Bool
    public var error: String?

    public init(
        id: String, agent: String, title: String, status: SessionStatus, createdAt: String,
        archived: Bool = false, error: String? = nil
    ) {
        self.id = id
        self.agent = agent
        self.title = title
        self.status = status
        self.createdAt = createdAt
        self.archived = archived
        self.error = error
    }

    private enum CodingKeys: String, CodingKey { case id, agent, title, status, createdAt, archived, error }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        agent = try c.decode(String.self, forKey: .agent)
        title = try c.decode(String.self, forKey: .title)
        status = try c.decode(SessionStatus.self, forKey: .status)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }
}

public struct SearchHit: Decodable, Equatable, Sendable, Identifiable {
    public enum Role: String, Decodable, Sendable { case user, agent }

    public let sessionId: String
    public let seq: Int
    public let role: Role
    /// Matches are wrapped in U+0001 … U+0002 by the server.
    public let snippet: String

    public var id: String { "\(sessionId)-\(seq)" }

    public init(sessionId: String, seq: Int, role: Role, snippet: String) {
        self.sessionId = sessionId
        self.seq = seq
        self.role = role
        self.snippet = snippet
    }

    /// The snippet split into runs, `true` for the matched ones.
    public var parts: [(text: String, matched: Bool)] {
        var parts: [(String, Bool)] = []
        var current = ""
        var matched = false
        for ch in snippet {
            if ch == "\u{1}" || ch == "\u{2}" {
                if !current.isEmpty { parts.append((current, matched)) }
                current = ""
                matched = ch == "\u{1}"
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { parts.append((current, matched)) }
        return parts
    }
}

public struct SessionEvent: Decodable, Equatable, Sendable {
    public enum Body: Equatable, Sendable {
        case userMessage(String, attachments: [String] = [])
        case agentMessageChunk(String)
        case agentThoughtChunk(String)
        case toolCall(id: String, title: String, kind: String, status: String)
        case toolCallUpdate(id: String, title: String?, status: String?)
        case permissionRequest(requestId: String, title: String, toolKind: String, detail: String?, options: [PermissionChoice])
        /// `optionId` is nil when the request was cancelled.
        case permissionResolved(requestId: String, optionId: String?)
        case turnEnd(stopReason: String)
        /// Something Kervan itself did, e.g. resuming the agent after a server restart.
        case notice(String)
        case error(String)
        /// A kind this client doesn't know yet; ignored.
        case unknown(kind: String)
    }

    public let seq: Int
    public let at: String
    public let body: Body

    public init(seq: Int, at: String = "", body: Body) {
        self.seq = seq
        self.at = at
        self.body = body
    }

    private enum CodingKeys: String, CodingKey {
        case seq, at, kind, text, toolCallId, title, toolKind, status, stopReason, message
        case requestId, detail, options, optionId, attachments
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seq = try c.decode(Int.self, forKey: .seq)
        at = try c.decodeIfPresent(String.self, forKey: .at) ?? ""
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "user_message":
            body = .userMessage(
                try c.decode(String.self, forKey: .text),
                attachments: try c.decodeIfPresent([String].self, forKey: .attachments) ?? []
            )
        case "agent_message_chunk": body = .agentMessageChunk(try c.decode(String.self, forKey: .text))
        case "agent_thought_chunk": body = .agentThoughtChunk(try c.decode(String.self, forKey: .text))
        case "tool_call":
            body = .toolCall(
                id: try c.decode(String.self, forKey: .toolCallId),
                title: try c.decode(String.self, forKey: .title),
                kind: try c.decodeIfPresent(String.self, forKey: .toolKind) ?? "other",
                status: try c.decodeIfPresent(String.self, forKey: .status) ?? "pending"
            )
        case "tool_call_update":
            body = .toolCallUpdate(
                id: try c.decode(String.self, forKey: .toolCallId),
                title: try c.decodeIfPresent(String.self, forKey: .title),
                status: try c.decodeIfPresent(String.self, forKey: .status)
            )
        case "permission_request":
            body = .permissionRequest(
                requestId: try c.decode(String.self, forKey: .requestId),
                title: try c.decode(String.self, forKey: .title),
                toolKind: try c.decodeIfPresent(String.self, forKey: .toolKind) ?? "other",
                detail: try c.decodeIfPresent(String.self, forKey: .detail),
                options: try c.decode([PermissionChoice].self, forKey: .options)
            )
        case "permission_resolved":
            body = .permissionResolved(
                requestId: try c.decode(String.self, forKey: .requestId),
                optionId: try c.decodeIfPresent(String.self, forKey: .optionId)
            )
        case "turn_end": body = .turnEnd(stopReason: try c.decode(String.self, forKey: .stopReason))
        case "notice": body = .notice(try c.decode(String.self, forKey: .text))
        case "error": body = .error(try c.decode(String.self, forKey: .message))
        default: body = .unknown(kind: kind)
        }
    }
}

public enum ClientMessage: Encodable, Equatable, Sendable {
    case hello(client: PeerInfo)
    case ping(id: String)
    case sessionCreate(id: String, agent: String)
    case sessionList(id: String)
    case sessionHistory(id: String, sessionId: String)
    case sessionPrompt(id: String, sessionId: String, text: String, attachments: [String] = [])
    case sessionCancel(id: String, sessionId: String)
    case sessionPermission(id: String, sessionId: String, requestId: String, optionId: String)
    case sessionRename(id: String, sessionId: String, title: String)
    case sessionArchive(id: String, sessionId: String, archived: Bool)
    case sessionSearch(id: String, query: String)

    private enum CodingKeys: String, CodingKey {
        case type, `protocol`, client, id, agent, sessionId, text, requestId, optionId, attachments, title, archived, query
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let client):
            try c.encode("hello", forKey: .type)
            try c.encode(kervanProtocolVersion, forKey: .protocol)
            try c.encode(client, forKey: .client)
        case .ping(let id):
            try c.encode("ping", forKey: .type)
            try c.encode(id, forKey: .id)
        case .sessionCreate(let id, let agent):
            try c.encode("session.create", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(agent, forKey: .agent)
        case .sessionList(let id):
            try c.encode("session.list", forKey: .type)
            try c.encode(id, forKey: .id)
        case .sessionHistory(let id, let sessionId):
            try c.encode("session.history", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(sessionId, forKey: .sessionId)
        case .sessionPrompt(let id, let sessionId, let text, let attachments):
            try c.encode("session.prompt", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(text, forKey: .text)
            if !attachments.isEmpty { try c.encode(attachments, forKey: .attachments) }
        case .sessionCancel(let id, let sessionId):
            try c.encode("session.cancel", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(sessionId, forKey: .sessionId)
        case .sessionPermission(let id, let sessionId, let requestId, let optionId):
            try c.encode("session.permission", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(requestId, forKey: .requestId)
            try c.encode(optionId, forKey: .optionId)
        case .sessionRename(let id, let sessionId, let title):
            try c.encode("session.rename", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(title, forKey: .title)
        case .sessionArchive(let id, let sessionId, let archived):
            try c.encode("session.archive", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(archived, forKey: .archived)
        case .sessionSearch(let id, let query):
            try c.encode("session.search", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(query, forKey: .query)
        }
    }

    public func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

public enum ServerMessage: Decodable, Equatable, Sendable {
    case welcome(protocolVersion: Int, server: PeerInfo, agents: [String])
    case pong(id: String)
    case ok(id: String)
    case error(code: String, message: String, id: String?)
    case sessionCreated(id: String, session: SessionInfo)
    case sessionListResult(id: String, sessions: [SessionInfo])
    case sessionHistoryResult(id: String, sessionId: String, events: [SessionEvent])
    case sessionUpdated(SessionInfo)
    case sessionEvent(sessionId: String, event: SessionEvent)
    case sessionSearchResult(id: String, hits: [SearchHit])
    /// A type this client doesn't know yet. Ignored, so the server can add types without a version bump.
    case unknown(type: String)

    private enum CodingKeys: String, CodingKey {
        case type, `protocol`, server, agents, id, code, message, session, sessions, sessionId, events, event, hits
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "welcome":
            self = .welcome(
                protocolVersion: try c.decode(Int.self, forKey: .protocol),
                server: try c.decode(PeerInfo.self, forKey: .server),
                agents: try c.decodeIfPresent([String].self, forKey: .agents) ?? []
            )
        case "pong": self = .pong(id: try c.decode(String.self, forKey: .id))
        case "ok": self = .ok(id: try c.decode(String.self, forKey: .id))
        case "error":
            self = .error(
                code: try c.decode(String.self, forKey: .code),
                message: try c.decode(String.self, forKey: .message),
                id: try c.decodeIfPresent(String.self, forKey: .id)
            )
        case "session.created":
            self = .sessionCreated(id: try c.decode(String.self, forKey: .id), session: try c.decode(SessionInfo.self, forKey: .session))
        case "session.list.result":
            self = .sessionListResult(id: try c.decode(String.self, forKey: .id), sessions: try c.decode([SessionInfo].self, forKey: .sessions))
        case "session.history.result":
            self = .sessionHistoryResult(
                id: try c.decode(String.self, forKey: .id),
                sessionId: try c.decode(String.self, forKey: .sessionId),
                events: try c.decode([SessionEvent].self, forKey: .events)
            )
        case "session.updated": self = .sessionUpdated(try c.decode(SessionInfo.self, forKey: .session))
        case "session.event":
            self = .sessionEvent(sessionId: try c.decode(String.self, forKey: .sessionId), event: try c.decode(SessionEvent.self, forKey: .event))
        case "session.search.result":
            self = .sessionSearchResult(id: try c.decode(String.self, forKey: .id), hits: try c.decode([SearchHit].self, forKey: .hits))
        default:
            self = .unknown(type: type)
        }
    }

    public static func decode(_ text: String) throws -> ServerMessage {
        try JSONDecoder().decode(ServerMessage.self, from: Data(text.utf8))
    }
}
