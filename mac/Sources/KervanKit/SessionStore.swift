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
    /// Every agent with its settings, for the Agents settings tab; loaded on request.
    public private(set) var agentConfigs: [AgentConfig] = []
    /// Where agents can run. Only "local" until multi-server nodes (M13).
    public private(set) var nodes: [String] = ["local"]
    /// The server's refusal of the last agent save (it tries the agent first), if any.
    public private(set) var agentSaveError: String?
    public private(set) var roles: [Role] = []
    /// Newest first.
    public private(set) var teams: [TeamInfo] = []
    /// MCP servers registered on the server, refreshed on connect and after every change.
    public private(set) var mcpServers: [McpServerSummary] = []
    /// True while the latest search is on its way.
    public private(set) var isSearching = false
    public private(set) var projects: [ProjectInfo] = []
    public private(set) var schedules: [ScheduleInfo] = []
    /// The last Changes answer per session.
    public private(set) var changes: [String: ChangeSet] = [:]
    public private(set) var usage: UsageReport?
    /// Ports something listens on, on the server.
    public private(set) var ports: [ListeningPort]?
    private var diagnosticsReport: Diagnostics?
    private var pullRequestAnswer: PullRequestInfo?
    private var pairingAnswer: WebPairing?
    private var githubCodeAnswer: GitHubDeviceCode?
    private var agentLoginAnswer: AgentLoginPrompt?
    /// Phone alert settings as last reported; nil until asked for.
    public private(set) var alerts: AlertSettings?
    /// Task boards by project, as last reported.
    public private(set) var boards: [String: [CardInfo]] = [:]
    /// Project maps' text by project, as last asked for.
    public private(set) var projectMaps: [String: String] = [:]
    /// The server's GitHub sign-in as last reported; nil until asked for.
    public private(set) var github: GitHubStatus?
    /// Why the last GitHub sign-in didn't finish, if it didn't.
    public private(set) var githubError: String?
    /// How the last account sign-in of each agent ended, by agent id; cleared when a new one starts.
    public private(set) var agentLoginOutcomes: [String: AgentLoginOutcome] = [:]
    /// The ACP registry's agents as the server sees them, and its Ollama; nil until asked for.
    public private(set) var offeredAgents: [OfferedAgent]?
    public private(set) var ollama: OllamaStatus?
    /// That machine's LM Studio; nil until asked for, and from a server or node too old to say.
    public private(set) var lmStudio: OllamaStatus?
    /// Web access as the server last told it; nil until asked for.
    public private(set) var webAccess: WebAccessStatus?
    /// The shell open in each session's folder, by session id.
    public private(set) var terminals: [String: TerminalState] = [:]

    public struct TerminalState: Equatable, Sendable {
        public let id: String
        public var output: String
        public var exited = false
    }

    /// Requests whose answer someone awaits, by request id: resumed with nil on success, else the error.
    private var awaiting: [String: CheckedContinuation<String?, Never>] = [:]
    /// What a terminal keeps on screen; older output scrolls away.
    static let terminalChars = 200_000

    /// Called when a live status change deserves a notification (not for lists loaded on connect).
    public var onAlert: (@MainActor (SessionAlert) -> Void)?
    /// The hub's own addresses, whenever it reports them.
    public var onHubAddresses: (@MainActor ([HubAddress]) -> Void)?

    private let send: Sender
    private var pendingCreates: Set<String> = []
    private var latestSearch: String?
    private var pendingAgentSave: String?
    private var latestRegistryRequest: String?
    private var pendingTeams: Set<String> = []

    public init(send: @escaping Sender) {
        self.send = send
    }

    /// Display name for an agent id, with its node if it has one; falls back to the id for agents the server no longer offers.
    public func agentName(_ id: String) -> String {
        agents.first { $0.id == id }?.displayName ?? id
    }

    /// Machines running kervan-node for this server; empty when it has none.
    public private(set) var nodeInfos: [NodeInfo] = []
    /// Where the hub says a new node could reach it (its Tailscale and LAN addresses).
    public private(set) var hubAddresses: [HubAddress] = []

    /// The invite the add-node sheet asked for: the node's name and its single-use code.
    public private(set) var nodeInvite: (name: String, code: String, expiresAt: String)?
    private var pendingInvite: String?

    public func inviteNode(_ name: String) async {
        nodeInvite = nil
        let id = Self.newID()
        pendingInvite = id
        await request(.nodeInvite(id: id, name: name))
    }

    public func removeNode(_ name: String) async {
        await request(.nodeRemove(id: Self.newID(), name: name))
    }

    /// True when the session's agent runs in a pseudo-terminal; its answers are terminal text, not Markdown.
    public func isTerminal(_ sessionID: String) -> Bool {
        guard let session = session(sessionID) else { return false }
        return agents.first { $0.id == session.agent }?.terminal ?? false
    }

    public func session(_ id: String) -> SessionInfo? {
        sessions.first { $0.id == id }
    }

    public func transcript(for id: String) -> [TranscriptItem] {
        Transcript.build(events[id] ?? [])
    }

    /// Asks again for the nodes and this server's addresses (they change when e.g. Tailscale signs in).
    public func refreshNodes() async {
        await request(.nodeList(id: Self.newID()))
    }

    /// Call after every (re)connect: refreshes the list, and with it every session's history.
    public func connected(agents: [AgentInfo]) async {
        self.agents = agents
        await request(.sessionList(id: Self.newID()))
        await request(.mcpList(id: Self.newID()))
        await request(.roleList(id: Self.newID()))
        await request(.teamList(id: Self.newID()))
        await request(.nodeList(id: Self.newID()))
        await request(.projectList(id: Self.newID()))
        await request(.scheduleList(id: Self.newID()))
        // Terminals opened before a reconnect may be gone; they reopen when shown.
        terminals = [:]
    }

    public func create(
        agent: String, skills: [String] = [], mcpServers: [String] = [], orchestrate: Bool = false, budgetUsd: Double? = nil,
        projectId: String? = nil, shared: Bool = false, split: Bool = false, autoApprove: Bool = false
    ) async {
        let id = Self.newID()
        pendingCreates.insert(id)
        await request(.sessionCreate(
            id: id, agent: agent, skills: skills, mcpServers: mcpServers, orchestrate: orchestrate, budgetUsd: budgetUsd,
            projectId: projectId, shared: shared, split: split, autoApprove: autoApprove
        ))
    }

    // MARK: Changes, rewinding, committing

    /// The plan the agent is following in this turn, if it shared one.
    public func plan(for sessionID: String) -> [PlanEntry]? { Transcript.plan(events[sessionID] ?? []) }

    public func commands(for sessionID: String) -> [SlashCommand] { Transcript.commands(events[sessionID] ?? []) }

    /// User messages whose "before" the folder can be put back to.
    public func checkpoints(for sessionID: String) -> Set<Int> { Transcript.checkpoints(events[sessionID] ?? []) }

    /// Fetches what the session changed; the answer lands in `changes`. Returns the server's refusal, if any.
    @discardableResult
    public func loadChanges(_ sessionID: String, sinceTurn: Bool = false) async -> String? {
        await call(.sessionChanges(id: Self.newID(), sessionId: sessionID, sinceTurn: sinceTurn))
    }

    /// Puts files back as they were before the user message `seq` (all of them when `paths` is empty).
    @discardableResult
    public func revert(_ sessionID: String, toBefore seq: Int, paths: [String] = []) async -> String? {
        await call(.sessionRevert(id: Self.newID(), sessionId: sessionID, seq: seq, paths: paths))
    }

    @discardableResult
    public func commit(_ sessionID: String, message: String) async -> String? {
        await call(.sessionCommit(id: Self.newID(), sessionId: sessionID, message: message))
    }

    /// Starts `agent` reviewing the session's changes; the server's refusal (e.g. nothing to review), if any.
    @discardableResult
    public func review(_ sessionID: String, agent: String) async -> String? {
        await call(.sessionReview(id: Self.newID(), sessionId: sessionID, agent: agent))
    }

    /// The latest review of a session, if one was asked for.
    public func latestReview(of sessionID: String) -> SessionInfo? {
        sessions.filter { $0.reviewOf == sessionID && !$0.archived }.max { $0.createdAt < $1.createdAt }
    }

    /// What a reviewer said in its last turn, whole; nil until it has said something.
    public func findings(of reviewID: String) -> String? {
        var reply = ""
        for event in events[reviewID] ?? [] {
            switch event.body {
            case .userMessage: reply = ""
            case .agentMessageChunk(let text): reply += text
            default: break
            }
        }
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Pushes the session's work on a branch of its own and opens a pull request; the server's refusal on failure.
    public func pullRequest(_ sessionID: String, title: String, body: String) async -> Result<PullRequestInfo, RequestFailure> {
        pullRequestAnswer = nil
        if let failure = await call(.sessionPullRequest(id: Self.newID(), sessionId: sessionID, title: title, body: body)) {
            return .failure(RequestFailure(message: failure))
        }
        guard let answer = pullRequestAnswer else { return .failure(RequestFailure(message: L("The server didn't answer.", "Sunucu yanıt vermedi."))) }
        return .success(answer)
    }

    // MARK: Phone alerts

    @discardableResult
    public func loadAlerts() async -> String? {
        await call(.alertsGet(id: Self.newID()))
    }

    @discardableResult
    public func saveAlerts(_ input: AlertInput) async -> String? {
        await call(.alertsSave(id: Self.newID(), alerts: input))
    }

    /// Sends a test alert; the reason it didn't arrive, if the server could tell.
    @discardableResult
    public func testAlerts() async -> String? {
        await call(.alertsTest(id: Self.newID()))
    }

    // MARK: Task boards

    @discardableResult
    public func loadBoard(_ projectID: String) async -> String? {
        await call(.boardList(id: Self.newID(), projectId: projectID))
    }

    @discardableResult
    public func saveCard(_ card: CardInput) async -> String? {
        await call(.cardSave(id: Self.newID(), card: card))
    }

    /// Returns the server's refusal, if any (e.g. moving a started card back to To do).
    @discardableResult
    public func moveCard(_ cardID: String, to column: CardColumn) async -> String? {
        await call(.cardMove(id: Self.newID(), cardId: cardID, column: column))
    }

    @discardableResult
    public func answerCardModel(_ cardID: String, useDefault: Bool) async -> String? {
        await call(.cardModel(id: Self.newID(), cardId: cardID, useDefault: useDefault))
    }

    @discardableResult
    public func deleteCard(_ cardID: String) async -> String? {
        await call(.cardDelete(id: Self.newID(), cardId: cardID))
    }

    // MARK: GitHub

    @discardableResult
    public func loadGitHub() async -> String? {
        await call(.githubStatus(id: Self.newID()))
    }

    /// Starts the server's GitHub sign-in; the code to enter, or the server's refusal. `github` updates when it ends.
    public func connectGitHub() async -> Result<GitHubDeviceCode, RequestFailure> {
        githubCodeAnswer = nil
        githubError = nil
        if let failure = await call(.githubConnect(id: Self.newID())) { return .failure(RequestFailure(message: failure)) }
        guard let answer = githubCodeAnswer else { return .failure(RequestFailure(message: L("The server didn't answer.", "Sunucu yanıt vermedi."))) }
        return .success(answer)
    }

    @discardableResult
    // MARK: Agent accounts

    /// Starts signing `agent` in on the server with the user's own account: the page to open, or why not.
    /// `agentLoginOutcomes[agent]` is set when the sign-in ends.
    public func startAgentLogin(_ agent: String) async -> Result<AgentLoginPrompt, RequestFailure> {
        agentLoginAnswer = nil
        agentLoginOutcomes[agent] = nil
        if let failure = await call(.agentLogin(id: Self.newID(), agent: agent)) { return .failure(RequestFailure(message: failure)) }
        guard let answer = agentLoginAnswer, answer.agent == agent else {
            return .failure(RequestFailure(message: L("The server didn't answer.", "Sunucu yanıt vermedi.")))
        }
        return .success(answer)
    }

    /// Claude's code from the page the user signed in on; nil once the server has it.
    public func sendAgentLoginCode(_ agent: String, code: String) async -> String? {
        await call(.agentLoginCode(id: Self.newID(), agent: agent, code: code))
    }

    public func cancelAgentLogin(_ agent: String) async {
        _ = await call(.agentLoginCancel(id: Self.newID(), agent: agent))
    }

    public func signOutAgent(_ agent: String) async -> String? {
        agentLoginOutcomes[agent] = nil
        return await call(.agentLogout(id: Self.newID(), agent: agent))
    }

    // MARK: Agent catalog

    /// Asks the server for the registry's agents, as this server or `node` sees them; nil, or why it couldn't.
    public func loadOfferedAgents(node: String? = nil) async -> String? {
        // What one machine offers says nothing about another.
        offeredAgents = nil
        ollama = nil
        lmStudio = nil
        return await askForOfferedAgents(node: node)
    }

    /// The same question while the catalog is open, keeping what's on screen until the answer differs: a model
    /// downloaded meanwhile shows up by itself.
    public func refreshOfferedAgents(node: String? = nil) async {
        _ = await askForOfferedAgents(node: node)
    }

    private func askForOfferedAgents(node: String?) async -> String? {
        let id = Self.newID()
        // Only the latest question counts: a slower answer about the machine chosen before must not replace it.
        latestRegistryRequest = id
        return await call(.agentRegistry(id: id, node: node))
    }

    /// Installs (or finds) a registry agent on the server and adds it, optionally on a local model; nil, or why not.
    /// It can take a few minutes. The agent list and the catalog refresh when it's done.
    public func installAgent(_ agentId: String, ollamaModel: String? = nil, lmStudioModel: String? = nil, node: String? = nil) async -> String? {
        let failure = await call(.agentInstall(id: Self.newID(), agentId: agentId, ollamaModel: ollamaModel, node: node, lmStudioModel: lmStudioModel))
        if failure == nil { _ = await loadOfferedAgents(node: node) }
        return failure
    }

    public func disconnectGitHub() async -> String? {
        githubError = nil
        return await call(.githubDisconnect(id: Self.newID()))
    }

    // MARK: Web access

    /// Fetches whether web access is on and which browsers are paired; the answer lands in `webAccess`.
    @discardableResult
    public func loadWebAccess() async -> String? {
        await call(.webStatus(id: Self.newID()))
    }

    @discardableResult
    public func setWebAccess(_ enabled: Bool) async -> String? {
        await call(.webEnable(id: Self.newID(), enabled: enabled))
    }

    /// A one-time code for a new browser, or the server's refusal.
    public func pairWebDevice() async -> Result<WebPairing, RequestFailure> {
        pairingAnswer = nil
        if let failure = await call(.webPair(id: Self.newID())) { return .failure(RequestFailure(message: failure)) }
        guard let answer = pairingAnswer else { return .failure(RequestFailure(message: L("The server didn't answer.", "Sunucu yanıt vermedi."))) }
        return .success(answer)
    }

    @discardableResult
    public func revokeWebDevice(_ deviceID: String) async -> String? {
        await call(.webRevoke(id: Self.newID(), deviceId: deviceID))
    }

    // MARK: Projects and scheduled tasks

    public func project(_ id: String?) -> ProjectInfo? {
        id.flatMap { id in projects.first { $0.id == id } }
    }

    @discardableResult
    public func saveProject(_ project: ProjectInput) async -> String? {
        await call(.projectSave(id: Self.newID(), project: project))
    }

    @discardableResult
    public func deleteProject(_ id: String) async -> String? {
        await call(.projectDelete(id: Self.newID(), projectId: id))
    }

    /// Starts (re)building the project's map; nil, or why not. The project's `map` says how it goes.
    @discardableResult
    public func buildProjectMap(_ id: String, agent: String) async -> String? {
        await call(.projectMap(id: Self.newID(), projectId: id, agent: agent))
    }

    /// Asks for the map's text, which lands in `projectMaps`; nil, or why not.
    @discardableResult
    public func loadProjectMap(_ id: String) async -> String? {
        await call(.projectMapGet(id: Self.newID(), projectId: id))
    }

    public func loadSchedules() async {
        await request(.scheduleList(id: Self.newID()))
    }

    @discardableResult
    public func saveSchedule(_ schedule: ScheduleInput) async -> String? {
        await call(.scheduleSave(id: Self.newID(), schedule: schedule))
    }

    @discardableResult
    public func deleteSchedule(_ id: String) async -> String? {
        await call(.scheduleDelete(id: Self.newID(), scheduleId: id))
    }

    /// Runs the task now; its new session shows up in the sidebar.
    @discardableResult
    public func runSchedule(_ id: String) async -> String? {
        await call(.scheduleRun(id: Self.newID(), scheduleId: id))
    }

    // MARK: Usage, ports, terminals

    public func loadUsage(days: Int, timeZone: TimeZone = .current) async {
        await request(.usageReport(id: Self.newID(), days: days, timeZone: timeZone.identifier))
    }

    /// The server's part of a bug report; nil when it couldn't be fetched (older server, no connection).
    public func diagnostics() async -> Diagnostics? {
        diagnosticsReport = nil
        guard await call(.diagnostics(id: Self.newID())) == nil else { return nil }
        return diagnosticsReport
    }

    public func loadPorts() async {
        await request(.portList(id: Self.newID()))
    }

    /// Opens (or finds) the shell in the session's folder; it lands in `terminals`. Returns the refusal, if any.
    @discardableResult
    public func openTerminal(_ sessionID: String) async -> String? {
        await call(.terminalOpen(id: Self.newID(), sessionId: sessionID))
    }

    public func typeInTerminal(_ sessionID: String, _ data: String) async {
        guard let terminal = terminals[sessionID], !terminal.exited else { return }
        await request(.terminalInput(id: Self.newID(), terminalId: terminal.id, data: data))
    }

    public func closeTerminal(_ sessionID: String) async {
        guard let terminal = terminals[sessionID] else { return }
        await request(.terminalClose(id: Self.newID(), terminalId: terminal.id))
    }

    public func clearTerminal(_ sessionID: String) {
        terminals[sessionID]?.output = ""
    }

    /// Sends and waits for the server's answer to this request: nil when it went through, else why not.
    private func call(_ message: ClientMessage) async -> String? {
        guard let id = message.requestID else { return nil }
        return await withCheckedContinuation { continuation in
            awaiting[id] = continuation
            Task {
                do {
                    try await send(message)
                } catch {
                    awaiting.removeValue(forKey: id)?.resume(returning: Self.couldntSend(error))
                }
            }
        }
    }

    /// Ends everything still waiting for an answer: it was lost with the connection, and a reconnect won't bring it.
    public func connectionLost() {
        let reason = L(
            "The connection to the server was lost before it answered; it may still have gone through.",
            "Sunucu yanıt vermeden bağlantı koptu; işlem yine de gerçekleşmiş olabilir."
        )
        let waiting = awaiting.values
        awaiting.removeAll()
        for waiter in waiting { waiter.resume(returning: reason) }
        if pendingAgentSave != nil {
            pendingAgentSave = nil
            agentSaveError = reason
        }
    }

    private static func couldntSend(_ error: any Error) -> String {
        L("Couldn't send to the server: \(error.localizedDescription)", "Sunucuya gönderilemedi: \(error.localizedDescription)")
    }

    /// What a lead and its helpers have spent together, from what their agents reported; nil when none reported a cost.
    public func crewCost(_ leadID: String) -> Double? {
        let costs = ([session(leadID)].compactMap { $0 } + helpers(of: leadID)).compactMap { $0.usage?.costUsd }
        return costs.isEmpty ? nil : costs.reduce(0, +)
    }

    /// Picks a turn back up after a server restart cut it off.
    public func resume(_ sessionID: String) async {
        await prompt(sessionID, text: Transcript.resumePrompt)
    }

    /// Changes one of the session's agent settings, e.g. its model. The server answers with session.updated.
    public func setConfig(_ sessionID: String, configId: String, value: String) async {
        await request(.sessionConfig(id: Self.newID(), sessionId: sessionID, configId: configId, value: value))
    }

    /// The helpers a lead agent started, oldest first.
    public func helpers(of leadID: String) -> [SessionInfo] {
        sessions.filter { $0.parentId == leadID }.sorted { $0.createdAt < $1.createdAt }
    }

    /// Nil, or why the server refused it.
    public func saveRole(_ role: Role) async -> String? {
        await call(.roleSave(id: Self.newID(), role: role))
    }

    public func deleteRole(_ id: String) async {
        await request(.roleDelete(id: Self.newID(), roleId: id))
    }

    /// Starts one session per role; the first member is selected when the team arrives.
    public func createTeam(title: String, roles: [String]) async {
        let id = Self.newID()
        pendingTeams.insert(id)
        await request(.teamCreate(id: id, title: title, roles: roles))
    }

    public func loadAgentConfigs() async {
        await request(.agentList(id: Self.newID()))
    }

    /// Asks the server to try the agent and keep it. Returns once the server answered; on refusal
    /// `agentSaveError` says why.
    public func saveAgent(_ agent: AgentInput) async {
        let id = Self.newID()
        agentSaveError = nil
        pendingAgentSave = id
        do {
            try await send(.agentSave(id: id, agent: agent))
        } catch {
            if pendingAgentSave == id {
                pendingAgentSave = nil
                agentSaveError = Self.couldntSend(error)
            }
        }
        while pendingAgentSave == id { try? await Task.sleep(for: .milliseconds(100)) }
    }

    public func deleteAgent(_ id: String) async {
        await request(.agentDelete(id: Self.newID(), agentId: id))
    }

    public func saveMcp(_ server: McpServerInput) async {
        await request(.mcpSave(id: Self.newID(), server: server))
    }

    public func deleteMcp(_ name: String) async {
        await request(.mcpDelete(id: Self.newID(), name: name))
    }

    /// Whether a message fits in one frame: the server closes the connection on anything over its 1 MiB limit.
    public nonisolated static func fitsInOneMessage(_ text: String) -> Bool {
        ((try? JSONEncoder().encode(text).count) ?? .max) <= 1_000_000
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

    public func setAutoApprove(_ sessionID: String, _ enabled: Bool) async {
        await request(.sessionAutoApprove(id: Self.newID(), sessionId: sessionID, enabled: enabled))
    }

    public func rename(_ sessionID: String, title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await request(.sessionRename(id: Self.newID(), sessionId: sessionID, title: String(trimmed.prefix(120))))
    }

    /// Returns the server's refusal, if any (removing a worktree can be refused, e.g. while the agent works).
    @discardableResult
    public func setArchived(_ sessionID: String, _ archived: Bool, removeWorktree: Bool = false) async -> String? {
        await call(.sessionArchive(id: Self.newID(), sessionId: sessionID, archived: archived, removeWorktree: removeWorktree))
    }

    /// A project session whose agent runs on a node: its work comes to the server as a branch, so it can continue here.
    public func canContinueOnServer(_ session: SessionInfo) -> Bool {
        session.projectId != nil && session.branch != nil && session.parentId == nil
            && agents.first { $0.id == session.agent }?.node != nil
    }

    /// The agents a session can continue with on the server: its own, and not terminal ones (they can't be told the conversation).
    public var takeoverAgents: [AgentInfo] { agents.filter { $0.node == nil && !$0.terminal } }

    /// Moves a node's project session to the server; returns the server's refusal, if any.
    @discardableResult
    public func continueOnServer(_ sessionID: String, agent: String?) async -> String? {
        await call(.sessionTakeover(id: Self.newID(), sessionId: sessionID, agent: agent))
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
        defer {
            // Answers someone is waiting for: the state above is already updated when they resume.
            if let id = message.requestID, let waiter = awaiting.removeValue(forKey: id) {
                if case .error(let code, let text, _) = message {
                    waiter.resume(returning: Self.describe(code: code, message: text))
                } else {
                    waiter.resume(returning: nil)
                }
            }
        }
        if case .error(_, _, let id?) = message, awaiting[id] != nil { return }
        switch message {
        case .sessionChangesResult(_, let sessionID, let changeSet):
            changes[sessionID] = changeSet
        case .projectListResult(_, let projects), .projectsUpdated(let projects):
            self.projects = projects
        case .scheduleListResult(_, let schedules), .schedulesUpdated(let schedules):
            self.schedules = schedules
        case .usageReportResult(_, let report):
            usage = report
        case .diagnosticsResult(_, let report):
            diagnosticsReport = report
        case .sessionPullRequestResult(_, _, let pullRequest):
            pullRequestAnswer = pullRequest
        case .alertsResult(_, let settings):
            alerts = settings
        case .boardResult(_, let projectId, let cards), .boardUpdated(let projectId, let cards):
            boards[projectId] = cards
        case .projectMapResult(_, let projectId, let text):
            projectMaps[projectId] = text
        case .githubStatusResult(_, let status):
            github = status
        case .githubCode(_, let code, let url):
            githubCodeAnswer = GitHubDeviceCode(code: code, url: url)
        case .githubUpdated(let status, let error):
            github = status
            githubError = error
        case .agentRegistryResult(let id, let agents, let status, let studio) where id == latestRegistryRequest:
            if offeredAgents != agents { offeredAgents = agents }
            if ollama != status { ollama = status }
            if lmStudio != studio { lmStudio = studio }
        case .agentLoginStarted(_, let agent, let url, let code, let needsCode):
            agentLoginAnswer = AgentLoginPrompt(agent: agent, url: url, code: code, needsCode: needsCode)
        case .agentLoginFinished(let agent, let signedIn, let error):
            agentLoginOutcomes[agent] = error.map { .failed($0) } ?? (signedIn ? .signedIn : .failed(L("The sign-in didn't finish.", "Giriş tamamlanmadı.")))
            Task { await loadAgentConfigs() }
        case .webStatusResult(_, let web):
            webAccess = web
        case .webPaired(_, let code, let expiresAt):
            pairingAnswer = WebPairing(code: code, expiresAt: SessionGroups.parse(expiresAt) ?? .now.addingTimeInterval(600))
        case .portListResult(_, let ports):
            self.ports = ports
        case .terminalOpened(_, let terminalID, let sessionID, let backlog):
            if terminals[sessionID]?.id != terminalID {
                terminals[sessionID] = TerminalState(id: terminalID, output: backlog)
            }
        case .terminalOutput(let terminalID, let data):
            guard let sessionID = terminals.first(where: { $0.value.id == terminalID })?.key else { break }
            var text = terminals[sessionID]!.output + data
            if text.count > Self.terminalChars { text = String(text.suffix(Self.terminalChars)) }
            terminals[sessionID]!.output = text
        case .terminalExited(let terminalID):
            if let sessionID = terminals.first(where: { $0.value.id == terminalID })?.key { terminals[sessionID]!.exited = true }
        case .sessionListResult(_, let list):
            sessions = list.sorted { $0.createdAt > $1.createdAt }
            for session in list { requestHistory(session.id) }
        case .sessionCreated(let requestID, let session):
            upsert(session)
            if events[session.id] == nil { events[session.id] = [] }
            if pendingCreates.remove(requestID) != nil { lastCreatedSessionID = session.id }
        case .sessionUpdated(let session):
            let previous = self.session(session.id)?.status
            upsert(session)
            if let alert = SessionAlert.on(session, from: previous, events: events[session.id] ?? [], agentName: agentName(session.agent)) {
                onAlert?(alert)
            }
        case .sessionHistoryResult(_, let sessionID, let history):
            events[sessionID] = history
        case .sessionEvent(let sessionID, let event):
            append(event, to: sessionID)
        case .agentListResult(let id, let configs, let nodes):
            agentConfigs = configs
            self.nodes = nodes
            if id == pendingAgentSave { pendingAgentSave = nil }
        case .agentsUpdated(let agents):
            self.agents = agents
        case .nodeInvited(let id, let name, let code, let expiresAt) where id == pendingInvite:
            pendingInvite = nil
            nodeInvite = (name, code, expiresAt)
        case .nodeListResult(_, let nodes, let addresses), .nodesUpdated(let nodes, let addresses):
            nodeInfos = nodes
            hubAddresses = addresses
            onHubAddresses?(addresses)
            // A node coming or going changes which nodes agents can be assigned to.
            if !agentConfigs.isEmpty { Task { await loadAgentConfigs() } }
        case .roleListResult(_, let roles):
            self.roles = roles
        case .teamListResult(_, let teams):
            self.teams = teams.sorted { $0.createdAt > $1.createdAt }
        case .teamCreated(let requestID, let team):
            upsertTeam(team)
            if pendingTeams.remove(requestID) != nil { lastCreatedSessionID = team.sessionIds.first }
        case .teamUpdated(let team):
            upsertTeam(team)
        case .mcpListResult(_, let servers):
            mcpServers = servers
        case .sessionSearchResult(let id, let hits) where id == latestSearch:
            searchHits = hits
            isSearching = false
        case .error(let code, let message, let id?) where id == pendingAgentSave:
            pendingAgentSave = nil
            agentSaveError = Self.describe(code: code, message: message)
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

    private func upsertTeam(_ team: TeamInfo) {
        if let index = teams.firstIndex(where: { $0.id == team.id }) {
            teams[index] = team
        } else {
            teams.insert(team, at: 0)
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
            lastError = Self.couldntSend(error)
        }
    }

    private static func newID() -> String { UUID().uuidString }

    /// The server's error codes in the app's language; unknown codes keep the server's text.
    static func describe(code: String, message: String) -> String {
        switch code {
        case "session_busy": L("The agent is still working on your last message; you can write when it's done.", "Ajan hâlâ önceki mesajınız üzerinde çalışıyor; bitince yazabilirsiniz.")
        case "session_unavailable": L("This session can't take messages right now.", "Bu oturum şu an mesaj alamıyor.")
        case "unknown_session": L("This session wasn't found on the server.", "Bu oturum sunucuda bulunamadı.")
        case "unknown_agent": L("This agent isn't installed on the server.", "Bu ajan sunucuda kurulu değil.")
        case "unknown_request": L("This approval request has expired.", "Bu izin isteği artık geçerli değil.")
        case "node_offline": L("The machine (node) this agent runs on isn't connected. The session continues when it's back.", "Ajanın çalıştığı makine (node) şu an bağlı değil. Bağlandığında oturum kaldığı yerden devam eder.")
        default: message
        }
    }
}
