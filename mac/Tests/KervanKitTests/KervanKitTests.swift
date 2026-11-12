import Foundation
import Testing
@testable import KervanKit

@Suite struct ServerAddressTests {
    @Test(arguments: [
        ("kervan", "ws://kervan:7420/v1/ws"),
        ("  kervan:7500 ", "ws://kervan:7500/v1/ws"),
        ("ws://100.66.121.56", "ws://100.66.121.56:7420/v1/ws"),
        ("http://kervan:7420/health", "ws://kervan:7420/v1/ws"),
        ("https://kervan.example.ts.net", "wss://kervan.example.ts.net:7420/v1/ws"),
    ])
    func normalises(input: String, expected: String) {
        #expect(ServerAddress(input)?.url.absoluteString == expected)
    }

    @Test(arguments: ["", "   ", "ftp://kervan", "ws://"])
    func rejects(input: String) {
        #expect(ServerAddress(input) == nil)
    }

    @Test func exposesHost() {
        #expect(ServerAddress("kervan")?.host == "kervan")
    }
}

@Suite struct ProtocolTests {
    @Test func encodesHello() throws {
        let json = try ClientMessage.hello(client: PeerInfo(name: "Kervan for Mac", version: "0.1.0")).jsonString()
        #expect(json == #"{"client":{"name":"Kervan for Mac","version":"0.1.0"},"protocol":1,"type":"hello"}"#)
    }

    @Test func encodesPing() throws {
        #expect(try ClientMessage.ping(id: "p1").jsonString() == #"{"id":"p1","type":"ping"}"#)
    }

    @Test func decodesWelcome() throws {
        let message = try ServerMessage.decode(#"{"type":"welcome","protocol":1,"server":{"name":"kervan","version":"0.1.0"},"agents":["claude"]}"#)
        #expect(message == .welcome(protocolVersion: 1, server: PeerInfo(name: "kervan", version: "0.1.0"), agents: [AgentInfo(id: "claude", name: "claude")]))

        let named = try ServerMessage.decode(#"{"type":"welcome","protocol":1,"server":{"name":"kervan","version":"0.2.0"},"agents":["claude","codex"],"agentDetails":[{"id":"claude","name":"Claude Code"},{"id":"codex","name":"Codex"}]}"#)
        guard case .welcome(_, _, let agents) = named else { Issue.record("expected welcome"); return }
        #expect(agents.map(\.name) == ["Claude Code", "Codex"])
    }

    @Test func encodesSessionRequests() throws {
        #expect(try ClientMessage.sessionCreate(id: "r1", agent: "claude").jsonString() == #"{"agent":"claude","id":"r1","type":"session.create"}"#)
        #expect(
            try ClientMessage.sessionPrompt(id: "r2", sessionId: "s1", text: "selam").jsonString()
                == #"{"id":"r2","sessionId":"s1","text":"selam","type":"session.prompt"}"#
        )
    }

    @Test func decodesSessionEvents() throws {
        let message = try ServerMessage.decode(
            #"{"type":"session.event","sessionId":"s1","event":{"seq":3,"at":"t","kind":"tool_call","toolCallId":"t1","title":"Read a.txt","toolKind":"read","status":"pending"}}"#
        )
        #expect(message == .sessionEvent(sessionId: "s1", event: SessionEvent(seq: 3, at: "t", body: .toolCall(id: "t1", title: "Read a.txt", kind: "read", status: "pending"))))

        let unknown = try ServerMessage.decode(#"{"type":"session.event","sessionId":"s1","event":{"seq":4,"kind":"future_kind"}}"#)
        #expect(unknown == .sessionEvent(sessionId: "s1", event: SessionEvent(seq: 4, body: .unknown(kind: "future_kind"))))
    }

    @Test func decodesSessionInfoWithUnknownStatus() throws {
        let message = try ServerMessage.decode(
            #"{"type":"session.updated","session":{"id":"s1","agent":"claude","title":"T","status":"paused","createdAt":"2026"}}"#
        )
        #expect(message == .sessionUpdated(SessionInfo(id: "s1", agent: "claude", title: "T", status: .unknown, createdAt: "2026")))
    }

    @Test func decodesPongAndError() throws {
        #expect(try ServerMessage.decode(#"{"type":"pong","id":"p1"}"#) == .pong(id: "p1"))
        #expect(
            try ServerMessage.decode(#"{"type":"error","code":"bad_message","message":"nope"}"#)
                == .error(code: "bad_message", message: "nope", id: nil)
        )
    }

    @Test func toleratesUnknownTypes() throws {
        #expect(try ServerMessage.decode(#"{"type":"fleet.created","foo":1}"#) == .unknown(type: "fleet.created"))
    }
}

@Suite struct BackoffTests {
    @Test func growsThenCaps() {
        #expect((1...7).map(Backoff.delay(attempt:)) == [1, 2, 4, 8, 16, 30, 30])
    }

    @Test func onlyNetworkFailuresRetry() {
        #expect(ConnectionFailure.unreachable("x").isRetryable)
        #expect(!ConnectionFailure.unauthorized.isRetryable)
        #expect(!ConnectionFailure.unsupportedProtocol("x").isRetryable)
    }
}

@Suite struct TranscriptTests {
    private func event(_ seq: Int, _ body: SessionEvent.Body) -> SessionEvent { SessionEvent(seq: seq, body: body) }

    @Test func joinsChunksAndPatchesTools() {
        let items = Transcript.build([
            event(1, .userMessage("README'yi oku")),
            event(2, .agentMessageChunk("Okuyorum")),
            event(3, .agentMessageChunk("…")),
            event(4, .toolCall(id: "t1", title: "Read README.md", kind: "read", status: "pending")),
            event(5, .agentMessageChunk("Bitti.")),
            event(6, .toolCallUpdate(id: "t1", title: nil, status: "completed")),
            event(7, .turnEnd(stopReason: "end_turn")),
        ])
        #expect(items == [
            .user(id: 1, text: "README'yi oku"),
            .agent(id: 2, text: "Okuyorum…"),
            .tool(id: 4, toolCallId: "t1", title: "Read README.md", kind: "read", status: "completed"),
            .agent(id: 5, text: "Bitti."),
        ])
    }

    @Test func showsStopsAndErrors() {
        let items = Transcript.build([
            event(1, .turnEnd(stopReason: "cancelled")),
            event(2, .error("boom")),
            event(3, .unknown(kind: "plan")),
        ])
        #expect(items == [.stopped(id: 1, reason: "cancelled"), .error(id: 2, message: "boom")])
    }

    private let allow = PermissionChoice(optionId: "yes", name: "Allow", kind: "allow_once")
    private let reject = PermissionChoice(optionId: "no", name: "Reject", kind: "reject_once")

    private func request(_ seq: Int, _ requestId: String) -> SessionEvent {
        event(seq, .permissionRequest(requestId: requestId, title: "Run tests", toolKind: "execute", detail: "npm test", options: [allow, reject]))
    }

    @Test func keepsAPermissionOpenUntilResolved() {
        let items = Transcript.build([request(1, "p1")])
        #expect(items == [.permission(id: 1, PermissionPrompt(requestId: "p1", title: "Run tests", toolKind: "execute", detail: "npm test", options: [allow, reject]))])
    }

