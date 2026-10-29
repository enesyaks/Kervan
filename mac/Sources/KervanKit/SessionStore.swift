import Foundation
import Observation

/// Client-side mirror of the server's sessions. Fed by `handle(_:)`; talks back through `send`.
@MainActor
@Observable
public final class SessionStore {
    public typealias Sender = @MainActor (ClientMessage) async throws -> Void

    /// Newest first.
    public private(set) var sessions: [SessionInfo] = []
    public private(set) var events: [String: [SessionEvent]] = [:]
    /// The server's agents, its default first.
    public private(set) var agents: [AgentInfo] = []
    /// Set when a session this client asked for arrives, so the UI can select it.
    public private(set) var lastCreatedSessionID: String?
    /// The most recent failed request, in the server's words.
    public var lastError: String?
    /// Hits for the latest search only; older, slower answers are dropped.
    public private(set) var searchHits: [SearchHit] = []
    /// MCP servers registered on the server, refreshed on connect and after every change.
    public private(set) var mcpServers: [McpServerSummary] = []
    /// True while the latest search is on its way.
    public private(set) var isSearching = false

    private let send: Sender
    private var pendingCreates: Set<String> = []
    private var latestSearch: String?

    public init(send: @escaping Sender) {
        self.send = send
    }

    /// Display name for an agent id; falls back to the id for agents the server no longer offers.
    public func agentName(_ id: String) -> String {
        agents.first { $0.id == id }?.name ?? id
    }

    public func session(_ id: String) -> SessionInfo? {
        sessions.first { $0.id == id }
    }

    public func transcript(for id: String) -> [TranscriptItem] {
        Transcript.build(events[id] ?? [])
    }

    /// Call after every (re)connect: refreshes the list, and with it every session's history.
    public func connected(agents: [AgentInfo]) async {
        self.agents = agents
        await request(.sessionList(id: Self.newID()))
        await request(.mcpList(id: Self.newID()))
    }

    public func create(agent: String, skills: [String] = [], mcpServers: [String] = []) async {
        let id = Self.newID()
        pendingCreates.insert(id)
        await request(.sessionCreate(id: id, agent: agent, skills: skills, mcpServers: mcpServers))
    }

    public func saveMcp(_ server: McpServerInput) async {
        await request(.mcpSave(id: Self.newID(), server: server))
    }

    public func deleteMcp(_ name: String) async {
        await request(.mcpDelete(id: Self.newID(), name: name))
    }

    public func prompt(_ sessionID: String, text: String, attachments: [String] = []) async {
        await request(.sessionPrompt(id: Self.newID(), sessionId: sessionID, text: text, attachments: attachments))
    }

    public func cancel(_ sessionID: String) async {
        await request(.sessionCancel(id: Self.newID(), sessionId: sessionID))
    }

    public func respond(_ sessionID: String, requestId: String, optionId: String) async {
        await request(.sessionPermission(id: Self.newID(), sessionId: sessionID, requestId: requestId, optionId: optionId))
    }

    public func rename(_ sessionID: String, title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await request(.sessionRename(id: Self.newID(), sessionId: sessionID, title: String(trimmed.prefix(120))))
    }

    public func setArchived(_ sessionID: String, _ archived: Bool) async {
        await request(.sessionArchive(id: Self.newID(), sessionId: sessionID, archived: archived))
    }

    public func search(_ query: String) async {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            latestSearch = nil
            searchHits = []
            isSearching = false
            return
        }
        let id = Self.newID()
        latestSearch = id
        isSearching = true
        await request(.sessionSearch(id: id, query: query))
    }

    /// When the session last saw activity: its newest event, else its creation.
    public func lastActivity(_ sessionID: String) -> String {
        events[sessionID]?.last?.at ?? session(sessionID)?.createdAt ?? ""
    }

    /// Sessions whose agent is blocked on the user; drives the Dock badge.
    public var waitingCount: Int {
        sessions.filter { $0.status == .waiting }.count
    }

    public func handle(_ message: ServerMessage) {
        switch message {
        case .sessionListResult(_, let list):
            sessions = list.sorted { $0.createdAt > $1.createdAt }
            for session in list { requestHistory(session.id) }
        case .sessionCreated(let requestID, let session):
            upsert(session)
            if events[session.id] == nil { events[session.id] = [] }
            if pendingCreates.remove(requestID) != nil { lastCreatedSessionID = session.id }
        case .sessionUpdated(let session):
            upsert(session)
        case .sessionHistoryResult(_, let sessionID, let history):
            events[sessionID] = history
        case .sessionEvent(let sessionID, let event):
            append(event, to: sessionID)
        case .mcpListResult(_, let servers):
            mcpServers = servers
        case .sessionSearchResult(let id, let hits) where id == latestSearch:
            searchHits = hits
            isSearching = false
        case .error(let code, let message, let id?):
            pendingCreates.remove(id)
            lastError = Self.describe(code: code, message: message)
        default:
            break
        }
    }

    /// Events must arrive in seq order without gaps; on a gap, reload the whole history.
    private func append(_ event: SessionEvent, to sessionID: String) {
        let last = events[sessionID]?.last?.seq ?? 0
        if event.seq == last + 1 {
            events[sessionID, default: []].append(event)
        } else if event.seq > last + 1 {
            requestHistory(sessionID)
        }
    }

    private func upsert(_ session: SessionInfo) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.insert(session, at: 0)
        }
    }

    private func requestHistory(_ sessionID: String) {
        Task { await request(.sessionHistory(id: Self.newID(), sessionId: sessionID)) }
    }

    private func request(_ message: ClientMessage) async {
        do {
            try await send(message)
        } catch {
            lastError = "Sunucuya gönderilemedi: \(error.localizedDescription)"
        }
    }

    private static func newID() -> String { UUID().uuidString }

    /// The server's error codes in the app's language; unknown codes keep the server's text.
    static func describe(code: String, message: String) -> String {
        switch code {
        case "session_busy": "Claude hâlâ önceki mesajı yanıtlıyor."
        case "session_unavailable": "Bu oturum şu anda mesaj kabul etmiyor."
        case "unknown_session": "Oturum sunucuda bulunamadı."
        case "unknown_agent": "Bu ajan sunucuda kurulu değil."
        case "unknown_request": "Bu izin isteği artık geçerli değil."
        default: message
        }
    }
}
