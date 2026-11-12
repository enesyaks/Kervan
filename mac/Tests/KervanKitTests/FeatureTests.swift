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
        #expect(list.first?.when.label == "Weekdays 09:00")

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
        #expect(ScheduleWhen.interval(minutes: 120).label == "Every 2 h")
        #expect(ScheduleWhen.interval(minutes: 15).label == "Every 15 min")
        #expect(ScheduleWhen.daily(time: "07:30", weekdays: Array(1...7)).label == "Every day 07:30")
        #expect(ScheduleWhen.daily(time: "10:00", weekdays: [1, 3]).label == "Mon, Wed 10:00")
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

@Suite struct SetupOutputTests {
    @Test func followsTheEnglishSetupScript() {
        let output = "==> packages\n==> Node.js 24\n==> user and folders\n==> Kervan code\n==> settings\n==> Tailscale\n==> firewall\n"
        #expect(HubSetupStep.reached(in: output) == .firewall)
        #expect(HubSetupStep.reached(in: output + "==> service\n==> Tailscale sign-in\n") == .tailscaleLogin)
        #expect(HubSetupStep.reached(in: output + "==> service\n==> ready\n") == .ready)
        #expect(InstallStep.reached(in: "==> Kervan: checking the hub (http://x)\n==> packages\n==> joining the hub as 'gpu'\n") == .joining)
    }
}

@Suite struct UpdateTests {
    @Test func comparesVersions() {
        #expect(SemanticVersion("0.2.0")! < SemanticVersion("v0.10.0")!)
        #expect(SemanticVersion("1.0")! == SemanticVersion("1.0.0")!)
        #expect(!(SemanticVersion("0.2.1")! < SemanticVersion("0.2.0")!))
        #expect(SemanticVersion("0.3.0-beta.1")!.description == "0.3.0")
        #expect(SemanticVersion("next") == nil)
    }

