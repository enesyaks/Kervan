import Foundation
import Testing
@testable import KervanKit

/// A store on a wire whose frames can be looked at, as the server would read them.
@MainActor
private final class Wire {
    var sent: [ClientMessage] = []
    var failure: (any Error)?
    lazy var store = SessionStore { [self] message in
        self.sent.append(message)
        if let failure = self.failure { throw failure }
    }

    func frame(_ index: Int = -1) throws -> [String: Any] {
        let message = index < 0 ? sent[sent.count + index] : sent[index]
        return try JSONSerialization.jsonObject(with: Data(message.jsonString().utf8)) as! [String: Any]
    }

    /// Runs `action` until it has sent something, answers with `answers` for that request, and returns its result.
    func answered<T: Sendable>(_ answers: @escaping (String) -> [ServerMessage], _ action: @escaping @MainActor (SessionStore) async -> T) async throws -> T {
        let before = sent.count
        let store = self.store
        let task = Task { @MainActor in await action(store) }
        while sent.count == before { await Task.yield() }
        for answer in answers(try #require(sent[before].requestID)) { store.handle(answer) }
        return await task.value
    }
}

private struct WireDown: LocalizedError {
    var errorDescription: String? { "the wire is down" }
}

@MainActor @Suite struct StoreAwaitedRequestTests {
    /// What each of these sends, and that the caller hears the server's answer either way.
    private let requests: [(type: String, send: @MainActor (SessionStore) async -> String?)] = [
        ("session.changes", { await $0.loadChanges("s", sinceTurn: true) }),
        ("session.revert", { await $0.revert("s", toBefore: 3, paths: ["a"]) }),
        ("session.commit", { await $0.commit("s", message: "m") }),
        ("session.review", { await $0.review("s", agent: "a") }),
        ("session.archive", { await $0.setArchived("s", true, removeWorktree: true) }),
        ("alerts.get", { await $0.loadAlerts() }),
        ("alerts.test", { await $0.testAlerts() }),
        ("board.list", { await $0.loadBoard("p") }),
        ("card.save", { await $0.saveCard(CardInput(projectId: "p", title: "t", prompt: "x", agent: "a")) }),
        ("card.move", { await $0.moveCard("c", to: .done) }),
        ("card.model", { await $0.answerCardModel("c", useDefault: true) }),
        ("card.delete", { await $0.deleteCard("c") }),
        ("github.status", { await $0.loadGitHub() }),
        ("github.disconnect", { await $0.disconnectGitHub() }),
        ("agent.login.code", { await $0.sendAgentLoginCode("claude", code: "c") }),
        ("agent.logout", { await $0.signOutAgent("claude") }),
        ("agent.registry", { await $0.loadOfferedAgents(node: "gpu") }),
        ("web.status", { await $0.loadWebAccess() }),
        ("web.enable", { await $0.setWebAccess(true) }),
        ("web.revoke", { await $0.revokeWebDevice("d") }),
        ("project.save", { await $0.saveProject(ProjectInput(name: "n")) }),
        ("project.delete", { await $0.deleteProject("p") }),
        ("project.map", { await $0.buildProjectMap("p", agent: "a") }),
        ("project.map.get", { await $0.loadProjectMap("p") }),
        ("schedule.save", { await $0.saveSchedule(ScheduleInput(title: "t", agent: "a", prompt: "x", when: .interval(minutes: 5))) }),
        ("schedule.delete", { await $0.deleteSchedule("x") }),
        ("schedule.run", { await $0.runSchedule("x") }),
        ("terminal.open", { await $0.openTerminal("s") }),
        ("role.save", { await $0.saveRole(Role(id: "r", name: "n", agent: "a")) }),
    ]

    @Test func eachSendsItsTypeAndPassesOnSuccess() async throws {
        for request in requests {
            let wire = Wire()
            let failure = try await wire.answered({ [.ok(id: $0)] }, request.send)
            #expect(failure == nil, "\(request.type)")
            #expect(try wire.frame()["type"] as? String == request.type)
        }
    }