    @Test func foldsTheAnswerIntoItsRequest() {
        let items = Transcript.build([
            request(1, "p1"),
            request(2, "p2"),
            event(3, .permissionResolved(requestId: "p2", optionId: nil)),
            event(4, .permissionResolved(requestId: "p1", optionId: "yes")),
        ])
        guard case .permission(_, let first) = items[0], case .permission(_, let second) = items[1] else {
            Issue.record("expected two permission rows")
            return
        }
        #expect(items.count == 2)
        #expect(first.resolution == .chose(allow))
        #expect(second.resolution == .cancelled)
    }
}

@MainActor
@Suite struct SessionStoreTests {
    final class Outbox {
        var sent: [ClientMessage] = []
    }

    private func makeStore() -> (SessionStore, Outbox) {
        let outbox = Outbox()
        let store = SessionStore { outbox.sent.append($0) }
        return (store, outbox)
    }

    private let s1 = SessionInfo(id: "s1", agent: "claude", title: "Eski", status: .idle, createdAt: "2026-10-29T08:00:00Z")
    private let s2 = SessionInfo(id: "s2", agent: "claude", title: "Yeni", status: .idle, createdAt: "2026-10-29T09:00:00Z")

    @Test func listsNewestFirstAndLoadsHistory() async throws {
        let (store, outbox) = makeStore()
        store.handle(.sessionListResult(id: "r", sessions: [s1, s2]))
        #expect(store.sessions.map(\.id) == ["s2", "s1"])
        try await Task.sleep(for: .milliseconds(20))
        let historyFor = outbox.sent.compactMap { if case .sessionHistory(_, let id) = $0 { id } else { nil } }
        #expect(Set(historyFor) == ["s1", "s2"])
    }

    @Test func appendsInOrderAndReloadsOnGap() async throws {
        let (store, outbox) = makeStore()
        store.handle(.sessionHistoryResult(id: "r", sessionId: "s1", events: [SessionEvent(seq: 1, body: .userMessage("a"))]))
        store.handle(.sessionEvent(sessionId: "s1", event: SessionEvent(seq: 2, body: .agentMessageChunk("b"))))
        store.handle(.sessionEvent(sessionId: "s1", event: SessionEvent(seq: 2, body: .agentMessageChunk("b"))))
        #expect(store.events["s1"]?.map(\.seq) == [1, 2])

        store.handle(.sessionEvent(sessionId: "s1", event: SessionEvent(seq: 5, body: .agentMessageChunk("x"))))
        #expect(store.events["s1"]?.map(\.seq) == [1, 2])
        try await Task.sleep(for: .milliseconds(20))
        #expect(outbox.sent.contains { if case .sessionHistory(_, "s1") = $0 { true } else { false } })
    }

    @Test func selectsOnlySessionsItCreated() async {
        let (store, outbox) = makeStore()
        await store.create(agent: "claude")
        guard case .sessionCreate(let requestID, "claude", _, _, false, _, _, false, false, false)? = outbox.sent.last else {
            Issue.record("expected a session.create")
            return
        }
        store.handle(.sessionCreated(id: "someone-else", session: s1))
        #expect(store.lastCreatedSessionID == nil)
        store.handle(.sessionCreated(id: requestID, session: s2))
        #expect(store.lastCreatedSessionID == "s2")
        #expect(store.sessions.first?.id == "s2")
    }

    @Test func surfacesRequestErrors() {
        let (store, _) = makeStore()
        store.handle(.error(code: "session_busy", message: "the agent is still answering", id: "r9"))
        #expect(store.lastError == "The agent is still working on your last message; you can write when it's done.")
    }
}

@Suite struct PermissionProtocolTests {
    @Test func decodesARequestAndItsAnswer() throws {
        let request = try ServerMessage.decode(
            #"{"type":"session.event","sessionId":"s1","event":{"seq":5,"kind":"permission_request","requestId":"p1","title":"Run tests","toolKind":"execute","detail":"npm test","options":[{"optionId":"yes","name":"Allow","kind":"allow_once"}]}}"#
        )
        let choice = PermissionChoice(optionId: "yes", name: "Allow", kind: "allow_once")
        #expect(request == .sessionEvent(sessionId: "s1", event: SessionEvent(seq: 5, body: .permissionRequest(requestId: "p1", title: "Run tests", toolKind: "execute", detail: "npm test", options: [choice]))))
        #expect(choice.allows)

        let cancelled = try ServerMessage.decode(
            #"{"type":"session.event","sessionId":"s1","event":{"seq":6,"kind":"permission_resolved","requestId":"p1","outcome":"cancelled"}}"#
        )
        #expect(cancelled == .sessionEvent(sessionId: "s1", event: SessionEvent(seq: 6, body: .permissionResolved(requestId: "p1", optionId: nil))))
    }

    @Test func encodesTheAnswer() throws {
        #expect(
            try ClientMessage.sessionPermission(id: "r1", sessionId: "s1", requestId: "p1", optionId: "yes").jsonString()
                == #"{"id":"r1","optionId":"yes","requestId":"p1","sessionId":"s1","type":"session.permission"}"#
        )
    }

    @MainActor @Test func countsSessionsWaitingForTheUser() {
        let store = SessionStore { _ in }
        store.handle(.sessionListResult(id: "r", sessions: [
            SessionInfo(id: "a", agent: "claude", title: "A", status: .waiting, createdAt: "1"),
            SessionInfo(id: "b", agent: "claude", title: "B", status: .running, createdAt: "2"),
        ]))
        #expect(store.waitingCount == 1)
    }
}

@Suite struct RecoveryTests {
    @Test func showsNoticesAndInterruptedTurns() throws {
        let notice = try ServerMessage.decode(#"{"type":"session.event","sessionId":"s1","event":{"seq":7,"kind":"notice","text":"Ajan yeniden başlatıldı"}}"#)
        #expect(notice == .sessionEvent(sessionId: "s1", event: SessionEvent(seq: 7, body: .notice("Ajan yeniden başlatıldı"))))

        let items = Transcript.build([
            SessionEvent(seq: 1, body: .turnEnd(stopReason: "interrupted")),
            SessionEvent(seq: 2, body: .notice("Ajan yeniden başlatıldı")),
        ])
        #expect(items == [.stopped(id: 1, reason: "interrupted"), .notice(id: 2, text: "Ajan yeniden başlatıldı")])
    }
}

@Suite struct FileClientTests {
    private let client = FileClient(address: ServerAddress("kervan")!, token: "t")

    @Test func derivesTheHTTPOrigin() {
        #expect(ServerAddress("kervan")!.httpBase.absoluteString == "http://kervan:7420/")
        #expect(ServerAddress("wss://kervan.example.ts.net")!.httpBase.absoluteString == "https://kervan.example.ts.net:7420/")
    }

    @Test func encodesEachPathSegment() {
        #expect(client.url(sessionID: "s1").absoluteString == "http://kervan:7420/v1/sessions/s1/files")
        #expect(
            client.url(sessionID: "s1", path: "uploads/rapor şubat #1.pdf").absoluteString
                == "http://kervan:7420/v1/sessions/s1/files/uploads/rapor%20%C5%9Fubat%20%231.pdf"
        )
    }

