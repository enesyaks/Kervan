import Foundation
import Observation

public enum ConnectionFailure: Equatable, Sendable {
    case unauthorized
    case unsupportedProtocol(String)
    case unreachable(String)

    /// Only network trouble is worth retrying; a wrong token or version won't fix itself.
    public var isRetryable: Bool {
        if case .unreachable = self { return true }
        return false
    }
}

public enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting(attempt: Int)
    case connected(server: PeerInfo)
    case retrying(at: Date, attempt: Int, reason: ConnectionFailure)
    case failed(ConnectionFailure)

    /// The server's name and version while connected.
    public var server: PeerInfo? {
        if case .connected(let server) = self { server } else { nil }
    }
}

/// Owns one WebSocket to the server: handshake, keep-alive pings, and reconnect with backoff.
@MainActor
@Observable
public final class KervanConnection {
    public private(set) var state: ConnectionState = .disconnected
    public private(set) var latency: Duration?

    /// Called after every successful handshake with the server's agent list.
    @ObservationIgnored public var onConnected: (@MainActor ([AgentInfo]) -> Void)?
    /// Every server message other than the handshake and pongs.
    @ObservationIgnored public var onMessage: (@MainActor (ServerMessage) -> Void)?

    private let client: PeerInfo
    private let session: URLSession
    private var runTask: Task<Void, Never>?
    private var activeTask: URLSessionWebSocketTask?
    private var pendingPings: [String: ContinuousClock.Instant] = [:]

    private static let pingInterval: Duration = .seconds(15)
    /// Unanswered pings before the socket is considered dead (covers silent drops after sleep).
    private static let maxMissedPings = 3

    public init(client: PeerInfo, session: URLSession = .shared) {
        self.client = client
        self.session = session
    }

    public func connect(to address: ServerAddress, token: String) {
        disconnect()
        runTask = Task { await run(address: address, token: token) }
    }

    public func send(_ message: ClientMessage) async throws {
        guard let activeTask else { throw URLError(.notConnectedToInternet) }
        try await activeTask.send(.string(message.jsonString()))
    }

    public func disconnect() {
        runTask?.cancel()
        runTask = nil
        activeTask = nil
        state = .disconnected
        latency = nil
        pendingPings.removeAll()
    }

    private func run(address: ServerAddress, token: String) async {
        var attempt = 0
        while !Task.isCancelled {
            attempt += 1
            state = .connecting(attempt: attempt)
            let (failure, wasConnected) = await runSession(address: address, token: token)
            if Task.isCancelled { return }
            latency = nil
            guard failure.isRetryable else {
                state = .failed(failure)
                return
            }
            if wasConnected { attempt = 1 }
            let delay = Backoff.delay(attempt: attempt)
            state = .retrying(at: Date().addingTimeInterval(delay), attempt: attempt, reason: failure)
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    private func runSession(address: ServerAddress, token: String) async -> (ConnectionFailure, wasConnected: Bool) {
        var request = URLRequest(url: address.url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        let task = session.webSocketTask(with: request)
        task.resume()
        pendingPings.removeAll()

        var connected = false
        var pinger: Task<Void, Never>?
        defer {
            pinger?.cancel()
            if activeTask === task { activeTask = nil }
            task.cancel(with: .goingAway, reason: nil)
        }

        do {
            try await task.send(.string(ClientMessage.hello(client: client).jsonString()))
            while !Task.isCancelled {
                guard case .string(let text) = try await task.receive(),
                      let message = try? ServerMessage.decode(text)
                else { continue }

                switch message {
                case .welcome(_, let server, let agents):
                    connected = true
                    activeTask = task
                    state = .connected(server: server)
                    pinger = Task { await pingLoop(task) }
                    onConnected?(agents)
                case .pong(let id):
                    if let sentAt = pendingPings.removeValue(forKey: id) {
                        latency = ContinuousClock.now - sentAt
                    }
                case .error(let code, let message, _) where code == "unsupported_protocol":
                    return (.unsupportedProtocol(message), connected)
                case .unknown:
                    continue
                default:
                    onMessage?(message)
                }
            }
            return (.unreachable("cancelled"), connected)
        } catch {
            if (task.response as? HTTPURLResponse)?.statusCode == 401 { return (.unauthorized, connected) }
            if task.closeCode.rawValue == 4000 { return (.unsupportedProtocol("protocol mismatch"), connected) }
            return (.unreachable(error.localizedDescription), connected)
        }
    }

    private func pingLoop(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            if pendingPings.count >= Self.maxMissedPings {
                task.cancel(with: .goingAway, reason: nil)  // makes receive() throw → reconnect
                return
            }
            let id = UUID().uuidString
            pendingPings[id] = .now
            if let frame = try? ClientMessage.ping(id: id).jsonString() {
                try? await task.send(.string(frame))
            }
            try? await Task.sleep(for: Self.pingInterval)
        }
    }
}