    @Test func eachReturnsTheServersRefusalAndLeavesTheBannerAlone() async throws {
        for request in requests {
            let wire = Wire()
            let failure = try await wire.answered({ [.error(code: "bad_message", message: "refused", id: $0)] }, request.send)
            #expect(failure == "refused", "\(request.type)")
            #expect(wire.store.lastError == nil, "\(request.type)")
        }
    }

    @Test func eachReportsWhenItCouldntBeSent() async {
        for request in requests {
            let wire = Wire()
            wire.failure = WireDown()
            let failure = await request.send(wire.store)
            #expect(failure?.contains("the wire is down") == true, "\(request.type)")
        }
    }

    @Test func aFailedLoadDoesntLeaveAnOldAnswerBehind() async throws {
        let wire = Wire()
        _ = try await wire.answered({ [.diagnosticsResult(id: $0, report: Self.report)] }) { await $0.diagnostics() }
        let refused = try await wire.answered({ [.error(code: "bad_message", message: "no", id: $0)] }) { await $0.diagnostics() }
        #expect(refused == nil)
        let silent = try await wire.answered({ [.ok(id: $0)] }) { await $0.diagnostics() }
        #expect(silent == nil, "an earlier report isn't this one's answer")
    }

    private static let report = Diagnostics(version: "1", node: "24", os: "linux", uptimeSec: 1, agents: [], nodes: [], sessions: [:], logs: [])

    @Test func diagnosticsReturnsTheReport() async throws {
        let wire = Wire()
        let report = try await wire.answered({ [.diagnosticsResult(id: $0, report: Self.report)] }) { await $0.diagnostics() }
        #expect(report == Self.report)
        #expect(try wire.frame()["type"] as? String == "diagnostics")
    }
}

@MainActor @Suite struct StoreAnsweredRequestTests {
    private let url = URL(string: "https://example.com/x")!

    @Test func aPullRequestAnswersWithItsLinkOrTheRefusalOrSaysTheServerWasSilent() async throws {
        let wire = Wire()
        let info = PullRequestInfo(branch: "b", base: "main", url: url, created: true)
        let opened = try await wire.answered({ [.sessionPullRequestResult(id: $0, sessionId: "s", pullRequest: info), .ok(id: $0)] }) { await $0.pullRequest("s", title: "t", body: "x") }
        #expect(opened == .success(info))
        let frame = try wire.frame()
        #expect(frame["type"] as? String == "session.pullRequest" && frame["title"] as? String == "t" && frame["body"] as? String == "x")
        let refused = try await wire.answered({ [.error(code: "bad_message", message: "no remote", id: $0)] }) { await $0.pullRequest("s", title: "t", body: "x") }
        #expect(refused == .failure(RequestFailure(message: "no remote")))
        guard case .failure = try await wire.answered({ [.ok(id: $0)] }, { await $0.pullRequest("s", title: "t", body: "x") }) else {
            Issue.record("the earlier answer must not count for this request")
            return
        }
    }

    @Test func gitHubSignInAnswersWithTheCode() async throws {
        let wire = Wire()
        let code = try await wire.answered({ [.githubCode(id: $0, code: "AB-12", url: self.url), .ok(id: $0)] }) { await $0.connectGitHub() }
        #expect(code == .success(GitHubDeviceCode(code: "AB-12", url: url)))
        guard case .failure = try await wire.answered({ [.ok(id: $0)] }, { await $0.connectGitHub() }) else {
            Issue.record("no code, no success")
            return
        }
        let refused = try await wire.answered({ [.error(code: "bad_message", message: "no gh", id: $0)] }) { await $0.connectGitHub() }
        #expect(refused == .failure(RequestFailure(message: "no gh")))
    }

