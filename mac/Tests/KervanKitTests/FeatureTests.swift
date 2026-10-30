import Foundation
import Testing
@testable import KervanKit

@Suite struct FeatureProtocolTests {
    @Test func decodesDiffsPlansCommandsAndCheckpoints() throws {
        let tool = try ServerMessage.decode(#"{"type":"session.event","sessionId":"s","event":{"seq":2,"at":"t","kind":"tool_call","toolCallId":"t1","title":"Write a.txt","toolKind":"edit","status":"completed","diffs":[{"path":"a.txt","newText":"hi"}]}}"#)
        #expect(tool == .sessionEvent(sessionId: "s", event: SessionEvent(seq: 2, at: "t", body: .toolCall(
            id: "t1", title: "Write a.txt", kind: "edit", status: "completed", diffs: [FileDiff(path: "a.txt", newText: "hi")]
        ))))
        let events = try [
            #"{"seq":1,"kind":"user_message","text":"go"}"#,
            #"{"seq":2,"kind":"checkpoint","commit":"abc","messageSeq":1}"#,
            #"{"seq":3,"kind":"commands","commands":[{"name":"review","description":"Review"}]}"#,
            #"{"seq":4,"kind":"plan","entries":[{"content":"Read","status":"completed","priority":"high"},{"content":"Fix","status":"in_progress","priority":"high"}]}"#,
        ].map { try JSONDecoder().decode(SessionEvent.self, from: Data($0.utf8)) }
        #expect(Transcript.plan(events)?.map(\.status) == ["completed", "in_progress"])
        #expect(Transcript.commands(events) == [SlashCommand(name: "review", description: "Review")])
        #expect(Transcript.checkpoints(events) == [1])
        // Plans, commands and checkpoints are not rows.
        #expect(Transcript.build(events).count == 1)
        // A new message ends the old plan.
        let next = events + [SessionEvent(seq: 5, body: .userMessage("again"))]
        #expect(Transcript.plan(next) == nil)
    }

    @Test func toolUpdatesKeepTheirDiffs() {
        let diff = FileDiff(path: "a", oldText: "1", newText: "2")
        let items = Transcript.build([
            SessionEvent(seq: 1, body: .toolCall(id: "t", title: "Edit a", kind: "edit", status: "pending", diffs: [diff])),
            SessionEvent(seq: 2, body: .toolCallUpdate(id: "t", title: nil, status: "completed")),
        ])
        #expect(items == [.tool(id: 1, toolCallId: "t", title: "Edit a", kind: "edit", status: "completed", diffs: [diff])])
    }

    @Test func decodesResults() throws {
        let changes = try ServerMessage.decode(#"{"type":"session.changes.result","id":"r","sessionId":"s","changes":{"files":[{"path":"a.txt","status":"added","additions":1,"deletions":0}],"patch":"","truncated":false,"sinceSeq":1,"repository":true,"branch":"main"}}"#)
        guard case .sessionChangesResult(_, "s", let set) = changes else {
            Issue.record("not a changes result")
            return
        }
        #expect(set.files.first?.status == .added)
        #expect(set.repository && set.branch == "main")
        #expect(changes.requestID == "r")

        let schedules = try ServerMessage.decode(#"{"type":"schedules.updated","schedules":[{"id":"x","title":"T","agent":"claude","prompt":"p","when":{"kind":"daily","time":"09:00","weekdays":[1,2,3,4,5]},"timeZone":"Europe/Istanbul","enabled":true,"createdAt":"c"}]}"#)
        guard case .schedulesUpdated(let list) = schedules else {
            Issue.record("not a schedules update")
            return
        }
        #expect(list.first?.when.label == "Hafta içi 09:00")

        #expect(try ServerMessage.decode(#"{"type":"ok","id":"q"}"#).requestID == "q")
        #expect(try ServerMessage.decode(#"{"type":"error","code":"bad_message","message":"m","id":"e"}"#).requestID == "e")
        #expect(ClientMessage.portList(id: "p").requestID == "p")
        #expect(ClientMessage.hello(client: PeerInfo(name: "a", version: "1")).requestID == nil)
    }

    @Test func encodesNewRequests() throws {
        #expect(try ClientMessage.sessionRevert(id: "1", sessionId: "s", seq: 3, paths: ["a"]).jsonString()
            == #"{"id":"1","paths":["a"],"seq":3,"sessionId":"s","type":"session.revert"}"#)
        #expect(try ClientMessage.sessionChanges(id: "1", sessionId: "s", sinceTurn: true).jsonString()
            == #"{"id":"1","sessionId":"s","since":"turn","type":"session.changes"}"#)
        let schedule = ScheduleInput(title: "T", agent: "a", prompt: "p", when: .interval(minutes: 30), timeZone: "UTC")
        let json = try ClientMessage.scheduleSave(id: "1", schedule: schedule).jsonString()
        #expect(json.contains(#""kind":"interval""#) && json.contains(#""minutes":30"#))
        #expect(try ClientMessage.sessionCreate(id: "1", agent: "a", projectId: "p").jsonString().contains(#""projectId":"p""#))
    }

    @Test func labelsSchedules() {
        #expect(ScheduleWhen.interval(minutes: 120).label == "2 saatte bir")
        #expect(ScheduleWhen.interval(minutes: 15).label == "15 dakikada bir")
        #expect(ScheduleWhen.daily(time: "07:30", weekdays: Array(1...7)).label == "Her gün 07:30")
        #expect(ScheduleWhen.daily(time: "10:00", weekdays: [1, 3]).label == "Pzt, Çar 10:00")
    }
}

@Suite struct DiffTests {
    @Test func comparesLinesWithContext() {
        let old = (1...20).map { "line \($0)" }.joined(separator: "\n")
        let new = old.replacingOccurrences(of: "line 10\n", with: "line ten\n")
        let lines = DiffLine.compare(old, new)
        #expect(lines.filter { $0.kind == .removed }.map(\.text) == ["line 10"])
        #expect(lines.filter { $0.kind == .added }.map(\.text) == ["line ten"])
        // Three lines of context each side, the rest folded.
        #expect(lines.filter { $0.kind == .context }.count == 6)
        #expect(lines.first?.kind == .gap && lines.last?.kind == .gap)
        #expect(DiffLine.compare("same", "same").isEmpty)
        #expect(DiffLine.compare("", "new file").map(\.kind) == [.added])
    }

    @Test func splitsAndParsesPatches() {
        let patch = """
        diff --git a/a.txt b/a.txt
        index 1..2 100644
        --- a/a.txt
        +++ b/a.txt
        @@ -1,2 +1,2 @@
         keep
        -old
        +new
        diff --git a/b.txt b/b.txt
        new file mode 100644
        @@ -0,0 +1 @@
        +bee
        """
        let set = ChangeSet(files: [], patch: patch)
        #expect(Set(set.patches.keys) == ["a.txt", "b.txt"])
        #expect(DiffLine.parse(patch: set.patches["a.txt"]!).map(\.kind) == [.context, .removed, .added])
        #expect(DiffLine.parse(patch: set.patches["b.txt"]!).map(\.text) == ["bee"])
    }
}

@Suite struct ComposerTests {
    @Test func suggestsSlashCommands() {
        let commands = [SlashCommand(name: "review", description: ""), SlashCommand(name: "explain", description: "")]
        #expect(Transcript.suggestions(for: "/", in: commands)?.count == 2)
        #expect(Transcript.suggestions(for: "/re", in: commands)?.map(\.name) == ["review"])
        #expect(Transcript.suggestions(for: "/review now", in: commands) == nil)
        #expect(Transcript.suggestions(for: "hello", in: commands) == nil)
        #expect(Transcript.suggestions(for: "/zzz", in: commands) == nil)
    }

    @Test func findsMentions() {
        #expect(Transcript.mention(in: "look at @src/ma") == "src/ma")
        #expect(Transcript.mention(in: "@") == "")
        #expect(Transcript.mention(in: "mail me at a@b.com") == nil)
        #expect(Transcript.mention(in: "@a.txt done") == nil)
    }
}

@MainActor
@Suite struct StoreRequestTests {
    @Test func awaitsTheAnswerToItsRequest() async {
        var sent: [ClientMessage] = []
        let store = SessionStore { sent.append($0) }
        async let failure = store.revert("s", toBefore: 3)
        while sent.isEmpty { await Task.yield() }
        store.handle(.error(code: "session_busy", message: "busy", id: sent[0].requestID))
        #expect(await failure == SessionStore.describe(code: "session_busy", message: "busy"))
        // An awaited error doesn't also show as the general banner.
        #expect(store.lastError == nil)

        async let ok = store.commit("s", message: "m")
        while sent.count < 2 { await Task.yield() }
        store.handle(.ok(id: sent[1].requestID!))
        #expect(await ok == nil)
    }

    @Test func keepsTerminalOutputPerSession() {
        let store = SessionStore { _ in }
        store.handle(.terminalOpened(id: "r", terminalId: "t", sessionId: "s", backlog: "$ "))
        store.handle(.terminalOutput(terminalId: "t", data: "hi\n"))
        #expect(store.terminals["s"]?.output == "$ hi\n")
        store.handle(.terminalExited(terminalId: "t"))
        #expect(store.terminals["s"]?.exited == true)
    }
}
