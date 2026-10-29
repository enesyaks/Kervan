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

/// An agent the server can start, e.g. ("codex", "Codex").
public struct AgentInfo: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
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
    public var skills: [String]
    public var mcpServers: [String]
    /// Set for team members.
    public var teamId: String?
    public var role: String?
    /// Set for helpers: the lead session that started them.
    public var parentId: String?
    /// The agent may start and message helper agents.
    public var orchestrate: Bool
    public var error: String?

    public init(
        id: String, agent: String, title: String, status: SessionStatus, createdAt: String,
        archived: Bool = false, skills: [String] = [], mcpServers: [String] = [], teamId: String? = nil,
        role: String? = nil, parentId: String? = nil, orchestrate: Bool = false, error: String? = nil
    ) {
        self.parentId = parentId
        self.orchestrate = orchestrate
        self.teamId = teamId
        self.role = role
        self.id = id
        self.agent = agent
        self.title = title
        self.status = status
        self.createdAt = createdAt
        self.archived = archived
        self.skills = skills
        self.mcpServers = mcpServers
        self.error = error
    }

    private enum CodingKeys: String, CodingKey { case id, agent, title, status, createdAt, archived, skills, mcpServers, teamId, role, parentId, orchestrate, error }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        agent = try c.decode(String.self, forKey: .agent)
        title = try c.decode(String.self, forKey: .title)
        status = try c.decode(SessionStatus.self, forKey: .status)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        skills = try c.decodeIfPresent([String].self, forKey: .skills) ?? []
        mcpServers = try c.decodeIfPresent([String].self, forKey: .mcpServers) ?? []
        teamId = try c.decodeIfPresent(String.self, forKey: .teamId)
        role = try c.decodeIfPresent(String.self, forKey: .role)
        parentId = try c.decodeIfPresent(String.self, forKey: .parentId)
        orchestrate = try c.decodeIfPresent(Bool.self, forKey: .orchestrate) ?? false
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }
}

/// An MCP server as the server describes it: secret values are reduced to their names.
public struct McpServerSummary: Codable, Equatable, Sendable, Identifiable {
    public enum Transport: String, Codable, Sendable { case stdio, http }

    public let name: String
    public let transport: Transport
    public let command: String?
    public let args: [String]?
    public let url: String?
    public let envKeys: [String]
    public let headerKeys: [String]

    public var id: String { name }

    public init(name: String, transport: Transport, command: String? = nil, args: [String]? = nil, url: String? = nil, envKeys: [String] = [], headerKeys: [String] = []) {
        self.name = name
        self.transport = transport
        self.command = command
        self.args = args
        self.url = url
        self.envKeys = envKeys
        self.headerKeys = headerKeys
    }
}

/// A job in a team: which agent, what it's told up front, what it may use.
public struct Role: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var agent: String
    public var instructions: String
    public var skills: [String]
    public var mcpServers: [String]
    /// In a team, this member may start and message helper agents.
    public var lead: Bool

    public init(
        id: String, name: String, agent: String, instructions: String = "", skills: [String] = [], mcpServers: [String] = [],
        lead: Bool = false
    ) {
        self.lead = lead
        self.id = id
        self.name = name
        self.agent = agent
        self.instructions = instructions
        self.skills = skills
        self.mcpServers = mcpServers
    }

    private enum CodingKeys: String, CodingKey { case id, name, agent, instructions, skills, mcpServers, lead }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        agent = try c.decode(String.self, forKey: .agent)
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        skills = try c.decodeIfPresent([String].self, forKey: .skills) ?? []
        mcpServers = try c.decodeIfPresent([String].self, forKey: .mcpServers) ?? []
        lead = try c.decodeIfPresent(Bool.self, forKey: .lead) ?? false
    }
}

/// Sessions started together from roles, sharing one folder.
public struct TeamInfo: Decodable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let createdAt: String
    public let sessionIds: [String]

    public init(id: String, title: String, createdAt: String, sessionIds: [String]) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.sessionIds = sessionIds
    }
}

/// An agent as the server lists it for editing; env values are reduced to their names.
public struct AgentConfig: Decodable, Equatable, Sendable, Identifiable {
    public enum Source: String, Decodable, Sendable { case builtin, app }

    public let id: String
    public let name: String
    public let command: String
    public let args: [String]
    public let authMethod: String?
    public let skillsDir: String?
    public let envKeys: [String]
    public let node: String
    public let source: Source
    public let available: Bool

    public init(
        id: String, name: String, command: String, args: [String] = [], authMethod: String? = nil, skillsDir: String? = nil,
        envKeys: [String] = [], node: String = "local", source: Source, available: Bool = true
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.args = args
        self.authMethod = authMethod
        self.skillsDir = skillsDir
        self.envKeys = envKeys
        self.node = node
        self.source = source
        self.available = available
    }
}