    @Test func anAgentSignInOnlyTakesItsOwnAgentsPrompt() async throws {
        let wire = Wire()
        let own = try await wire.answered({ [.agentLoginStarted(id: $0, agent: "claude", url: self.url, code: nil, needsCode: true), .ok(id: $0)] }) { await $0.startAgentLogin("claude") }
        #expect(own == .success(AgentLoginPrompt(agent: "claude", url: url, code: nil, needsCode: true)))
        guard case .failure = try await wire.answered({ [.agentLoginStarted(id: $0, agent: "codex", url: self.url, code: "x", needsCode: false), .ok(id: $0)] }, { await $0.startAgentLogin("claude") }) else {
            Issue.record("another agent's sign-in page must not open for this one")
            return
        }
        let refused = try await wire.answered({ [.error(code: "bad_message", message: "busy", id: $0)] }) { await $0.startAgentLogin("claude") }
        #expect(refused == .failure(RequestFailure(message: "busy")))
        await wire.store.cancelAgentLoginAnswered(wire)
    }

    @Test func pairingABrowserGivesTheCodeAndWhenItExpires() async throws {
        let wire = Wire()
        let paired = try await wire.answered({ [.webPaired(id: $0, code: "123456", expiresAt: "2030-01-01T00:00:00Z"), .ok(id: $0)] }) { await $0.pairWebDevice() }
        guard case .success(let pairing) = paired else { Issue.record("expected a pairing"); return }
        #expect(pairing.code == "123456")
        #expect(pairing.expiresAt == ISO8601DateFormatter().date(from: "2030-01-01T00:00:00Z"))
        guard case .failure = try await wire.answered({ [.ok(id: $0)] }, { await $0.pairWebDevice() }) else {
            Issue.record("no code, no success")
            return
        }
        let refused = try await wire.answered({ [.error(code: "bad_message", message: "off", id: $0)] }) { await $0.pairWebDevice() }
        #expect(refused == .failure(RequestFailure(message: "off")))
    }

    @Test func installingARegistryAgentRefreshesTheCatalogOnlyWhenItWorked() async throws {
        let wire = Wire()
        let refused = try await wire.answered({ [.error(code: "bad_message", message: "no tool calls", id: $0)] }) { await $0.installAgent("qwen", lmStudioModel: "m", node: "gpu") }
        #expect(refused == "no tool calls")
        #expect(wire.sent.count == 1)
        let frame = try wire.frame()
        #expect(frame["type"] as? String == "agent.install" && frame["agentId"] as? String == "qwen" && frame["lmStudioModel"] as? String == "m" && frame["node"] as? String == "gpu")

        let store = wire.store
        let task = Task { @MainActor in await store.installAgent("qwen", node: "gpu") }
        while wire.sent.count < 2 { await Task.yield() }
        store.handle(.ok(id: wire.sent[1].requestID!))
        while wire.sent.count < 3 { await Task.yield() }
        let refresh = try wire.frame(2)
        #expect(refresh["type"] as? String == "agent.registry" && refresh["node"] as? String == "gpu", "for the same machine")
        store.handle(.ok(id: wire.sent[2].requestID!))
        #expect(await task.value == nil)
    }
}

extension SessionStore {
    fileprivate func cancelAgentLoginAnswered(_ wire: Wire) async {
        let before = wire.sent.count
        let task = Task { @MainActor in await self.cancelAgentLogin("claude") }
        while wire.sent.count == before { await Task.yield() }
        handle(.ok(id: wire.sent[before].requestID!))
        await task.value
    }
}

@MainActor @Suite struct StoreSentRequestTests {
    private let session = SessionInfo(id: "s", agent: "a", title: "t", status: .idle, createdAt: "2026-01-01T00:00:00Z")

