import Foundation
import KervanKit
import Observation

@MainActor
@Observable
final class AppModel {
    static let appVersion = "0.1.0"
    private static let serverKey = "serverAddress"

    var serverInput: String {
        didSet { UserDefaults.standard.set(serverInput, forKey: Self.serverKey) }
    }
    var tokenInput = ""
    var selectedSessionID: String?
    var showFiles = false
    var showNewTeam = false
    /// A message to scroll to and flash, set by picking a search hit; ChatView clears it.
    var focus: (sessionID: String, seq: Int)?

    let connection: KervanConnection
    let store: SessionStore
    private(set) var activeAddress: ServerAddress?
    private var activeToken: String?
    /// True from the first handshake until the user disconnects; brief drops keep the chat on screen.
    private(set) var isLinked = false

    /// KERVAN_SERVER / KERVAN_TOKEN override the saved values for local development
    /// (`KERVAN_TOKEN=… swift run Kervan`) and keep the Keychain out of it.
    private let environment = ProcessInfo.processInfo.environment
    private var usesEnvironmentToken: Bool { environment["KERVAN_TOKEN"] != nil }

    init() {
        let connection = KervanConnection(client: PeerInfo(name: "Kervan for Mac", version: Self.appVersion))
        let store = SessionStore { try await connection.send($0) }
        self.connection = connection
        self.store = store
        serverInput = environment["KERVAN_SERVER"] ?? UserDefaults.standard.string(forKey: Self.serverKey) ?? "kervan"

        connection.onMessage = { store.handle($0) }
        connection.onConnected = { [weak self] agents in
            self?.isLinked = true
            Task { await store.connected(agents: agents) }
        }
        Task { await restoreToken() }
    }

    var address: ServerAddress? { ServerAddress(serverInput) }

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
            // Keychain calls can block on a system permission prompt; keep them off the main thread.
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
        isLinked = false
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

    /// Opens the new-session sheet; the session starts from there.
    func newSession(agent: String? = nil) {
        guard let agent = agent ?? defaultAgent?.id else { return }
        newSessionAgent = agent
    }

    func startSession(agent: String, skills: [String], mcpServers: [String], orchestrate: Bool = false) {
        lastAgentID = agent
        UserDefaults.standard.set(skills, forKey: Self.lastSkillsKey)
        UserDefaults.standard.set(mcpServers, forKey: Self.lastMcpKey)
        UserDefaults.standard.set(orchestrate, forKey: Self.lastOrchestrateKey)
        Task { await store.create(agent: agent, skills: skills, mcpServers: mcpServers, orchestrate: orchestrate) }
    }

    private func restoreToken() async {
        let token = if let fromEnvironment = environment["KERVAN_TOKEN"] {
            fromEnvironment
        } else {
            await Task.detached { TokenStore.read() }.value
        }
        guard let token, tokenInput.isEmpty else { return }
        tokenInput = token
        if canConnect { connect() }
    }
}
