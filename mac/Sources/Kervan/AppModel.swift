import Foundation
import KervanKit
import Observation

@MainActor
@Observable
final class AppModel {
    static let appVersion = KervanVersion.current
    private static let serverKey = "serverAddress"
    private static let onboardedKey = "onboarded"

    var serverInput: String {
        didSet { UserDefaults.standard.set(serverInput, forKey: Self.serverKey) }
    }
    var tokenInput = ""
    var selectedSessionID: String? {
        didSet { if let selectedSessionID { notifier?.clear(selectedSessionID) } }
    }
    private var notifier: Notifier?
    /// The side panel next to a chat, and which of its pages shows.
    var showFiles = false
    var panel: SessionPanel = .files
    /// Server ports forwarded to this Mac, for the Preview panel.
    let forwarder = PortForwarder()
    /// New app releases from GitHub.
    let updater = AppUpdater()
    /// Updates the connected hub over SSH when it runs an older version than this app carries.
    let serverUpdater = HubInstaller()
    var showServerUpdate = false
    var showReportProblem = false
    /// The selected session's whole team (or lead and helpers) side by side, instead of its chat alone.
    var showCrew = false
    var showNewTeam = false
    /// The guided first run, over the whole window: shown until a server has answered once.
    /// KERVAN_ONBOARDING=1 shows it anyway, for checking the flow.
    var showOnboarding = false
    /// The opening animation, once per launch; KERVAN_NO_INTRO=1 skips it for development.
    var showIntro = ProcessInfo.processInfo.environment["KERVAN_NO_INTRO"] == nil
        && (UserDefaults.standard.object(forKey: AppModel.introKey) as? Bool ?? true)
    static let introKey = "showIntro"
    /// A message to scroll to and flash, set by picking a search hit; ChatView clears it.
    var focus: (sessionID: String, seq: Int)?

    let connection: KervanConnection
    let store: SessionStore
    private(set) var activeAddress: ServerAddress?
    /// The token the connection uses; a server update keeps it.
    private(set) var activeToken: String?
    /// True from the first handshake until the user disconnects; brief drops keep the chat on screen.
    private(set) var isLinked = false

    /// KERVAN_SERVER / KERVAN_TOKEN override the saved values for local development
    /// (`KERVAN_TOKEN=… swift run Kervan`) and leave the saved key alone.
    private let environment = ProcessInfo.processInfo.environment
    private var usesEnvironmentToken: Bool { environment["KERVAN_TOKEN"] != nil }

    init() {
        let connection = KervanConnection(client: PeerInfo(name: "Kervan for Mac", version: Self.appVersion))
        let store = SessionStore { try await connection.send($0) }
        self.connection = connection
        self.store = store
        serverInput = environment["KERVAN_SERVER"] ?? UserDefaults.standard.string(forKey: Self.serverKey) ?? ""

        connection.onMessage = { store.handle($0) }
        showOnboarding = environment["KERVAN_ONBOARDING"] != nil
            || (!UserDefaults.standard.bool(forKey: Self.onboardedKey) && environment["KERVAN_SERVER"] == nil
                && UserDefaults.standard.string(forKey: Self.serverKey) == nil)

        connection.onConnected = { [weak self] agents in
            self?.isLinked = true
            UserDefaults.standard.set(true, forKey: Self.onboardedKey)
            Task { await store.connected(agents: agents) }
        }
        // A bare `swift run` binary has no bundle id, and notifications need one.
        if Bundle.main.bundleIdentifier != nil {
            let notifier = Notifier { [weak self] sessionID in
                self?.showCrew = false
                self?.selectedSessionID = sessionID
            }
            self.notifier = notifier
            store.onAlert = { [weak self] alert in notifier.post(alert, selected: self?.selectedSessionID) }
        }
        Task { await restoreToken() }
        updater.checkIfDue()
    }

    var address: ServerAddress? { ServerAddress(serverInput) }

    /// The connected server's version when it is older than the server this app carries.
    var outdatedServer: String? {
        guard case .connected(let server) = connection.state,
              let theirs = SemanticVersion(server.version), let mine = SemanticVersion(KervanVersion.current),
              theirs < mine
        else { return nil }
        return server.version
    }

    var canConnect: Bool { address != nil && !trimmedToken.isEmpty }

    var canCreateSession: Bool {
        if case .connected = connection.state { return !store.agents.isEmpty }
        return false
    }

    private var trimmedToken: String { tokenInput.trimmingCharacters(in: .whitespacesAndNewlines) }