    @Test func sendsWhatItWasAskedTo() async throws {
        let cases: [(type: String, send: @MainActor (SessionStore) async -> Void)] = [
            ("node.remove", { await $0.removeNode("n") }),
            ("node.list", { await $0.refreshNodes() }),
            ("schedule.list", { await $0.loadSchedules() }),
            ("usage.report", { await $0.loadUsage(days: 30, timeZone: TimeZone(identifier: "Europe/Istanbul")!) }),
            ("port.list", { await $0.loadPorts() }),
            ("session.config", { await $0.setConfig("s", configId: "model", value: "m") }),
            ("role.delete", { await $0.deleteRole("r") }),
            ("team.create", { await $0.createTeam(title: "t", roles: ["r"]) }),
            ("agent.list", { await $0.loadAgentConfigs() }),
            ("agent.delete", { await $0.deleteAgent("a") }),
            ("mcp.save", { await $0.saveMcp(McpServerInput(name: "m", transport: .stdio, command: "c", args: [], env: [:])) }),
            ("mcp.delete", { await $0.deleteMcp("m") }),
            ("session.cancel", { await $0.cancel("s") }),
            ("session.permission", { await $0.respond("s", requestId: "r", optionId: "o") }),
        ]
        for item in cases {
            let wire = Wire()
            await item.send(wire.store)
            #expect(try wire.frame()["type"] as? String == item.type)
            #expect(wire.store.lastError == nil, "\(item.type)")
            wire.failure = WireDown()
            await item.send(wire.store)
            #expect(wire.store.lastError?.contains("the wire is down") == true, "\(item.type)")
        }
    }

    @Test func aRenameIsTrimmedCappedAndNeverBlank() async throws {
        let wire = Wire()
        await wire.store.rename("s", title: "   \n")
        #expect(wire.sent.isEmpty)
        await wire.store.rename("s", title: "  ad  ")
        #expect(try wire.frame()["title"] as? String == "ad")
        await wire.store.rename("s", title: String(repeating: "x", count: 500))
        #expect((try wire.frame()["title"] as? String)?.count == 120)
    }

    @Test func aTerminalOnlyTakesInputWhileItsOpen() async throws {
        let wire = Wire()
        let store = wire.store
        await store.typeInTerminal("s", "ls")
        await store.closeTerminal("s")
        #expect(wire.sent.isEmpty, "nothing open yet")

        store.handle(.terminalOpened(id: "r", terminalId: "t", sessionId: "s", backlog: "$ "))
        await store.typeInTerminal("s", "ls")
        let input = try wire.frame()
        #expect(input["type"] as? String == "terminal.input" && input["terminalId"] as? String == "t" && input["data"] as? String == "ls")

        store.clearTerminal("s")
        #expect(store.terminals["s"]?.output == "")

        store.handle(.terminalExited(terminalId: "t"))
        await store.typeInTerminal("s", "ls")
        #expect(wire.sent.count == 1, "it has exited")
        await store.closeTerminal("s")
        #expect(try wire.frame()["type"] as? String == "terminal.close")
    }

    @Test func tellsATerminalAgentFromAnACPOne() async {
        let wire = Wire()
        let store = wire.store
        await store.connected(agents: [AgentInfo(id: "a", name: "A", terminal: true), AgentInfo(id: "b", name: "B")])
        store.handle(.sessionListResult(id: "r", sessions: [session]))
        #expect(store.isTerminal("s"))
        #expect(!store.isTerminal("missing"))
    }

    @Test func readsAsessionsPlanCommandsAndCheckpointsFromItsEvents() {
        let wire = Wire()
        let store = wire.store
        #expect(store.transcript(for: "s").isEmpty && store.plan(for: "s") == nil && store.commands(for: "s").isEmpty && store.checkpoints(for: "s").isEmpty)
        let entry = PlanEntry(content: "step", status: "pending", priority: "high")
        store.handle(.sessionHistoryResult(id: "r", sessionId: "s", events: [
            SessionEvent(seq: 1, body: .userMessage("a")),
            SessionEvent(seq: 2, body: .checkpoint(commit: "abc", messageSeq: 1)),
            SessionEvent(seq: 3, body: .plan([entry])),
        ]))
        #expect(!store.transcript(for: "s").isEmpty)
        #expect(store.plan(for: "s") == [entry])
        #expect(store.checkpoints(for: "s") == [1])
    }