    @Test func decodesAListing() throws {
        let json = #"{"entries":[{"path":"uploads","type":"dir","size":0,"modifiedAt":"t"},{"path":"uploads/a.txt","type":"file","size":12,"modifiedAt":"t"}],"truncated":false}"#
        let listing = try JSONDecoder().decode(WorkspaceListing.self, from: Data(json.utf8))
        #expect(listing.entries.map(\.depth) == [0, 1])
        #expect(listing.entries[1].name == "a.txt")
    }

    @Test func neverOverwritesALocalFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let taken = folder.appendingPathComponent("rapor.pdf")
        try Data().write(to: taken)
        #expect(FileClient.freeName(for: taken).lastPathComponent == "rapor 2.pdf")
    }
}

@Suite struct AttachmentProtocolTests {
    @Test func sendsAttachmentsOnlyWhenPresent() throws {
        #expect(try ClientMessage.sessionPrompt(id: "r", sessionId: "s", text: "t").jsonString() == #"{"id":"r","sessionId":"s","text":"t","type":"session.prompt"}"#)
        #expect(
            try ClientMessage.sessionPrompt(id: "r", sessionId: "s", text: "t", attachments: ["uploads/a.txt"]).jsonString()
                == #"{"attachments":["uploads\/a.txt"],"id":"r","sessionId":"s","text":"t","type":"session.prompt"}"#
        )
    }

    @Test func showsAttachmentsOnTheUserMessage() throws {
        let message = try ServerMessage.decode(#"{"type":"session.event","sessionId":"s","event":{"seq":1,"kind":"user_message","text":"oku","attachments":["uploads/a.txt"]}}"#)
        guard case .sessionEvent(_, let event) = message else { Issue.record("expected event"); return }
        #expect(Transcript.build([event]) == [.user(id: 1, text: "oku", attachments: ["uploads/a.txt"])])
    }
}

@Suite struct HistoryTests {
    private func session(_ id: String, archived: Bool = false) -> SessionInfo {
        SessionInfo(id: id, agent: "claude", title: id, status: .idle, createdAt: "2026-01-01T00:00:00Z", archived: archived)
    }

    @Test func groupsByLastActivityAndKeepsArchiveApart() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = try #require(SessionGroups.parse("2026-10-29T15:00:00.000Z"))
        let activity = [
            "today": "2026-10-29T09:00:00.000Z", "today2": "2026-10-29T14:00:00Z",
            "yesterday": "2026-10-28T23:59:00.000Z", "week": "2026-10-25T10:00:00.000Z",
            "old": "2026-09-01T10:00:00.000Z", "gone": "2026-10-29T12:00:00.000Z",
        ]
        let sessions = ["today", "yesterday", "week", "old", "today2"].map { session($0) } + [session("gone", archived: true)]
        let (active, archived) = SessionGroups.group(sessions, lastActivity: { activity[$0.id]! }, now: now, calendar: calendar)
        #expect(active.map(\.title) == ["Today", "Yesterday", "Last 7 days", "Older"])
        #expect(active[0].sessions.map(\.id) == ["today2", "today"])
        #expect(archived.map(\.id) == ["gone"])
    }

    @Test func splitsSnippetsIntoMatchedRuns() {
        let hit = SearchHit(sessionId: "s", seq: 2, role: .agent, snippet: "…karavan \u{1}rotası\u{2} hazır \u{1}ipek\u{2}")
        #expect(hit.parts.map(\.text) == ["…karavan ", "rotası", " hazır ", "ipek"])
        #expect(hit.parts.map(\.matched) == [false, true, false, true])
    }

    @Test func decodesSearchResultsAndArchivedSessions() throws {
        let message = try ServerMessage.decode(#"{"type":"session.search.result","id":"q","hits":[{"sessionId":"s","seq":1,"role":"user","snippet":"x"}]}"#)
        #expect(message == .sessionSearchResult(id: "q", hits: [SearchHit(sessionId: "s", seq: 1, role: .user, snippet: "x")]))
        let updated = try ServerMessage.decode(#"{"type":"session.updated","session":{"id":"s","agent":"claude","title":"T","status":"idle","createdAt":"c","archived":true}}"#)
        #expect(updated == .sessionUpdated(SessionInfo(id: "s", agent: "claude", title: "T", status: .idle, createdAt: "c", archived: true)))
    }

    @MainActor @Test func keepsOnlyTheLatestSearch() async {
        final class Box { var sent: [ClientMessage] = [] }
        let box = Box()
        let store = SessionStore { box.sent.append($0) }
        await store.search("ilk")
        await store.search("ikinci")
        let ids = box.sent.compactMap { if case .sessionSearch(let id, _) = $0 { id } else { nil } }
        store.handle(.sessionSearchResult(id: ids[0], hits: [SearchHit(sessionId: "s", seq: 1, role: .user, snippet: "eski")]))
        #expect(store.searchHits.isEmpty)
        store.handle(.sessionSearchResult(id: ids[1], hits: [SearchHit(sessionId: "s", seq: 2, role: .user, snippet: "yeni")]))
        #expect(store.searchHits.map(\.snippet) == ["yeni"])
        await store.search("  ")
        #expect(store.searchHits.isEmpty)
    }
}

@MainActor @Suite struct AgentNameTests {
    @Test func namesAgentsAndFallsBackToTheId() async {
        let store = SessionStore { _ in }
        await store.connected(agents: [AgentInfo(id: "codex", name: "Codex")])
        #expect(store.agentName("codex") == "Codex")
        #expect(store.agentName("gone") == "gone")
    }
}

@Suite struct SkillAndMcpTests {
    @Test func namesSkillsFromTheirFolder() {
        #expect(FileClient.skillName(for: URL(fileURLWithPath: "/x/Rapor Şablonu")) == "rapor-sablonu")
        #expect(FileClient.skillName(for: URL(fileURLWithPath: "/x/İstanbul_Notları v2")) == "istanbul-notlari-v2")
    }

    @Test func findsSkillFilesWithoutHiddenOnes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("templates"), withIntermediateDirectories: true)
        for path in ["SKILL.md", "templates/rapor.md", ".DS_Store"] {
            try Data("x".utf8).write(to: folder.appendingPathComponent(path))
        }
        #expect(Set(try FileClient.skillFiles(in: folder)) == ["SKILL.md", "templates/rapor.md"])
    }

    @Test func sendsNullToKeepAStoredSecret() throws {
        let input = McpServerInput(name: "github", transport: .stdio, command: "npx", args: [], env: ["GITHUB_TOKEN": nil, "EXTRA": "1"])
        let json = try ClientMessage.mcpSave(id: "r", server: input).jsonString()
        #expect(json.contains(#""GITHUB_TOKEN":null"#))
        #expect(json.contains(#""EXTRA":"1""#))
        #expect(!json.contains("headers"))
    }

    @Test func decodesTheMcpListAndSessionChoices() throws {
        let list = try ServerMessage.decode(#"{"type":"mcp.list.result","id":"r","servers":[{"name":"github","transport":"stdio","command":"npx","args":[],"envKeys":["GITHUB_TOKEN"],"headerKeys":[]}]}"#)
        #expect(list == .mcpListResult(id: "r", servers: [McpServerSummary(name: "github", transport: .stdio, command: "npx", args: [], envKeys: ["GITHUB_TOKEN"])]))
        let created = try ClientMessage.sessionCreate(id: "c", agent: "claude", skills: ["rapor"], mcpServers: ["github"]).jsonString()
        #expect(created == #"{"agent":"claude","id":"c","mcpServers":["github"],"skills":["rapor"],"type":"session.create"}"#)
    }
}

