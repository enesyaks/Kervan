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

    let connection = KervanConnection(client: PeerInfo(name: "Kervan for Mac", version: AppModel.appVersion))
    private(set) var activeAddress: ServerAddress?

    /// KERVAN_SERVER / KERVAN_TOKEN override the saved values for local development
    /// (`KERVAN_TOKEN=… swift run Kervan`) and keep the Keychain out of it.
    private let environment = ProcessInfo.processInfo.environment
    private var usesEnvironmentToken: Bool { environment["KERVAN_TOKEN"] != nil }

    init() {
        serverInput = environment["KERVAN_SERVER"] ?? UserDefaults.standard.string(forKey: Self.serverKey) ?? "kervan"
        Task { await restoreToken() }
    }

    var address: ServerAddress? { ServerAddress(serverInput) }

    var canConnect: Bool { address != nil && !trimmedToken.isEmpty }

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