    @Test func findsTheLatestReviewThatIsntArchived() {
        let wire = Wire()
        let store = wire.store
        func review(_ id: String, _ at: String, archived: Bool = false) -> SessionInfo {
            var info = SessionInfo(id: id, agent: "a", title: id, status: .idle, createdAt: at)
            info.reviewOf = "s"
            info.archived = archived
            return info
        }
        #expect(store.latestReview(of: "s") == nil)
        store.handle(.sessionListResult(id: "r", sessions: [session, review("old", "2026-01-01T00:00:00Z"), review("new", "2026-01-02T00:00:00Z"), review("gone", "2026-01-03T00:00:00Z", archived: true)]))
        #expect(store.latestReview(of: "s")?.id == "new")
    }

    @Test func aReviewersFindingsAreItsLastTurnAlone() {
        let store = Wire().store
        #expect(store.findings(of: "r") == nil)
        store.handle(.sessionHistoryResult(id: "x", sessionId: "r", events: [
            SessionEvent(seq: 1, body: .userMessage("review")),
            SessionEvent(seq: 2, body: .agentMessageChunk("first answer")),
            SessionEvent(seq: 3, body: .userMessage("again")),
            SessionEvent(seq: 4, body: .agentMessageChunk(" second")),
            SessionEvent(seq: 5, body: .agentMessageChunk(" answer\n")),
        ]))
        #expect(store.findings(of: "r") == "second answer")
    }

    @Test func findsAProjectByIdOnlyWhenThereIsOne() {
        let store = Wire().store
        #expect(store.project(nil) == nil && store.project("p") == nil)
        let project = ProjectInfo(id: "p", name: "n", path: "/w", instructions: "", createdAt: "t")
        store.handle(.projectListResult(id: "r", projects: [project]))
        #expect(store.project("p") == project)
    }