/// What the app sends to add or edit an agent. A `nil` env value keeps the one stored on the server.
public struct AgentInput: Encodable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var command: String
    public var args: [String]
    public var authMethod: String?
    public var skillsDir: String?
    public var env: [String: String?]
    public var node: String

    public init(
        id: String, name: String, command: String, args: [String] = [], authMethod: String? = nil,
        skillsDir: String? = nil, env: [String: String?] = [:], node: String = "local"
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.args = args
        self.authMethod = authMethod
        self.skillsDir = skillsDir
        self.env = env
        self.node = node
    }

    private enum CodingKeys: String, CodingKey { case id, name, command, args, authMethod, skillsDir, env, node }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(command, forKey: .command)
        try c.encode(args, forKey: .args)
        try c.encodeIfPresent(authMethod, forKey: .authMethod)
        try c.encodeIfPresent(skillsDir, forKey: .skillsDir)
        try c.encode(node, forKey: .node)
        try c.encode(McpServerInput.nullable(env), forKey: .env)
    }
}

/// What the app sends to save an MCP server. A `nil` secret value keeps the one stored on the server.
public struct McpServerInput: Encodable, Equatable, Sendable {
    public var name: String
    public var transport: McpServerSummary.Transport
    public var command: String?
    public var args: [String]?
    public var env: [String: String?]?
    public var url: String?
    public var headers: [String: String?]?

    public init(
        name: String, transport: McpServerSummary.Transport, command: String? = nil, args: [String]? = nil,
        env: [String: String?]? = nil, url: String? = nil, headers: [String: String?]? = nil
    ) {
        self.name = name
        self.transport = transport
        self.command = command
        self.args = args
        self.env = env
        self.url = url
        self.headers = headers
    }