    func connect() {
        guard let address, canConnect else { return }
        let token = trimmedToken
        if !usesEnvironmentToken {
            // File work, kept off the main thread.
            Task.detached { TokenStore.save(token) }
        }
        activeAddress = address
        activeToken = token
        connection.connect(to: address, token: token)
    }

    /// HTTP access to session workspaces, with the same server and token as the socket.
    var fileClient: FileClient? {
        guard let activeAddress, let activeToken else { return nil }
        return FileClient(address: activeAddress, token: activeToken)
    }

    func disconnect() {
        connection.disconnect()
        forwarder.stopAll()
        isLinked = false
    }

    /// The WebSocket request for one forwarded connection to `port` on the server.
    func tunnelRequest(port: Int) -> URLRequest? {
        guard let activeAddress, let activeToken,
              var components = URLComponents(url: activeAddress.url, resolvingAgainstBaseURL: false)
        else { return nil }
        components.path = "/v1/tunnel"
        components.queryItems = [URLQueryItem(name: "port", value: String(port))]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(activeToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Opens a side panel page for the selected chat.
    func showPanel(_ panel: SessionPanel) {
        if showFiles && self.panel == panel {
            showFiles = false
        } else {
            self.panel = panel
            showFiles = true
        }
    }

    func open(sessionID: String, at seq: Int) {
        focus = (sessionID, seq)
        selectedSessionID = sessionID
    }

    private static let lastAgentKey = "lastAgent"

    /// Observable copy of the last agent used, so menus that name the default redraw when it changes.
    private var lastAgentID = UserDefaults.standard.string(forKey: AppModel.lastAgentKey) {
        didSet { UserDefaults.standard.set(lastAgentID, forKey: Self.lastAgentKey) }
    }

    /// The agent ⌘N starts: the one used last if the server still offers it, else the server's default.
    var defaultAgent: AgentInfo? {
        store.agents.first { $0.id == lastAgentID } ?? store.agents.first
    }

    static let lastSkillsKey = "lastSkills"
    static let lastMcpKey = "lastMcpServers"
    static let lastOrchestrateKey = "lastOrchestrate"

    /// Set to an agent id to show the new-session sheet with that agent picked.
    var newSessionAgent: String?
    /// The project the new-session sheet starts in; nil for a folder of the session's own.
    var newSessionProject: String?

    /// Opens the new-session sheet; the session starts from there.
    func newSession(agent: String? = nil, project: String? = nil) {
        guard let agent = agent ?? defaultAgent?.id else { return }
        newSessionProject = project
        newSessionAgent = agent
    }

    func startSession(
        agent: String, skills: [String], mcpServers: [String], orchestrate: Bool = false, budgetUsd: Double? = nil, projectId: String? = nil,
        shared: Bool = false, split: Bool = false
    ) {
        lastAgentID = agent
        UserDefaults.standard.set(skills, forKey: Self.lastSkillsKey)
        UserDefaults.standard.set(mcpServers, forKey: Self.lastMcpKey)
        UserDefaults.standard.set(orchestrate, forKey: Self.lastOrchestrateKey)
        Task {
            await store.create(
                agent: agent, skills: skills, mcpServers: mcpServers, orchestrate: orchestrate, budgetUsd: budgetUsd, projectId: projectId,
                shared: shared, split: split
            )
        }
    }

    // Sidebar entries that aren't sessions share its selection, under these tags.
    static let usagePage = "page:usage"
    static let schedulesPage = "page:schedules"
    static let projectPrefix = "project:"
    static func projectPage(_ id: String) -> String { projectPrefix + id }
}

/// The pages of the panel next to a chat.
enum SessionPanel: String, CaseIterable, Identifiable {
    case files, changes, terminal, preview
    var id: String { rawValue }

    var title: String {
        switch self {
        case .files: L("Files", "Dosyalar")
        case .changes: L("Changes", "Değişiklikler")
        case .terminal: "Terminal"
        case .preview: L("Preview", "Önizleme")
        }
    }

    var symbol: String {
        switch self {
        case .files: "folder"
        case .changes: "plusminus"
        case .terminal: "terminal"
        case .preview: "safari"
        }
    }
}

extension AppModel {
    fileprivate func restoreToken() async {
        let token = if let fromEnvironment = ProcessInfo.processInfo.environment["KERVAN_TOKEN"] {
            fromEnvironment
        } else {
            await Task.detached { TokenStore.read() }.value
        }
        guard let token, tokenInput.isEmpty else { return }
        tokenInput = token
        if canConnect { connect() }
    }
}