    @Test func aBlankSearchClearsWithoutAsking() async {
        let wire = Wire()
        await wire.store.search("kervan")
        #expect(wire.store.isSearching)
        await wire.store.search("   ")
        #expect(!wire.store.isSearching && wire.store.searchHits.isEmpty)
        #expect(wire.sent.count == 1)
    }
}

/// Requests that wait for an answer that can never come.
@MainActor @Suite struct StoreLostAnswerTests {
    @Test func aRequestLostWithTheConnectionEndsWithAReason() async throws {
        let wire = Wire()
        let store = wire.store
        let role = Task { @MainActor in await store.saveRole(Role(id: "r", name: "n", agent: "a")) }
        let commit = Task { @MainActor in await store.commit("s", message: "m") }
        while wire.sent.count < 2 { await Task.yield() }

        store.connectionLost()

        #expect(await role.value?.isEmpty == false)
        #expect(await commit.value == role.value)
        #expect(store.lastError == nil, "the callers show it")
        // An answer can't arrive twice: a late one for a finished request is harmless.
        store.handle(.ok(id: try #require(wire.sent[0].requestID)))
    }

    @Test func aLostConnectionWithNothingWaitingChangesNothing() {
        let store = Wire().store
        store.connectionLost()
        store.connectionLost()
        #expect(store.lastError == nil && store.agentSaveError == nil)
    }

    @Test func aRequestAfterTheLossStillGetsItsAnswer() async throws {
        let wire = Wire()
        wire.store.connectionLost()
        let failure = try await wire.answered({ [.ok(id: $0)] }) { await $0.commit("s", message: "m") }
        #expect(failure == nil)
    }

    @Test func anAgentSaveThatCouldntBeSentReturnsAndSaysSo() async {
        let wire = Wire()
        wire.failure = WireDown()
        await wire.store.saveAgent(AgentInput(id: "a", name: "A", command: "c"))
        #expect(wire.store.agentSaveError?.contains("the wire is down") == true)
        #expect(wire.store.lastError == nil, "the form shows it")
    }

    @Test func anAgentSaveLostWithTheConnectionReturnsAndSaysSo() async {
        let wire = Wire()
        let store = wire.store
        let task = Task { @MainActor in await store.saveAgent(AgentInput(id: "a", name: "A", command: "c")) }
        while wire.sent.isEmpty { await Task.yield() }
        store.connectionLost()
        await task.value
        #expect(store.agentSaveError?.isEmpty == false, "the form must not close as if it had saved")
    }

    @Test func anAnsweredAgentSaveStillSucceeds() async throws {
        let wire = Wire()
        let store = wire.store
        let task = Task { @MainActor in await store.saveAgent(AgentInput(id: "a", name: "A", command: "c")) }
        while wire.sent.isEmpty { await Task.yield() }
        store.handle(.agentListResult(id: try #require(wire.sent[0].requestID), agents: [], nodes: ["local"]))
        await task.value
        #expect(store.agentSaveError == nil)
    }
}

@MainActor @Suite struct OfferedAgentRefreshTests {
    private func result(_ id: String, models: [String]) -> ServerMessage {
        .agentRegistryResult(id: id, agents: [], ollama: OllamaStatus(running: true, url: "u", models: models))
    }

    @Test func anOfferSaysWhichModelsAreAddedAlreadyEvenFromAnOlderServer() throws {
        let fields = #""id":"goose","name":"goose","description":"","status":"added","ollama":true"#
        let current = try JSONDecoder().decode(OfferedAgent.self, from: Data(#"{\#(fields),"addedModels":["a"]}"#.utf8))
        #expect(current.addedModels == ["a"])
        let older = try JSONDecoder().decode(OfferedAgent.self, from: Data("{\(fields)}".utf8))
        #expect(older.addedModels == nil)
    }

    @Test func aModelDownloadedMeanwhileShowsUpWithoutEmptyingTheList() async throws {
        let wire = Wire()
        _ = try await wire.answered({ [self.result($0, models: ["a"]), .ok(id: $0)] }) { await $0.loadOfferedAgents() }
        #expect(wire.store.ollama?.models == ["a"])

        let store = wire.store
        let task = Task { @MainActor in await store.refreshOfferedAgents(node: "mac") }
        while wire.sent.count < 2 { await Task.yield() }
        #expect(store.ollama?.models == ["a"], "still on screen while asking")
        #expect(try wire.frame()["node"] as? String == "mac")
        let id = try #require(wire.sent[1].requestID)
        store.handle(result(id, models: ["a", "b"]))
        store.handle(.ok(id: id))
        await task.value
        #expect(store.ollama?.models == ["a", "b"])
    }

    @Test func aSlowAnswerAboutAnotherMachineIsDropped() async throws {
        let wire = Wire()
        let store = wire.store
        let first = Task { @MainActor in await store.refreshOfferedAgents(node: "old") }
        while wire.sent.isEmpty { await Task.yield() }
        let second = Task { @MainActor in await store.refreshOfferedAgents(node: "new") }
        while wire.sent.count < 2 { await Task.yield() }
        let (oldID, newID) = (try #require(wire.sent[0].requestID), try #require(wire.sent[1].requestID))

        store.handle(result(newID, models: ["new-model"]))
        store.handle(.ok(id: newID))
        store.handle(result(oldID, models: ["old-model"]))
        store.handle(.ok(id: oldID))
        await first.value
        await second.value
        #expect(store.ollama?.models == ["new-model"])
    }
}

@Suite struct LMStudioToolTests {
    @Test func findsTheToolBionicInstalls() {
        #expect(LMStudioTool.path(home: "/Users/x", isExecutable: { $0 == "/Users/x/.lmstudio/bin/lms" }) == "/Users/x/.lmstudio/bin/lms")
        #expect(LMStudioTool.path(home: "/Users/x", isExecutable: { _ in false }) == nil)
        #expect(LMStudioTool.startArguments == ["server", "start"])
    }

    @Test func readsThisMacsNodeName() {
        #expect(MacNode.installedName(read: { _ in "kutu\n" }) == "kutu")
        #expect(MacNode.installedName(read: { _ in " \n" }) == nil)
        #expect(MacNode.installedName(read: { _ in nil }) == nil)
    }
}

@Suite struct NodeListTests {
    @Test func tellsWhichNodesCanBeChosenNow() {
        let nodes = [NodeInfo(name: "gpu", connected: true), NodeInfo(name: "mac", connected: false), NodeInfo(name: "vm", connected: true)]
        #expect(nodes.connectedNames == ["gpu", "vm"])
        #expect(nodes.offlineNames == ["mac"])
        #expect([NodeInfo]().connectedNames.isEmpty && [NodeInfo]().offlineNames.isEmpty)
    }
}

@Suite struct UsageReportTests {
    private let report = UsageReport(
        days: [
            UsageReport.Day(date: "2026-10-01", agent: "claude", costUsd: 1.5),
            UsageReport.Day(date: "2026-10-02", agent: "codex", costUsd: 4),
            UsageReport.Day(date: "2026-10-03", agent: "claude", costUsd: 1),
        ],
        sessions: [UsageReport.SessionCost(sessionId: "s", costUsd: 6.5)]
    )

    @Test func addsUpSpending() {
        #expect(report.total == 6.5)
        #expect(report.total(since: "2026-10-02") == 5, "from that day on")
        #expect(report.total(since: "2027-01-01") == 0)
        #expect(UsageReport(days: [], sessions: []).total == 0)
    }

    @Test func listsAgentsLargestFirst() {
        #expect(report.byAgent.map(\.agent) == ["codex", "claude"])
        #expect(report.byAgent.map(\.costUsd) == [4, 2.5])
    }
}

@Suite struct SetupStepTests {
    private func hasDistinctWords<S: Sequence>(_ titles: S) -> Bool where S.Element == String {
        let all = Array(titles)
        return !all.contains("") && Set(all).count == all.count
    }

    @Test func everyStageSaysSomethingOfItsOwn() {
        #expect(hasDistinctWords(InstallStep.allCases.map(\.title)))
        #expect(hasDistinctWords(InstallStep.allCases.map(\.detail)))
        #expect(hasDistinctWords(HubSetupStep.allCases.map(\.title)))
        #expect(hasDistinctWords(HubSetupStep.allCases.map(\.detail)))
        #expect(hasDistinctWords(MacNode.Step.allCases.map(\.title)))
        #expect(MacNode.Step.code.detail != "" && MacNode.Step.service.detail == "")
    }

    @Test func stagesAreInOrder() {
        #expect(MacNode.Step.checking < MacNode.Step.service)
        #expect(InstallStep.connecting < InstallStep.connected)
        #expect(HubSetupStep.uploading < HubSetupStep.ready)
    }

    @Test func readsNodeSetupOutputWithoutGoingBack() {
        #expect(InstallStep.reached(in: "") == .connecting)
        #expect(InstallStep.reached(in: "==> checking the hub") == .checkingHub)
        #expect(InstallStep.reached(in: "==> paketler kuruluyor\n==> Kervan kodu") == .files)
        #expect(InstallStep.reached(in: "==> joining the hub\nnoise about service") == .joining, "only ==> lines count")
        #expect(InstallStep.reached(in: "==> service\n==> checking the hub") == .service)
        #expect(InstallStep.reached(in: "==> something unknown") == .connecting)
    }

    @Test func neverWaitsForAPasswordOverSSH() {
        for arguments in [HubSetup.sudoCheckArguments(user: "u", host: "h"), HubSetup.tailscaleAddressArguments(user: "u", host: "h")] {
            #expect(arguments.contains("BatchMode=yes"))
            #expect(arguments.contains("u@h"))
        }
        #expect(HubSetup.sudoCheckArguments(user: "u", host: "h").last == "sudo -n true")
        #expect(HubSetup.tailscaleAddressArguments(user: "u", host: "h").last?.hasPrefix("tailscale status --json") == true)
    }

    @Test func knowsWhetherThisMacIsANode() {
        #expect(MacNode.isInstalled(fileExists: { $0 == MacNode.service }))
        #expect(!MacNode.isInstalled(fileExists: { _ in false }))
    }
}