    private enum CodingKeys: String, CodingKey { case name, transport, command, args, env, url, headers }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(transport, forKey: .transport)
        try c.encodeIfPresent(command, forKey: .command)
        try c.encodeIfPresent(args, forKey: .args)
        try c.encodeIfPresent(url, forKey: .url)
        // Encode nil values as JSON null ("keep"), which the synthesized encoder would drop.
        if let env { try c.encode(Self.nullable(env), forKey: .env) }
        if let headers { try c.encode(Self.nullable(headers), forKey: .headers) }
    }

    /// Secret maps with JSON null for "keep the stored value", which the synthesized encoder would drop.
    static func nullable(_ map: [String: String?]) -> [String: NullableString] {
        map.mapValues { NullableString($0) }
    }

    struct NullableString: Encodable {
        let value: String?
        init(_ value: String?) { self.value = value }
        func encode(to encoder: any Encoder) throws {
            var c = encoder.singleValueContainer()
            if let value { try c.encode(value) } else { try c.encodeNil() }
        }
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
        /// `from` is the lead session when a lead agent, not the user, wrote it.
        case userMessage(String, attachments: [String] = [], from: String? = nil)
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
        case requestId, detail, options, optionId, attachments, from
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
                attachments: try c.decodeIfPresent([String].self, forKey: .attachments) ?? [],
                from: try c.decodeIfPresent(String.self, forKey: .from)
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
    case sessionCreate(id: String, agent: String, skills: [String] = [], mcpServers: [String] = [], orchestrate: Bool = false)
    case sessionList(id: String)
    case sessionHistory(id: String, sessionId: String)
    case sessionPrompt(id: String, sessionId: String, text: String, attachments: [String] = [])
    case sessionCancel(id: String, sessionId: String)
    case sessionPermission(id: String, sessionId: String, requestId: String, optionId: String)
    case sessionRename(id: String, sessionId: String, title: String)
    case sessionArchive(id: String, sessionId: String, archived: Bool)
    case sessionSearch(id: String, query: String)
    case mcpList(id: String)
    case mcpSave(id: String, server: McpServerInput)
    case mcpDelete(id: String, name: String)
    case agentList(id: String)
    case agentSave(id: String, agent: AgentInput)
    case agentDelete(id: String, agentId: String)
    case roleList(id: String)
    case roleSave(id: String, role: Role)
    case roleDelete(id: String, roleId: String)
    case teamCreate(id: String, title: String, roles: [String])
    case teamList(id: String)

    private enum CodingKeys: String, CodingKey {
        case type, `protocol`, client, id, agent, sessionId, text, requestId, optionId, attachments, title, archived, query
        case skills, mcpServers, server, name, agentId, role, roleId, roles, orchestrate
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
        case .sessionCreate(let id, let agent, let skills, let mcpServers, let orchestrate):
            try c.encode("session.create", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(agent, forKey: .agent)
            if !skills.isEmpty { try c.encode(skills, forKey: .skills) }
            if !mcpServers.isEmpty { try c.encode(mcpServers, forKey: .mcpServers) }
            if orchestrate { try c.encode(true, forKey: .orchestrate) }
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
        case .mcpList(let id):
            try c.encode("mcp.list", forKey: .type)
            try c.encode(id, forKey: .id)
        case .mcpSave(let id, let server):
            try c.encode("mcp.save", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(server, forKey: .server)
        case .mcpDelete(let id, let name):
            try c.encode("mcp.delete", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
        case .agentList(let id):
            try c.encode("agent.list", forKey: .type)
            try c.encode(id, forKey: .id)
        case .agentSave(let id, let agent):
            try c.encode("agent.save", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(agent, forKey: .agent)
        case .agentDelete(let id, let agentId):
            try c.encode("agent.delete", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(agentId, forKey: .agentId)
        case .roleList(let id):
            try c.encode("role.list", forKey: .type)
            try c.encode(id, forKey: .id)
        case .roleSave(let id, let role):
            try c.encode("role.save", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(role, forKey: .role)
        case .roleDelete(let id, let roleId):
            try c.encode("role.delete", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(roleId, forKey: .roleId)
        case .teamCreate(let id, let title, let roles):
            try c.encode("team.create", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(title, forKey: .title)
            try c.encode(roles, forKey: .roles)
        case .teamList(let id):
            try c.encode("team.list", forKey: .type)
            try c.encode(id, forKey: .id)
        }
    }

    public func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

public enum ServerMessage: Decodable, Equatable, Sendable {
    /// `agents` is in the server's order; the first is its default.
    case welcome(protocolVersion: Int, server: PeerInfo, agents: [AgentInfo])
    case pong(id: String)
    case ok(id: String)
    case error(code: String, message: String, id: String?)
    case sessionCreated(id: String, session: SessionInfo)
    case sessionListResult(id: String, sessions: [SessionInfo])
    case sessionHistoryResult(id: String, sessionId: String, events: [SessionEvent])
    case sessionUpdated(SessionInfo)
    case sessionEvent(sessionId: String, event: SessionEvent)
    case sessionSearchResult(id: String, hits: [SearchHit])
    case mcpListResult(id: String, servers: [McpServerSummary])
    case agentListResult(id: String, agents: [AgentConfig], nodes: [String])
    case agentsUpdated([AgentInfo])
    case roleListResult(id: String, roles: [Role])
    case teamCreated(id: String, team: TeamInfo)
    case teamListResult(id: String, teams: [TeamInfo])
    case teamUpdated(TeamInfo)
    /// A type this client doesn't know yet. Ignored, so the server can add types without a version bump.
    case unknown(type: String)

    private enum CodingKeys: String, CodingKey {
        case type, `protocol`, server, agents, agentDetails, id, code, message, session, sessions, sessionId, events, event, hits, servers
        case nodes, roles, team, teams
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "welcome":
            // Servers before M7 send only ids; their names then are the ids.
            let ids = try c.decodeIfPresent([String].self, forKey: .agents) ?? []
            let details = try c.decodeIfPresent([AgentInfo].self, forKey: .agentDetails)
            self = .welcome(
                protocolVersion: try c.decode(Int.self, forKey: .protocol),
                server: try c.decode(PeerInfo.self, forKey: .server),
                agents: details ?? ids.map { AgentInfo(id: $0, name: $0) }
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
        case "agent.list.result":
            self = .agentListResult(
                id: try c.decode(String.self, forKey: .id),
                agents: try c.decode([AgentConfig].self, forKey: .agents),
                nodes: try c.decodeIfPresent([String].self, forKey: .nodes) ?? ["local"]
            )
        case "role.list.result":
            self = .roleListResult(id: try c.decode(String.self, forKey: .id), roles: try c.decode([Role].self, forKey: .roles))
        case "team.created":
            self = .teamCreated(id: try c.decode(String.self, forKey: .id), team: try c.decode(TeamInfo.self, forKey: .team))
        case "team.list.result":
            self = .teamListResult(id: try c.decode(String.self, forKey: .id), teams: try c.decode([TeamInfo].self, forKey: .teams))
        case "team.updated":
            self = .teamUpdated(try c.decode(TeamInfo.self, forKey: .team))
        case "agents.updated":
            self = .agentsUpdated(try c.decode([AgentInfo].self, forKey: .agentDetails))
        case "mcp.list.result":
            self = .mcpListResult(id: try c.decode(String.self, forKey: .id), servers: try c.decode([McpServerSummary].self, forKey: .servers))
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

/// Splits a command line the way a shell would for plain words: spaces separate, "…" and '…' group,
/// a backslash escapes the next character. Lets argument fields hold paths with spaces.
public func splitArguments(_ line: String) -> [String] {
    var args: [String] = []
    var current = ""
    var quote: Character?
    var escaped = false
    var started = false
    for ch in line {
        if escaped {
            current.append(ch)
            escaped = false
        } else if ch == "\\" && quote != "'" {
            escaped = true
            started = true
        } else if let open = quote {
            if ch == open { quote = nil } else { current.append(ch) }
        } else if ch == "\"" || ch == "'" {
            quote = ch
            started = true
        } else if ch == " " || ch == "\t" {
            if started { args.append(current) }
            current = ""
            started = false
        } else {
            current.append(ch)
            started = true
        }
    }
    if started { args.append(current) }
    return args
}

/// The inverse: quotes arguments that need it, so an edit form shows what `splitArguments` reads back.
public func joinArguments(_ args: [String]) -> String {
    args.map { arg in
        arg.isEmpty || arg.contains(where: { " \t\"'\\".contains($0) }) ? "\"" + arg.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" : arg
    }.joined(separator: " ")
}