    @Test func readsTheLatestRelease() throws {
        let json = #"""
        {"tag_name":"v0.3.0","body":"Notes","html_url":"https://github.com/enesyaks/Kervan/releases/tag/v0.3.0","draft":false,"prerelease":false,
         "assets":[{"name":"Kervan-0.3.0-macOS.zip","browser_download_url":"https://example.com/k.zip"},
                   {"name":"Kervan-0.3.0-macOS.zip.sha256","browser_download_url":"https://example.com/k.zip.sha256"}]}
        """#
        let release = try #require(AppRelease.parse(Data(json.utf8)))
        #expect(release.version == "0.3.0")
        #expect(release.checksum?.absoluteString == "https://example.com/k.zip.sha256")
        #expect(release.isNewer(than: "0.2.0"))
        #expect(!release.isNewer(than: "0.3.0"))
        #expect(AppRelease.parse(Data(#"{"tag_name":"v1","html_url":"https://x.y","assets":[]}"#.utf8)) == nil)
        let digest = String(repeating: "ab", count: 32)
        #expect(AppRelease.digest(inChecksumFile: "\(digest)  Kervan-0.3.0-macOS.zip\n") == digest)
        #expect(AppRelease.digest(inChecksumFile: "not a digest") == nil)
    }

    @Test func keepsTheVersionsInStep() throws {
        // mac/Tests/KervanKitTests/FeatureTests.swift → repository root
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: root.appendingPathComponent("mac/Resources/Info.plist")), format: nil) as? [String: Any]
        #expect(plist?["CFBundleShortVersionString"] as? String == KervanVersion.current)
        let server = try String(contentsOf: root.appendingPathComponent("server/src/version.ts"), encoding: .utf8)
        #expect(server.contains("\"\(KervanVersion.current)\""))
    }

    @Test func updatesAHubWithoutTouchingItsSettings() {
        #expect(HubSetup.runArguments(user: "ubuntu", host: "kervan", access: .update).last == "sudo -n env ACCESS=update bash /tmp/kervan-setup/hub-setup.sh")
    }
}

@Suite struct ReportTests {
    @Test func redactsSecrets() {
        #expect(Redact.text("ANTHROPIC_API_KEY=sk-ant-abcdefghijk") == "ANTHROPIC_API_KEY=…")
        #expect(Redact.text("Bearer 25d3e6141117cbb29e47c47fc151382a9376c63f74422893") == "Bearer …")
        #expect(Redact.text("key AIzaSyA1234567890abcdefghijklmno") == "key AIza…")
        #expect(Redact.text("plain text") == "plain text")
    }

    @Test func buildsAShortEnoughIssueLink() throws {
        let server = Diagnostics(
            version: "0.2.0", node: "v24.1.0", os: "linux", uptimeSec: 600,
            agents: [.init(id: "claude", available: true, signedIn: false, node: "local")],
            nodes: [], sessions: ["idle": 3],
            logs: (1...400).map { "{\"level\":\"warn\",\"msg\":\"line \($0) token=abc\"}" }
        )
        var report = BugReport.make(app: "0.2.0", macOS: "15.5", language: "English UI", connection: "Connected", server: server, errors: ["agent crashed"])
        report.title = "Terminal stays empty"
        #expect(report.versions.contains("server 0.2.0"))
        #expect(report.logs.contains("claude=ok, not signed in"))
        #expect(!report.logs.contains("token=abc"))
        let url = report.issueURL.absoluteString
        #expect(url.count <= BugReport.maxURLLength)
        #expect(url.contains("template=bug.yml"))
        // The newest lines survive the cut.
        #expect(url.contains("line%20400") || url.contains("line+400"))
    }
}

@Suite struct PullRequestTests {
    @Test func requestLeavesOutAnEmptyBody() throws {
        let plain = try ClientMessage.sessionPullRequest(id: "r", sessionId: "s", title: "Fix it", body: "").jsonString()
        #expect(plain.contains(#""type":"session.pullRequest""#))
        #expect(plain.contains(#""title":"Fix it""#))
        #expect(!plain.contains("body"))
        let described = try ClientMessage.sessionPullRequest(id: "r", sessionId: "s", title: "Fix it", body: "Why").jsonString()
        #expect(described.contains(#""body":"Why""#))
    }

    @Test func answerCarriesTheLinkWhenThereIsOne() throws {
        let opened = try ServerMessage.decode(#"{"type":"session.pullRequest.result","id":"r","sessionId":"s","pullRequest":{"branch":"kervan/fix-1","base":"main","url":"https://github.com/a/b/pull/7","created":true}}"#)
        guard case .sessionPullRequestResult(_, _, let pr) = opened else { Issue.record("not a pull request result"); return }
        #expect(pr.created && pr.url?.absoluteString == "https://github.com/a/b/pull/7")
        #expect(opened.requestID == "r")
        let pushed = try ServerMessage.decode(#"{"type":"session.pullRequest.result","id":"r","sessionId":"s","pullRequest":{"branch":"b","base":"main","created":false}}"#)
        guard case .sessionPullRequestResult(_, _, let bare) = pushed else { Issue.record("not a pull request result"); return }
        #expect(bare.url == nil && !bare.created)
    }
}

@Suite struct WebAccessTests {
    @Test func requestsSayWhatTheyChange() throws {
        #expect(try ClientMessage.webEnable(id: "r", enabled: true).jsonString().contains(#""enabled":true"#))
        #expect(try ClientMessage.webRevoke(id: "r", deviceId: "d1").jsonString().contains(#""deviceId":"d1""#))
        #expect(try ClientMessage.webPair(id: "r").jsonString().contains(#""type":"web.pair""#))
    }

    @Test func statusAndCodeDecode() throws {
        let status = try ServerMessage.decode(#"{"type":"web.status.result","id":"r","web":{"enabled":true,"devices":[{"id":"d1","name":"iPhone · Safari","createdAt":"2026-10-30T12:00:00Z"}]}}"#)
        guard case .webStatusResult(_, let web) = status else { Issue.record("not a status"); return }
        #expect(web.enabled && web.devices.first?.name == "iPhone · Safari" && web.devices.first?.lastSeenAt == nil)
        let paired = try ServerMessage.decode(#"{"type":"web.paired","id":"p","code":"ABCD-EFGH","expiresAt":"2026-10-30T12:10:00Z"}"#)
        guard case .webPaired(let id, let code, _) = paired else { Issue.record("not a pairing"); return }
        #expect(id == "p" && code == "ABCD-EFGH")
    }
}

@Suite struct GitHubTests {
    @Test func codeAndUpdatesDecode() throws {
        let code = try ServerMessage.decode(#"{"type":"github.code","id":"g","code":"AB12-CD34","url":"https://github.com/login/device"}"#)
        guard case .githubCode(let id, let value, let url) = code else { Issue.record("not a code"); return }
        #expect(id == "g" && value == "AB12-CD34" && url.host() == "github.com")
        #expect(code.requestID == "g")
        let done = try ServerMessage.decode(#"{"type":"github.updated","github":{"available":true,"signedIn":true,"signingIn":false,"account":"enesyaks"}}"#)
        guard case .githubUpdated(let status, let error) = done else { Issue.record("not an update"); return }
        #expect(status.account == "enesyaks" && status.signedIn && error == nil)
        #expect(try ClientMessage.githubConnect(id: "c").jsonString().contains(#""type":"github.connect""#))
    }
}

@Suite struct WorktreeTests {
    @Test func sharedAndRemovalAreSentOnlyWhenAsked() throws {
        let own = try ClientMessage.sessionCreate(id: "c", agent: "claude", projectId: "p").jsonString()
        #expect(own.contains(#""projectId":"p""#) && !own.contains("shared"))
        #expect(try ClientMessage.sessionCreate(id: "c", agent: "claude", projectId: "p", shared: true).jsonString().contains(#""shared":true"#))
        let plain: String = try ClientMessage.sessionArchive(id: "a", sessionId: "s", archived: true).jsonString()
        #expect(!plain.contains("removeWorktree"))
        #expect(try ClientMessage.sessionArchive(id: "a", sessionId: "s", archived: true, removeWorktree: true).jsonString().contains(#""removeWorktree":true"#))
    }
}

@MainActor @Suite struct TakeoverTests {
    @Test func sendsTheAgentOnlyWhenOneIsChosen() throws {
        let chosen = try ClientMessage.sessionTakeover(id: "t", sessionId: "s", agent: "claude").jsonString()
        #expect(chosen.contains(#""type":"session.takeover""#) && chosen.contains(#""agent":"claude""#))
        #expect(try !ClientMessage.sessionTakeover(id: "t", sessionId: "s", agent: nil).jsonString().contains("agent"))
    }

    @Test func offersToContinueOnTheServerOnlyForANodesProjectSession() {
        let store = SessionStore { _ in }
        store.handle(.agentsUpdated([
            AgentInfo(id: "claude", name: "Claude"),
            AgentInfo(id: "shell", name: "Shell", terminal: true),
            AgentInfo(id: "mac-claude", name: "Claude", node: "mac", online: false),
        ]))
        var session = SessionInfo(id: "s", agent: "mac-claude", title: "T", status: .idle, createdAt: "2026")
        #expect(!store.canContinueOnServer(session), "no project: there is nothing on the server to continue from")
        session.projectId = "p"
        session.branch = "kervan/t-12345678"
        #expect(store.canContinueOnServer(session))
        #expect(store.projectNode(of: session) == "mac", "its Changes panel offers the branch's pull request")
        session.agent = "claude"
        #expect(!store.canContinueOnServer(session), "already on the server")
        // A terminal agent can't be told the conversation, so it isn't offered.
        #expect(store.takeoverAgents.map(\.id) == ["claude"])
    }
}

@Suite struct BoardTests {
    @Test func cardsDecodeAndMovesEncode() throws {
        let board = try ServerMessage.decode(#"{"type":"board.updated","projectId":"p","cards":[{"id":"c","projectId":"p","title":"T","prompt":"Do it","agent":"claude","column":"needs","sessionId":"s","prompted":true,"createdAt":"a","updatedAt":"b"}]}"#)
        guard case .boardUpdated(let project, let cards) = board else { Issue.record("not a board"); return }
        #expect(project == "p" && cards.first?.column == .needs && cards.first?.sessionId == "s")
        let move: String = try ClientMessage.cardMove(id: "m", cardId: "c", column: .working).jsonString()
        #expect(move.contains(#""column":"working""#) && move.contains(#""type":"card.move""#))
    }

    @Test func cardsCarryTheirModelQuestionAndItsAnswerEncodes() throws {
        let board = try ServerMessage.decode(#"{"type":"board.updated","projectId":"p","cards":[{"id":"c","projectId":"p","title":"T","prompt":"Do it","agent":"claude","column":"working","modelChoice":{"model":"Haiku 5.5","defaultModel":"Opus 5.5","size":"small","waitSeconds":15},"createdAt":"a","updatedAt":"b"}]}"#)
        guard case .boardUpdated(_, let cards) = board else { Issue.record("not a board"); return }
        #expect(cards.first?.modelChoice?.model == "Haiku 5.5" && cards.first?.modelChoice?.waitSeconds == 15)
        let answer: String = try ClientMessage.cardModel(id: "m", cardId: "c", useDefault: true).jsonString()
        #expect(answer.contains(#""useDefault":true"#) && answer.contains(#""type":"card.model""#))
    }
}

@Suite struct PhoneAlertTests {
    @Test func secretsAreKeptUnlessReplacedOrRemoved() throws {
        let events = AlertSettings.Events(approval: true, finished: false, error: true)
        let keep: String = try ClientMessage.alertsSave(id: "a", alerts: AlertInput(enabled: true, events: events, ntfyServer: "https://ntfy.sh", ntfyTopic: "kervan-x")).jsonString()
        #expect(keep.contains(#""token":null"#), "a null token keeps the stored one")
        #expect(!keep.contains("webhook"), "no webhook field keeps the stored address")
        let off: String = try ClientMessage.alertsSave(id: "a", alerts: AlertInput(enabled: false, events: events, ntfyServer: "", ntfyTopic: "", webhook: "")).jsonString()
        #expect(off.contains(#""ntfy":"""#) && off.contains(#""webhook":"""#), "empty strings remove them")
        let settings = try ServerMessage.decode(#"{"type":"alerts.result","id":"a","alerts":{"enabled":true,"events":{"approval":true,"finished":false,"error":true},"ntfy":{"server":"https://ntfy.sh","topic":"kervan-x","tokenSet":true},"webhookSet":false}}"#)
        guard case .alertsResult(_, let value) = settings else { Issue.record("not alerts"); return }
        #expect(value.ntfy?.tokenSet == true && !value.events.finished)
    }
}

@Suite struct ReviewTests {
    @Test func reviewRequestAndLinkDecode() throws {
        let request: String = try ClientMessage.sessionReview(id: "r", sessionId: "s", agent: "gemini").jsonString()
        #expect(request.contains(#""type":"session.review""#) && request.contains(#""agent":"gemini""#))
        let info = try JSONDecoder().decode(SessionInfo.self, from: Data(#"{"id":"v","agent":"gemini","title":"Review: X","status":"idle","createdAt":"c","reviewOf":"s"}"#.utf8))
        #expect(info.reviewOf == "s")
    }
}

@Suite struct SplitTests {
    @Test func splitIsSentAndRestingRead() throws {
        let create: String = try ClientMessage.sessionCreate(id: "c", agent: "claude", orchestrate: true, split: true).jsonString()
        #expect(create.contains(#""split":true"#) && create.contains(#""orchestrate":true"#))
        let plain: String = try ClientMessage.sessionCreate(id: "c", agent: "claude").jsonString()
        #expect(!plain.contains("split"))
        let helper = try JSONDecoder().decode(SessionInfo.self, from: Data(#"{"id":"h","agent":"fake","title":"H","status":"idle","createdAt":"c","parentId":"l","resting":true}"#.utf8))
        #expect(helper.resting == true)
    }
}

@Suite struct ProjectMapTests {
    @Test func aProjectDecodesWithAndWithoutAMap() throws {
        let plain = try ServerMessage.decode(#"{"type":"projects.updated","projects":[{"id":"p","name":"n","path":"/w","instructions":"","createdAt":"t"}]}"#)
        guard case .projectsUpdated(let before) = plain else { Issue.record("not a project list"); return }
        #expect(before.first?.map == nil)
        let mapped = try ServerMessage.decode(#"{"type":"project.list.result","id":"r","projects":[{"id":"p","name":"n","path":"/w","instructions":"","createdAt":"t","map":{"status":"ready","agent":"claude","commit":"abc1234def","updatedAt":"u","sessionId":"s"}}]}"#)
        guard case .projectListResult(_, let after) = mapped else { Issue.record("not a project list"); return }
        #expect(after.first?.map == ProjectMapInfo(status: .ready, agent: "claude", commit: "abc1234def", updatedAt: "u", sessionId: "s"))
    }

    @Test func mapRequestsEncodeAndTheTextLandsInTheStore() throws {
        let build: String = try ClientMessage.projectMap(id: "b", projectId: "p", agent: "claude").jsonString()
        #expect(build.contains(#""type":"project.map""#) && build.contains(#""projectId":"p""#) && build.contains(#""agent":"claude""#))
        let get: String = try ClientMessage.projectMapGet(id: "g", projectId: "p").jsonString()
        #expect(get.contains(#""type":"project.map.get""#) && get.contains(#""projectId":"p""#))
        #expect(try ClientMessage.projectSave(id: "s", project: ProjectInput(name: "n", mapAgent: "claude")).jsonString().contains(#""mapAgent":"claude""#))
        let unmapped: String = try ClientMessage.projectSave(id: "s", project: ProjectInput(name: "n")).jsonString()
        #expect(!unmapped.contains("mapAgent"))

        let result = try ServerMessage.decode(##"{"type":"project.map.result","id":"g","projectId":"p","text":"# Map"}"##)
        guard case .projectMapResult(let id, let project, let text) = result else { Issue.record("not a map"); return }
        #expect(id == "g" && project == "p" && text == "# Map")
    }
}

@Suite struct ProjectPMTests {
    @Test func warnsWithoutAPMOrWhenItsRoleIsGone() {
        let pm = Role(id: "pm", name: "PM", agent: "claude", lead: true)
        let none = ProjectInfo(id: "p", name: "n", path: "/w")
        #expect(none.pmWarning(roles: [pm])?.contains("no PM") == true)
        let set = ProjectInfo(id: "p", name: "n", path: "/w", pm: ProjectPM(roleId: "pm"))
        #expect(set.pmWarning(roles: [pm]) == nil)
        #expect(set.pmWarning(roles: [])?.contains("was deleted") == true)
    }

    @Test func aPMRoleTakesTheFirstFreeID() {
        #expect(Role.pmTemplate(agent: "claude", taken: []).id == "pm")
        let next = Role.pmTemplate(agent: "claude", taken: ["pm", "pm-2"])
        #expect(next.id == "pm-3" && next.lead && next.agent == "claude" && next.skills.isEmpty)
    }

    @Test func setsAndRemovesThePM() throws {
        let set = try ClientMessage.projectPM(id: "a", projectId: "p", pm: ProjectPM(roleId: "pm", autoPickup: false)).jsonString()
        #expect(set.contains(#""type":"project.pm""#) && set.contains(#""roleId":"pm""#) && set.contains(#""autoPickup":false"#))
        #expect(try ClientMessage.projectPM(id: "a", projectId: "p", pm: nil).jsonString().contains(#""pm":null"#))
        let decoded = try JSONDecoder().decode(ProjectInfo.self, from: Data(#"{"id":"p","name":"n","path":"/w","instructions":"","createdAt":"t","pm":{"roleId":"pm","autoPickup":true,"startOwnCases":false}}"#.utf8))
        #expect(decoded.pm == ProjectPM(roleId: "pm"))
    }
}

@Suite struct PMCardTests {
    @Test func readsThePMsPlanAndSendsDirectOnlyWhenAsked() throws {
        let card = try JSONDecoder().decode(CardInfo.self, from: Data(#"{"id":"c","projectId":"p","title":"T","prompt":"x","agent":"claude","column":"working","sessionId":"s","createdAt":"t","updatedAt":"t","pm":true,"plan":"1. Yaz"}"#.utf8))
        #expect(card.pm == true && card.plan == "1. Yaz" && card.direct == nil && card.error == nil)
        // An older server's card has none of it.
        let old = try JSONDecoder().decode(CardInfo.self, from: Data(#"{"id":"c","projectId":"p","title":"T","prompt":"x","agent":"claude","column":"todo","createdAt":"t","updatedAt":"t"}"#.utf8))
        #expect(old.pm == nil && old.plan == nil)
        let direct = try JSONEncoder().encode(CardInput(projectId: "p", title: "T", prompt: "x", agent: "claude", direct: true))
        #expect(String(decoding: direct, as: UTF8.self).contains(#""direct":true"#))
    }
}

@Suite struct ProjectTeamTests {
    @Test func readsTheTeamAndSendsItWhole() throws {
        let project = try JSONDecoder().decode(ProjectInfo.self, from: Data(#"{"id":"p","name":"n","path":"/w","instructions":"","createdAt":"t","team":[{"id":"tester","name":"Testçi","agent":"claude","instructions":"","skills":["test-yaz"]}]}"#.utf8))
        #expect(project.team == [ProjectMember(id: "tester", name: "Testçi", agent: "claude", skills: ["test-yaz"])])
        let emptied = try ClientMessage.projectTeam(id: "a", projectId: "p", team: []).jsonString()
        #expect(emptied.contains(#""type":"project.team""#) && emptied.contains(#""team":[]"#))
    }
}

@Suite struct PMOpenedCardTests {
    private func card(_ id: String, kind: String?) throws -> CardInfo {
        let origin = kind.map { #","openedBy":{"sessionId":"s","kind":"\#($0)","reason":"src/a.ts:3"}"# } ?? ""
        return try JSONDecoder().decode(CardInfo.self, from: Data(#"{"id":"\#(id)","projectId":"p","title":"T","prompt":"x","agent":"claude","column":"todo","createdAt":"t","updatedAt":"t"\#(origin)}"#.utf8))
    }

    @Test func readsWhereACardCameFrom() throws {
        let security = try card("a", kind: "security")
        #expect(security.openedBy == CaseOrigin(sessionId: "s", kind: .security, reason: "src/a.ts:3"))
        #expect(try card("b", kind: nil).openedBy == nil)
    }

    @Test func putsSecurityProblemsFirstAndKeepsTheRestInOrder() throws {
        let lane = [try card("1", kind: nil), try card("2", kind: "fix"), try card("3", kind: "security"), try card("4", kind: nil), try card("5", kind: "security")]
        #expect(lane.laneOrder().map(\.id) == ["3", "5", "1", "2", "4"])
    }

    @Test func theReviewCardAsksForCardsNotChanges() {
        #expect(ProjectPM.reviewPrompt.contains("case_open") && ProjectPM.reviewPrompt.contains("Don't change any files"))
    }
}

@MainActor @Suite struct SkillDraftTests {
    @Test func keepsWhatPMsSuggestedUntilItIsAcceptedOrDiscarded() throws {
        let store = SessionStore { _ in }
        store.handle(try ServerMessage.decode(#"{"type":"skill.drafts.updated","drafts":[{"id":"d","name":"surum-cikar","description":"Sürüm çıkarırken.","body":"1. Test","sessionId":"s","projectId":"p","createdAt":"t"}]}"#))
        #expect(store.skillDrafts.map(\.name) == ["surum-cikar"])
        store.handle(try ServerMessage.decode(#"{"type":"skill.drafts.result","id":"x","drafts":[]}"#))
        #expect(store.skillDrafts.isEmpty)
        #expect(try ClientMessage.skillDraftAccept(id: "a", draftId: "d").jsonString().contains(#""draftId":"d""#))
    }
}

@Suite struct NodeSkillTests {
    @Test func offersSkillsOnlyWhereTheyCanBeCopiedIn() {
        let agents = [AgentInfo(id: "claude", name: "Claude"), AgentInfo(id: "yeni", name: "Y", node: "yeni"), AgentInfo(id: "eski", name: "E", node: "eski")]
        let nodes = [NodeInfo(name: "yeni", connected: true, features: ["orchestra", "projects", "skills"]), NodeInfo(name: "eski", connected: true, features: ["orchestra", "projects"])]
        #expect(AgentPlace.canTakeSkills(agent: "claude", agents: agents, nodes: nodes))
        #expect(AgentPlace.canTakeSkills(agent: "yeni", agents: agents, nodes: nodes))
        #expect(!AgentPlace.canTakeSkills(agent: "eski", agents: agents, nodes: nodes))
    }
}