@MainActor @Suite struct AgentCatalogTests {
    @Test func encodesAgentWithKeptSecret() throws {
        let json = try ClientMessage.agentSave(id: "r", agent: AgentInput(id: "gemini", name: "Gemini", command: "builtin", env: ["GEMINI_API_KEY": nil])).jsonString()
        #expect(json.contains(#""GEMINI_API_KEY":null"#))
        #expect(json.contains(#""node":"local""#))
    }

    @Test func tracksSavesAndBroadcasts() async {
        final class Box { var sent: [ClientMessage] = [] }
        let box = Box()
        let store = SessionStore { box.sent.append($0) }
        let save = Task { await store.saveAgent(AgentInput(id: "x", name: "X", command: "x")) }
        try? await Task.sleep(for: .milliseconds(50))
        guard case .agentSave(let id, _)? = box.sent.last else { Issue.record("expected agent.save"); return }
        store.handle(.error(code: "bad_message", message: "the agent didn't start: boom", id: id))
        await save.value
        #expect(store.agentSaveError == "the agent didn't start: boom")

        let list = try? ServerMessage.decode(#"{"type":"agent.list.result","id":"l","agents":[{"id":"claude","name":"Claude Code","command":"/x","args":[],"envKeys":[],"node":"local","source":"builtin","available":true}],"nodes":["local"]}"#)
        store.handle(list!)
        #expect(store.agentConfigs.map(\.id) == ["claude"])

        store.handle(try! ServerMessage.decode(#"{"type":"agents.updated","agents":["claude","x"],"agentDetails":[{"id":"claude","name":"Claude Code"},{"id":"x","name":"X"}]}"#))
        #expect(store.agents.map(\.name) == ["Claude Code", "X"])
    }
}

@Suite struct ArgumentTests {
    @Test func splitsLikeAShell() {
        #expect(splitArguments(#"-y  @mcp/server "/Users/enes/untitled folder/a.ts" 'it''s' a\ b"#) == ["-y", "@mcp/server", "/Users/enes/untitled folder/a.ts", "its", "a b"])
        #expect(splitArguments(#"--flag "" x"#) == ["--flag", "", "x"])
        #expect(splitArguments("   ") == [])
    }

    @Test func joinRoundTrips() {
        let args = ["acp", "/a b/c.ts", #"say "hi""#, ""]
        #expect(splitArguments(joinArguments(args)) == args)
    }
}

@MainActor @Suite struct TeamTests {
    @Test func tracksTeamsAndSelectsTheFirstMemberOfOursOnly() async {
        final class Box { var sent: [ClientMessage] = [] }
        let box = Box()
        let store = SessionStore { box.sent.append($0) }
        await store.createTeam(title: "Web", roles: ["yazar", "inceleyici"])
        guard case .teamCreate(let id, "Web", ["yazar", "inceleyici"])? = box.sent.last else { Issue.record("expected team.create"); return }

        store.handle(.teamUpdated(TeamInfo(id: "other", title: "Başka", createdAt: "1", sessionIds: ["x"])))
        #expect(store.lastCreatedSessionID == nil)
        store.handle(.teamCreated(id: id, team: TeamInfo(id: "t", title: "Web", createdAt: "2", sessionIds: ["s1", "s2"])))
        #expect(store.lastCreatedSessionID == "s1")
        #expect(store.teams.map(\.id) == ["t", "other"])
    }

    @Test func decodesMembersAndRoles() throws {
        let updated = try ServerMessage.decode(#"{"type":"session.updated","session":{"id":"s","agent":"claude","title":"Yazar","status":"idle","createdAt":"c","archived":false,"teamId":"t","role":"Yazar"}}"#)
        guard case .sessionUpdated(let info) = updated else { Issue.record("expected session.updated"); return }
        #expect([info.teamId, info.role] == ["t", "Yazar"])
        let roles = try ServerMessage.decode(#"{"type":"role.list.result","id":"r","roles":[{"id":"yazar","name":"Yazar","agent":"claude","instructions":"Yaz.","skills":[],"mcpServers":[]}]}"#)
        #expect(roles == .roleListResult(id: "r", roles: [Role(id: "yazar", name: "Yazar", agent: "claude", instructions: "Yaz.")]))
    }
}

@MainActor @Suite struct HelperTests {
    @Test func asksForTheOrchestrationToolsOnlyWhenWanted() throws {
        #expect(try ClientMessage.sessionCreate(id: "r", agent: "claude").jsonString() == #"{"agent":"claude","id":"r","type":"session.create"}"#)
        #expect(
            try ClientMessage.sessionCreate(id: "r", agent: "claude", orchestrate: true).jsonString()
                == #"{"agent":"claude","id":"r","orchestrate":true,"type":"session.create"}"#
        )
    }

    @Test func listsHelpersUnderTheirLeadOldestFirst() {
        let store = SessionStore { _ in }
        let lead = SessionInfo(id: "lead", agent: "claude", title: "Şef", status: .running, createdAt: "1", orchestrate: true)
        store.handle(.sessionUpdated(lead))
        store.handle(.sessionUpdated(SessionInfo(id: "h2", agent: "codex", title: "B", status: .idle, createdAt: "3", parentId: "lead")))
        store.handle(.sessionUpdated(SessionInfo(id: "h1", agent: "codex", title: "A", status: .idle, createdAt: "2", parentId: "lead")))
        #expect(store.helpers(of: "lead").map(\.id) == ["h1", "h2"])
        #expect(store.helpers(of: "h1").isEmpty)
    }

    @Test func marksMessagesFromTheLead() throws {
        let message = try ServerMessage.decode(#"{"type":"session.event","sessionId":"h","event":{"seq":1,"kind":"user_message","text":"testleri yaz","from":"lead"}}"#)
        guard case .sessionEvent(_, let event) = message else { Issue.record("expected event"); return }
        #expect(Transcript.build([event]) == [.user(id: 1, text: "testleri yaz", from: "lead")])
    }

    @Test func decodesHelperFieldsAndLeadRoles() throws {
        let updated = try ServerMessage.decode(#"{"type":"session.updated","session":{"id":"h","agent":"codex","title":"A","status":"idle","createdAt":"c","archived":false,"parentId":"lead"}}"#)
        guard case .sessionUpdated(let info) = updated else { Issue.record("expected session.updated"); return }
        #expect(info.parentId == "lead")
        #expect(info.orchestrate == false)
        let role = try JSONDecoder().decode(Role.self, from: Data(#"{"id":"sef","name":"Şef","agent":"claude","instructions":"","skills":[],"mcpServers":[],"lead":true}"#.utf8))
        #expect(role.lead)
        #expect(try JSONDecoder().decode(Role.self, from: Data(#"{"id":"x","name":"X","agent":"claude"}"#.utf8)).lead == false)
    }
}

@Suite struct CrewTests {
    private func info(_ id: String, at: String, team: String? = nil, parent: String? = nil, lead: Bool = false) -> SessionInfo {
        SessionInfo(id: id, agent: "claude", title: id, status: .idle, createdAt: at, teamId: team, parentId: parent, orchestrate: lead)
    }

    @Test func gathersALeadAndItsHelpersFromAnyOfThem() {
        let sessions = [info("h2", at: "3", parent: "lead"), info("lead", at: "1", lead: true), info("h1", at: "2", parent: "lead"), info("solo", at: "4")]
        let crew = Crew.of("h2", sessions: sessions, teams: [])
        #expect(crew?.kind == .lead("lead"))
        #expect(crew?.members.map(\.id) == ["lead", "h1", "h2"])
        #expect(Crew.of("solo", sessions: sessions, teams: []) == nil, "a session working alone has no team view")
    }

    @Test func listsTeamMembersWithEachLeadsHelpersAfterIt() {
        let team = TeamInfo(id: "t", title: "Web", createdAt: "0", sessionIds: ["a", "b"])
        let sessions = [info("a", at: "1", team: "t", lead: true), info("b", at: "2", team: "t"), info("ah", at: "3", team: "t", parent: "a")]
        let crew = Crew.of("b", sessions: sessions, teams: [team])
        #expect(crew?.title == "Web")
        #expect(crew?.members.map(\.id) == ["a", "ah", "b"])
    }

    @Test func buildsTheFlowFromHandOffsRepliesAndOpenApprovals() {
        let members = [info("lead", at: "1", lead: true), info("h", at: "2", parent: "lead")]
        let events: [String: [SessionEvent]] = [
            "lead": [SessionEvent(seq: 1, at: "t1", body: .userMessage("iki yardımcı başlat"))],
            "h": [
                SessionEvent(seq: 1, at: "t2", body: .userMessage("hello.py yaz", from: "lead")),
                SessionEvent(seq: 2, at: "t3", body: .agentMessageChunk("Yazdım, ")),
                SessionEvent(seq: 3, at: "t3", body: .agentMessageChunk("çalışıyor.")),
                SessionEvent(seq: 4, at: "t4", body: .turnEnd(stopReason: "end_turn")),
                SessionEvent(seq: 5, at: "t5", body: .permissionRequest(requestId: "r1", title: "Write a", toolKind: "edit", detail: nil, options: [])),
                SessionEvent(seq: 6, at: "t6", body: .permissionResolved(requestId: "r1", optionId: "yes")),
                SessionEvent(seq: 7, at: "t7", body: .permissionRequest(requestId: "r2", title: "Run tests", toolKind: "execute", detail: nil, options: [])),
            ],
        ]
        let flow = Flow.build(members, events: events)
        #expect(flow.map(\.kind) == [.userWrote, .assigned(from: "lead"), .replied, .waiting])
        #expect(flow.map(\.text) == ["iki yardımcı başlat", "hello.py yaz", "Yazdım, çalışıyor.", "Run tests"])
        #expect(Flow.build(members, events: events, limit: 2).map(\.seq) == [4, 7])
    }
}

@MainActor @Suite struct BudgetTests {
    @Test func sendsABudgetOnlyForLeads() throws {
        #expect(
            try ClientMessage.sessionCreate(id: "r", agent: "claude", orchestrate: true, budgetUsd: 5).jsonString()
                == #"{"agent":"claude","budgetUsd":5,"id":"r","orchestrate":true,"type":"session.create"}"#
        )
        #expect(try ClientMessage.sessionCreate(id: "r", agent: "claude", budgetUsd: 5).jsonString() == #"{"agent":"claude","id":"r","type":"session.create"}"#)
    }

    @Test func decodesUsageBranchAndBudget() throws {
        let updated = try ServerMessage.decode(
            #"{"type":"session.updated","session":{"id":"h","agent":"claude","title":"A","status":"idle","createdAt":"c","archived":false,"parentId":"l","branch":"kervan/a-1","usage":{"contextUsed":10,"contextSize":100,"costUsd":0.12}}}"#
        )
        guard case .sessionUpdated(let info) = updated else { Issue.record("expected session.updated"); return }
        #expect(info.branch == "kervan/a-1")
        #expect(info.usage == SessionUsage(contextUsed: 10, contextSize: 100, costUsd: 0.12))
    }

    @Test func addsUpWhatALeadAndItsHelpersSpent() {
        let store = SessionStore { _ in }
        #expect(store.crewCost("lead") == nil)
        store.handle(.sessionUpdated(SessionInfo(id: "lead", agent: "claude", title: "Şef", status: .idle, createdAt: "1", orchestrate: true, budgetUsd: 2,
                                                 usage: SessionUsage(contextUsed: 1, contextSize: 10, costUsd: 0.5))))
        store.handle(.sessionUpdated(SessionInfo(id: "h", agent: "claude", title: "A", status: .idle, createdAt: "2", parentId: "lead",
                                                 usage: SessionUsage(contextUsed: 1, contextSize: 10, costUsd: 0.25))))
        store.handle(.sessionUpdated(SessionInfo(id: "g", agent: "gemini", title: "B", status: .idle, createdAt: "3", parentId: "lead")))
        #expect(store.crewCost("lead") == 0.75)
    }
}

@MainActor @Suite struct AlertTests {
    private func info(_ status: SessionStatus, parent: String? = nil, error: String? = nil) -> SessionInfo {
        SessionInfo(id: "s", agent: "claude", title: "Sürüm", status: status, createdAt: "1", parentId: parent, error: error)
    }
    private let ask = SessionEvent(seq: 2, body: .permissionRequest(requestId: "r", title: "Run npm test", toolKind: "execute", detail: nil, options: []))
    private let reply = [SessionEvent(seq: 1, body: .userMessage("yap")), SessionEvent(seq: 2, body: .agentMessageChunk("Bitti, testler geçti.\nAyrıntı"))]

    @Test func asksForApprovalsAndEndedTurnsAndErrors() {
        let waiting = SessionAlert.on(info(.waiting), from: .running, events: [ask], agentName: "Claude Code")
        #expect(waiting == SessionAlert(sessionID: "s", kind: .waiting, title: "Waiting for your approval: Sürüm", body: "Claude Code wants to: Run npm test"))
        #expect(SessionAlert.on(info(.idle), from: .running, events: reply, agentName: "Claude Code")?.body == "Bitti, testler geçti.")
        #expect(SessionAlert.on(info(.error, error: "agent exited"), from: .running, events: [], agentName: "x")?.kind == .failed)
    }

    @Test func staysQuietOtherwise() {
        #expect(SessionAlert.on(info(.idle), from: nil, events: reply, agentName: "x") == nil, "lists loaded on connect")
        #expect(SessionAlert.on(info(.idle), from: .starting, events: [], agentName: "x") == nil, "a session that just started")
        #expect(SessionAlert.on(info(.idle, parent: "lead"), from: .running, events: reply, agentName: "x") == nil, "a helper answers its lead")
        #expect(SessionAlert.on(info(.waiting, parent: "lead"), from: .running, events: [ask], agentName: "x")?.kind == .waiting, "but its approvals need the user")
    }

    @Test func storeRaisesAlertsOnlyForLiveChanges() {
        let store = SessionStore { _ in }
        var alerts: [SessionAlert.Kind] = []
        store.onAlert = { alerts.append($0.kind) }
        store.handle(.sessionListResult(id: "l", sessions: [info(.running)]))
        store.handle(.sessionUpdated(info(.running)))
        store.handle(.sessionEvent(sessionId: "s", event: SessionEvent(seq: 1, body: .permissionRequest(requestId: "r", title: "Edit", toolKind: "edit", detail: nil, options: []))))
        store.handle(.sessionUpdated(info(.waiting)))
        #expect(alerts == [.waiting])
    }
}

@Suite struct TerminalAgentTests {
    @Test func readsTheTerminalFlagAndSendsTheProtocol() throws {
        let welcome = try ServerMessage.decode(#"{"type":"agents.updated","agents":["aider"],"agentDetails":[{"id":"aider","name":"Aider","terminal":true},{"id":"claude","name":"Claude"}]}"#)
        #expect(welcome == .agentsUpdated([AgentInfo(id: "aider", name: "Aider", terminal: true), AgentInfo(id: "claude", name: "Claude")]))
        let input = AgentInput(id: "aider", name: "Aider", command: "aider", protocol: "pty", quietMs: 1500)
        let json = try String(decoding: JSONEncoder().encode(input), as: UTF8.self)
        #expect(json.contains(#""protocol":"pty""#) && json.contains(#""quietMs":1500"#))
    }
}

@Suite struct ConfigOptionTests {
    @Test func decodesSettingsAndAsksForAChange() throws {
        let updated = try ServerMessage.decode(
            #"{"type":"session.updated","session":{"id":"s","agent":"claude","title":"A","status":"idle","createdAt":"c","archived":false,"config":[{"id":"mode","name":"Mod","category":"mode","value":"default","choices":[{"value":"default","name":"Varsayılan"}]},{"id":"model","name":"Model","category":"model","value":"opus","choices":[{"value":"opus","name":"Opus"},{"value":"sonnet","name":"Sonnet","description":"Hızlı"}]}]}}"#
        )
        guard case .sessionUpdated(let info) = updated else { Issue.record("expected session.updated"); return }
        #expect(ConfigOption.ordered(info.config).map(\.id) == ["model", "mode"], "model first")
        #expect(info.config[1].current?.name == "Opus")
        #expect(
            try ClientMessage.sessionConfig(id: "r", sessionId: "s", configId: "model", value: "sonnet").jsonString()
                == #"{"configId":"model","id":"r","sessionId":"s","type":"session.config","value":"sonnet"}"#
        )
    }

    @Test func decodesAutoApproveAndAsksForAChange() throws {
        let updated = try ServerMessage.decode(
            #"{"type":"session.updated","session":{"id":"s","agent":"claude","title":"A","status":"idle","createdAt":"c","archived":false,"autoApprove":true}}"#
        )
        guard case .sessionUpdated(let info) = updated else { Issue.record("expected session.updated"); return }
        #expect(info.autoApprove == true)
        #expect(
            try ClientMessage.sessionCreate(id: "c", agent: "claude", autoApprove: true).jsonString()
                == #"{"agent":"claude","autoApprove":true,"id":"c","type":"session.create"}"#
        )
        #expect(
            try ClientMessage.sessionAutoApprove(id: "r", sessionId: "s", enabled: true).jsonString()
                == #"{"enabled":true,"id":"r","sessionId":"s","type":"session.autoApprove"}"#
        )
    }
}

@MainActor @Suite struct NodeTests {
    @Test func groupsAgentsByTheMachineTheyRunOn() throws {
        let updated = try ServerMessage.decode(#"{"type":"agents.updated","agents":[],"agentDetails":[{"id":"gpu-claude","name":"Claude","node":"gpu","online":false}]}"#)
        #expect(updated == .agentsUpdated([AgentInfo(id: "gpu-claude", name: "Claude", node: "gpu", online: false)]))

        let here = AgentInfo(id: "claude", name: "Claude")
        let away = AgentInfo(id: "gpu-claude", name: "Claude", node: "gpu", online: false)
        let places = AgentPlace.all(agents: [away, here], nodes: [NodeInfo(name: "gpu", connected: false), NodeInfo(name: "bos", connected: true)])
        #expect(places.map(\.id) == [AgentPlace.serverID, "bos", "gpu"])
        #expect(places[0].agents == [here] && places[0].online)
        #expect(places[1].agents.isEmpty && places[1].online)
        #expect(places[2].agents == [away] && !places[2].online)
        #expect(away.isAway && !here.isAway)
        // An older server doesn't say, and a browser-style list has no node records.
        #expect(AgentPlace.all(agents: [AgentInfo(id: "x", name: "X", node: "kutu")], nodes: [])[1].online)
    }

    @Test func offersProjectWorkOnlyWhereAProjectCopyCanGo() throws {
        let message = try ServerMessage.decode(#"{"type":"nodes.updated","nodes":[{"name":"yeni","connected":true,"features":["orchestra","projects"]},{"name":"eski","connected":true,"features":["orchestra"]},{"name":"onceki","connected":false}]}"#)
        guard case .nodesUpdated(let nodes, _) = message else { Issue.record("not nodes.updated"); return }
        #expect(nodes.map(\.canWorkOnProjects) == [true, false, false])

        let agents = [
            AgentInfo(id: "claude", name: "Claude"),
            AgentInfo(id: "yeni-claude", name: "Claude", node: "yeni"),
            AgentInfo(id: "eski-claude", name: "Claude", node: "eski"),
        ]
        // The server always; a node only when it said it can hold a copy, and a node that never said can't.
        #expect(AgentPlace.forProjects(agents: agents, nodes: nodes).map(\.id) == [AgentPlace.serverID, "yeni"])
        #expect(AgentPlace.canWorkOnProjects(agent: "claude", agents: agents, nodes: nodes))
        #expect(AgentPlace.canWorkOnProjects(agent: "yeni-claude", agents: agents, nodes: nodes))
        #expect(!AgentPlace.canWorkOnProjects(agent: "eski-claude", agents: agents, nodes: nodes))
        #expect(!AgentPlace.canWorkOnProjects(agent: "yeni-claude", agents: agents, nodes: []), "a node the app knows nothing about")

        // One line says where the work happens and where it goes; the server needs none.
        let places = AgentPlace.all(agents: agents, nodes: nodes)
        #expect(places[0].projectCopyNote == nil)
        let note = try #require(places.first { $0.node == "yeni" }?.projectCopyNote)
        #expect(note.contains("yeni"))
    }

    @Test func namesTheNodeAndTracksWhichNodesAreConnected() throws {
        let store = SessionStore { _ in }
        store.handle(.agentsUpdated([AgentInfo(id: "claude", name: "Claude Code"), AgentInfo(id: "gpu-claude", name: "Claude Code", node: "gpu")]))
        #expect(store.agentName("gpu-claude") == "Claude Code (gpu)")
        #expect(store.agentName("claude") == "Claude Code")

        let message = try ServerMessage.decode(#"{"type":"nodes.updated","nodes":[{"name":"gpu","connected":false,"version":"0.1.0","lastSeen":"t"}]}"#)
        store.handle(message)
        #expect(store.nodeInfos == [NodeInfo(name: "gpu", connected: false, version: "0.1.0", lastSeen: "t")])
        store.handle(.error(code: "node_offline", message: "node 'gpu' is offline", id: "x"))
        #expect(store.lastError?.hasPrefix("The machine (node) this agent runs on isn't connected") == true)
    }
}

@MainActor @Suite struct ResumeTests {
    @Test func offersToContinueOnlyTheLastTurnARestartCutOff() async {
        let cut = [SessionEvent(seq: 1, body: .userMessage("yap")), SessionEvent(seq: 2, body: .turnEnd(stopReason: "interrupted"))]
        #expect(Transcript.resumable(Transcript.build(cut)) == 2)
        #expect(Transcript.resumable(Transcript.build(cut + [SessionEvent(seq: 3, body: .userMessage("sonra"))])) == nil)
        #expect(Transcript.resumable(Transcript.build([SessionEvent(seq: 1, body: .turnEnd(stopReason: "cancelled"))])) == nil)

        final class Box { var sent: [ClientMessage] = [] }
        let box = Box()
        let store = SessionStore { box.sent.append($0) }
        await store.resume("s")
        guard case .sessionPrompt(_, "s", let text, _)? = box.sent.last else { Issue.record("expected a prompt"); return }
        #expect(text == Transcript.resumePrompt)
    }
}

@MainActor @Suite struct NodeSetupTests {
    @Test func buildsTheInstallCommandForTheChosenHubAddress() {
        let address = ServerAddress("kervan")!
        #expect(NodeSetup.hub(of: address) == "kervan:7420")
        #expect(NodeSetup.command(address: address, code: "abc") == "curl -fsSL 'http://kervan:7420/v1/node/install?code=abc' | sudo bash")
        #expect(NodeSetup.command(hub: "192.168.1.21:7420", code: "abc") == "curl -fsSL 'http://192.168.1.21:7420/v1/node/install?code=abc' | sudo bash")
        #expect(NodeSetup.command(address: ServerAddress("wss://hub.example:443")!, code: "x").hasPrefix("curl -fsSL 'https://hub.example:443/"))
        let ssh = NodeSetup.sshArguments(user: "ubuntu", host: "192.168.1.27", hub: "192.168.1.21:7420", code: "abc")
        #expect(ssh.contains("BatchMode=yes"), "never waits for a password")
        #expect(ssh.last == "bash -o pipefail -c \"curl -fsSL 'http://192.168.1.21:7420/v1/node/install?code=abc' | sudo -n bash\"")
        #expect(NodeSetup.firewallCommand(network: "192.168.1.0/24", port: 7420) == "sudo ufw allow from 192.168.1.0/24 to any port 7420 proto tcp")
    }

    @Test func explainsCommonSSHFailures() {
        #expect(NodeSetup.explain(output: "sudo: a password is required").contains("sudo needs a password"))
        #expect(NodeSetup.explain(output: "ubuntu@gpu: Permission denied (publickey).").contains("ssh-copy-id"))
        #expect(NodeSetup.explain(output: "ssh: Could not resolve hostname gpu").contains("Couldn't reach the machine"))
        #expect(NodeSetup.explain(output: "ssh: connect to host 192.168.1.28 port 22: No route to host").contains("Local Network"))
        #expect(NodeSetup.explain(output: "curl: (6) Could not resolve host: kervan").contains("local IP"))
        #expect(NodeSetup.explain(output: "curl: (7) Failed to connect to 192.168.1.21 port 7420").contains("firewall"))
    }

    @Test func keepsOnlyTheInviteItAskedFor() async {
        final class Box { var sent: [ClientMessage] = [] }
        let box = Box()
        let store = SessionStore { box.sent.append($0) }
        await store.inviteNode("gpu")
        guard case .nodeInvite(let id, "gpu")? = box.sent.last else { Issue.record("expected node.invite"); return }
        store.handle(.nodeInvited(id: "other", name: "x", code: "c0", expiresAt: "t"))
        #expect(store.nodeInvite == nil)
        store.handle(.nodeInvited(id: id, name: "gpu", code: "c1", expiresAt: "t"))
        #expect(store.nodeInvite?.code == "c1")
    }
}

@Suite struct LanHubTests {
    @Test func suggestsTheHubsLanAddressForAMachineOnTheSameNetwork() {
        let addresses = [
            HubAddress(address: "100.66.121.56:7420", kind: .tailscale),
            HubAddress(address: "192.168.1.21:7420", kind: .lan, network: "192.168.1.0/24"),
        ]
        #expect(NodeSetup.lanHub(for: "192.168.1.27", in: addresses)?.address == "192.168.1.21:7420")
        #expect(NodeSetup.lanHub(for: "10.0.0.5", in: addresses) == nil, "another network")
        #expect(NodeSetup.lanHub(for: "gpu-box", in: addresses) == nil, "a name, not an address")
    }
}

@Suite struct InstallProgressTests {
    @Test func followsTheScriptsMarkers() {
        #expect(InstallStep.reached(in: "") == .connecting)
        #expect(InstallStep.reached(in: "==> Kervan: hub kontrol ediliyor (http://x)\n") == .checkingHub)
        let output = """
        ==> Kervan: hub kontrol ediliyor (http://192.168.1.21:7420)
        ==> paketler
        ==> Node.js 24
        ==> kullanıcı ve klasörler
        ==> Kervan kodu
        added 134 packages in 9s
        """
        #expect(InstallStep.reached(in: output) == .files)
        #expect(InstallStep.reached(in: output + "\n==> hub'a 'gpu' olarak katılınıyor\n==> servis\n") == .service)
        #expect(InstallStep.reached(in: "npm warn: packages\n") == .connecting, "only ==> lines count")
    }
}

@Suite struct NodeHubChoiceTests {
    let addresses = [
        HubAddress(address: "100.66.121.56:7420", kind: .tailscale),
        HubAddress(address: "192.168.1.40:7420", kind: .lan, network: "192.168.1.0/24"),
    ]

    @Test func followsTheHubWhenItsAddressChanges() {
        #expect(NodeHubChoice.resolve("", appHub: "kervan:7420", addresses: addresses) == "kervan:7420")
        #expect(NodeHubChoice.resolve("lan", appHub: "kervan:7420", addresses: addresses) == "192.168.1.40:7420", "today's LAN IP, not a saved one")
        #expect(NodeHubChoice.resolve("tailscale", appHub: "kervan:7420", addresses: addresses) == "100.66.121.56:7420")
        #expect(NodeHubChoice.resolve("lan", appHub: "kervan:7420", addresses: []) == "kervan:7420", "no LAN address: fall back to the app's")
        #expect(NodeHubChoice.resolve("10.0.0.9:7420", appHub: "kervan:7420", addresses: addresses) == "10.0.0.9:7420")
    }

    @Test func turnsASavedIpIntoItsKind() {
        #expect(NodeHubChoice.migrate("192.168.1.40:7420", addresses: addresses) == "lan")
        #expect(NodeHubChoice.migrate("100.66.121.56:7420", addresses: addresses) == "tailscale")
        #expect(NodeHubChoice.migrate("10.0.0.9:7420", addresses: addresses) == "10.0.0.9:7420")
        #expect(NodeHubChoice.repairCommand(hub: "192.168.1.40:7420").contains("KERVAN_HUB_URL=ws://192.168.1.40:7420"))
    }
}

@Suite struct ServerFactsTests {
    @Test func readsWhetherTheServerCanBuild() throws {
        let says = try JSONDecoder().decode(PeerInfo.self, from: Data(#"{"name":"kervan","version":"0.3.27","containers":false}"#.utf8))
        #expect(says.containers == false)
        // A server from before this says nothing, which is not the same as "no": the app offers nothing then.
        let older = try JSONDecoder().decode(PeerInfo.self, from: Data(#"{"name":"kervan","version":"0.3.24"}"#.utf8))
        #expect(older.containers == nil)
    }
}

@Suite struct HandOffTests {
    @Test func asksTheLeadToStartTheHelperSomewhere() {
        let here = HandOff.message(agentName: "Codex", node: nil, task: "  Write the release notes  ")
        #expect(here.contains("`Codex`"))
        #expect(here.contains(L("on this server", "bu sunucudaki")))
        #expect(here.hasSuffix("Write the release notes"))   // trimmed, and last so the task reads as the task
        let there = HandOff.message(agentName: "goose", node: "studio", task: "Run the benchmark")
        #expect(there.contains(L("on studio", "studio üzerinde")))
        // The lead must hand it over rather than do it, or the machine the user picked is ignored.
        #expect(there.contains(L("don't do the task yourself", "görevi kendin yapma")))
    }
}

@Suite struct HubSetupTests {
    @Test func makesAStrongTokenAndPasswordFreeCommands() {
        let token = HubSetup.makeToken()
        #expect(token.count == 64 && token.allSatisfy(\.isHexDigit))
        #expect(HubSetup.makeToken() != token)
        #expect(HubSetup.uploadArguments(user: "ubuntu", host: "192.168.1.30").contains("BatchMode=yes"))
        #expect(HubSetup.runArguments(user: "ubuntu", host: "h", access: .tailscale).last == "sudo -n env ACCESS=tailscale bash /tmp/kervan-setup/hub-setup.sh")
        #expect(HubSetup.terminalCommand(user: "ubuntu", host: "h", access: .tailscale) == "ssh -t ubuntu@h \"sudo env ACCESS=tailscale bash /tmp/kervan-setup/hub-setup.sh\"")
        // Copies the key; makes one first only when the Mac has none, so an existing key is never replaced.
        let copy = HubSetup.copyKeyCommand(user: "ubuntu", host: "kervan-1.example.ts.net")
        #expect(copy.hasSuffix("ssh-copy-id ubuntu@kervan-1.example.ts.net"))
        #expect(copy.hasPrefix("test -e ~/.ssh/id_ed25519.pub -o -e ~/.ssh/id_rsa.pub -o -e ~/.ssh/id_ecdsa.pub || {"))
        // Setting up Podman is its own mode, so an ordinary update never installs it unasked.
        #expect(HubSetup.runArguments(user: "ubuntu", host: "h", access: .podman).last == "sudo -n env ACCESS=podman bash /tmp/kervan-setup/hub-setup.sh")
        // Asks about the token rather than the folder: the script leaves the folder behind and takes the token with it.
        #expect(HubSetup.tokenCheckArguments(user: "ubuntu", host: "h").last == "test -e /tmp/kervan-setup/token")
    }

    @Test func followsTheSetupScript() {
        #expect(HubSetupStep.reached(in: "") == .uploading)
        let output = "==> paketler\n==> Node.js 24\n==> kullanıcı ve klasörler\n==> Kervan kodu\n==> ayarlar\n==> Tailscale\n==> güvenlik duvarı\n"
        #expect(HubSetupStep.reached(in: output) == .firewall)
        #expect(HubSetupStep.reached(in: output + "==> servis\n==> Tailscale girişi\n") == .tailscaleLogin)
        #expect(HubSetupStep.reached(in: output + "==> servis\n==> hazır\n") == .ready)
        #expect(HubSetup.tailscaleLoginURL(in: "To authenticate, visit:\n\n\thttps://login.tailscale.com/a/1b2c3d\n")?.absoluteString == "https://login.tailscale.com/a/1b2c3d")
    }
}

@Suite struct AgentSignInTests {
    @Test func keysBecomeTheBuiltinAdapterWithItsEnvironment() throws {
        let claude = try #require(AgentSignIn.of("claude")?.input(key: "  sk-ant-api03-abc \n"))
        #expect(claude.command == "builtin")
        #expect(claude.env == ["ANTHROPIC_API_KEY": "sk-ant-api03-abc"])
        #expect(claude.authMethod == nil)

        let subscription = try #require(AgentSignIn.of("claude")?.input(key: "sk-ant-oat01-xyz"))
        #expect(subscription.env == ["CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-oat01-xyz"])

        let codex = try #require(AgentSignIn.of("codex")?.input(key: "sk-proj-1"))
        #expect(codex.env == ["OPENAI_API_KEY": "sk-proj-1"])
        #expect(codex.authMethod == "api-key")
        #expect(AgentSignIn.of("gemini")?.input(key: "AIza1")?.authMethod == "gemini-api-key")
    }

    @Test func anEmptyKeyIsNothingToSave() {
        #expect(AgentSignIn.of("codex")?.input(key: "   ") == nil)
        #expect(AgentSignIn.of("yerel") == nil)
    }
}

@Suite struct SSHKeyTests {
    @Test func tellsALockedKeyFromAMissingOne() {
        // Keys, none opening without a passphrase, an empty agent: unlocking is what helps, not ssh-copy-id.
        #expect(SSHKeys.lockedKey(present: ["id_ed25519"], unlocked: [], agentHasKeys: false) == "id_ed25519")
        #expect(SSHKeys.lockedKey(present: ["id_rsa", "id_ed25519"], unlocked: [], agentHasKeys: false) == "id_ed25519", "the one ssh tries first")
        // The agent already holds a key, or one key opens by itself: ssh can sign, so the refusal is about the server.
        #expect(SSHKeys.lockedKey(present: ["id_ed25519"], unlocked: [], agentHasKeys: true) == nil)
        #expect(SSHKeys.lockedKey(present: ["id_ed25519", "id_rsa"], unlocked: ["id_rsa"], agentHasKeys: false) == nil)
        // No key at all: copying one (made first) is the answer.
        #expect(SSHKeys.lockedKey(present: [], unlocked: [], agentHasKeys: false) == nil)
    }

    @Test func findsNothingLockedWithoutKeysOrWithAKeyThatOpens() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("kervan-ssh-\(UUID().uuidString)")
        let folder = home.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(SSHKeys.probe(home: home) == nil)

        let keygen = Process()
        keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        keygen.arguments = ["-q", "-t", "ed25519", "-N", "", "-f", folder.appendingPathComponent("id_ed25519").path]
        try keygen.run()
        keygen.waitUntilExit()
        #expect(SSHKeys.probe(home: home) == nil, "a key without a passphrase opens by itself")
    }

    @Test func theUnlockCommandAddsTheKeychainSettingsOnce() throws {
        let command = SSHKeys.unlockCommand(key: "id_ed25519")
        #expect(command.hasPrefix("ssh-add --apple-use-keychain ~/.ssh/id_ed25519 && "))
        // Runs in zsh, Terminal's shell, with the passphrase step left out: the settings go in once, however often it runs.
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("kervan-ssh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let script = command.replacingOccurrences(of: "ssh-add --apple-use-keychain ~/.ssh/id_ed25519", with: "true")
        for _ in 0..<2 {
            let shell = Process()
            shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
            shell.arguments = ["-f", "-c", script]
            shell.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
            try shell.run()
            shell.waitUntilExit()
            #expect(shell.terminationStatus == 0)
        }
        let config = try String(contentsOf: home.appendingPathComponent(".ssh/config"), encoding: .utf8)
        #expect(config == "\nHost *\n  UseKeychain yes\n  AddKeysToAgent yes\n")
    }
}
