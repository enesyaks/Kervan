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

    let connection: KervanConnection
    let store: SessionStore
    private(set) var activeAddress: ServerAddress?
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
        connection.connect(to: address, token: token)
    }

    func disconnect() {
        connection.disconnect()
        isLinked = false
    }

    func newSession() {
        guard let agent = store.agents.first else { return }
        Task { await store.create(agent: agent) }
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
