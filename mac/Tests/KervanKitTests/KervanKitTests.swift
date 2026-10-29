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
        #expect(message == .welcome(protocolVersion: 1, server: PeerInfo(name: "kervan", version: "0.1.0"), agents: ["claude"]))
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

        let unknown = try ServerMessage.decode(#"{"type":"session.event","sessionId":"s1","event":{"seq":4,"kind":"plan"}}"#)
        #expect(unknown == .sessionEvent(sessionId: "s1", event: SessionEvent(seq: 4, body: .unknown(kind: "plan"))))
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
        #expect(try ServerMessage.decode(#"{"type":"team.created","foo":1}"#) == .unknown(type: "team.created"))
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
        guard case .sessionCreate(let requestID, "claude")? = outbox.sent.last else {
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
        #expect(store.lastError == "Claude hâlâ önceki mesajı yanıtlıyor.")
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
        #expect(active.map(\.title) == ["Bugün", "Dün", "Son 7 gün", "Daha eski"])
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
