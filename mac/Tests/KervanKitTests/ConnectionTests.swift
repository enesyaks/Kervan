import Foundation
import Network
import Testing
@testable import KervanKit

/// A real server on the loopback: speaks WebSocket, or answers the upgrade with an HTTP status.
private final class FakeHub: @unchecked Sendable {
    enum Mode {
        case webSocket
        case refuse(status: String)
    }

    final class Client: @unchecked Sendable {
        let connection: NWConnection
        init(_ connection: NWConnection) { self.connection = connection }

        func send(_ text: String) {
            let context = NWConnection.ContentContext(identifier: "text", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
            connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .idempotent)
        }

        func close(code: UInt16) {
            let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
            metadata.closeCode = .privateCode(code)
            let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
            connection.send(content: nil, contentContext: context, isComplete: true, completion: .idempotent)
        }

        func drop() { connection.cancel() }
    }

    private let queue = DispatchQueue(label: "fake-hub")
    private let lock = NSLock()
    private var listener: NWListener?
    private var authorization: String?
    private var texts: [String] = []
    private var connections = 0
    private let onText: @Sendable (String, Client) -> Void

    var seenAuthorization: String? { lock.withLock { authorization } }
    var received: [String] { lock.withLock { texts } }
    var connectionCount: Int { lock.withLock { connections } }

    init(_ mode: Mode = .webSocket, onText: @escaping @Sendable (String, Client) -> Void = FakeHub.friendly) {
        self.onText = onText
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        if case .webSocket = mode {
            let options = NWProtocolWebSocket.Options()
            options.setClientRequestHandler(queue) { [weak self] _, headers in
                self?.lock.withLock { self?.authorization = headers.first { $0.name.lowercased() == "authorization" }?.value }
                return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
            }
            parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        }
        let listener = try! NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.lock.withLock { self.connections += 1 }
            connection.start(queue: self.queue)
            switch mode {
            case .webSocket: self.read(from: Client(connection))
            case .refuse(let status):
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                    let answer = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(answer.utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
    }

    /// Welcomes a hello and answers pings.
    static let friendly: @Sendable (String, Client) -> Void = { text, client in
        if text.contains(#""type":"hello""#) { client.send(welcome) }
        if text.contains(#""type":"ping""#), let id = (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["id"] as? String {
            client.send(#"{"type":"pong","id":"\#(id)"}"#)
        }
    }

    static let welcome = #"{"type":"welcome","protocol":1,"server":{"name":"kervan","version":"9"},"agents":["claude"],"agentDetails":[{"id":"claude","name":"Claude Code"}]}"#

    private func read(from client: Client) {
        client.connection.receiveMessage { [weak self] data, context, _, error in
            guard let self, error == nil else { return }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if let data, metadata?.opcode == .text {
                let text = String(decoding: data, as: UTF8.self)
                self.lock.withLock { self.texts.append(text) }
                self.onText(text, client)
            }
            self.read(from: client)
        }
    }

    func start() async throws -> ServerAddress {
        let listener = try #require(self.listener)
        let port: UInt16 = await withCheckedContinuation { continuation in
            let once = Once(continuation)
            listener.stateUpdateHandler = { [weak listener] state in
                if case .ready = state { once.resume(listener?.port?.rawValue ?? 0) }
            }
            listener.start(queue: queue)
        }
        return try #require(ServerAddress("127.0.0.1:\(port)"))
    }

    func stop() {
        listener?.cancel()
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<UInt16, Never>?
        init(_ continuation: CheckedContinuation<UInt16, Never>) { self.continuation = continuation }
        func resume(_ value: UInt16) {
            lock.withLock {
                continuation?.resume(returning: value)
                continuation = nil
            }
        }
    }
}

@MainActor @Suite struct ConnectionTests {
    private func makeConnection() -> KervanConnection {
        KervanConnection(client: PeerInfo(name: "tests", version: "1"), session: URLSession(configuration: .ephemeral))
    }

    private func until(_ what: Comment, within seconds: Double = 8, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), what)
    }

    @Test func introducesItselfWithTheKeyAndReportsTheServer() async throws {
        let hub = FakeHub()
        defer { hub.stop() }
        let connection = makeConnection()
        defer { connection.disconnect() }
        var agents: [AgentInfo] = []
        connection.onConnected = { agents = $0 }

        connection.connect(to: try await hub.start(), token: "the-key")
        await until("connected") { connection.state.server != nil }

        #expect(connection.state.server == PeerInfo(name: "kervan", version: "9"))
        #expect(agents.map(\.id) == ["claude"])
        #expect(hub.seenAuthorization == "Bearer the-key")
        #expect(hub.received.first?.contains(#""type":"hello""#) == true)
        #expect(hub.received.first?.contains("the-key") == false, "the key goes in the header alone")
    }

    @Test func measuresTheRoundTripFromAPong() async throws {
        let hub = FakeHub()
        defer { hub.stop() }
        let connection = makeConnection()
        defer { connection.disconnect() }
        connection.connect(to: try await hub.start(), token: "k")
        await until("a latency") { connection.latency != nil }
    }

    @Test func passesOnServerMessagesAndIgnoresWhatItCantRead() async throws {
        let hub = FakeHub { text, client in
            guard text.contains(#""type":"hello""#) else { return }
            client.send(FakeHub.welcome)
            client.send("not json")
            client.send(#"{"type":"from.the.future"}"#)
            client.send(#"{"type":"pong","id":"never-asked"}"#)
            client.send(#"{"type":"ok","id":"r1"}"#)
        }
        defer { hub.stop() }
        let connection = makeConnection()
        defer { connection.disconnect() }
        var messages: [ServerMessage] = []
        connection.onMessage = { messages.append($0) }
        connection.connect(to: try await hub.start(), token: "k")
        await until("the message") { !messages.isEmpty }
        #expect(messages == [.ok(id: "r1")])
        #expect(connection.latency == nil, "a pong nobody asked for says nothing")
    }

    @Test func sendsOnceConnectedAndNotBefore() async throws {
        let hub = FakeHub()
        defer { hub.stop() }
        let connection = makeConnection()
        defer { connection.disconnect() }
        await #expect(throws: URLError.self) { try await connection.send(.ping(id: "early")) }
        connection.connect(to: try await hub.start(), token: "k")
        await until("connected") { connection.state.server != nil }
        try await connection.send(.sessionList(id: "mine"))
        await until("arrived") { hub.received.contains { $0.contains(#""id":"mine""#) } }
    }

    @Test func stopsTryingOnAWrongKey() async throws {
        let hub = FakeHub(.refuse(status: "401 Unauthorized"))
        defer { hub.stop() }
        let connection = makeConnection()
        defer { connection.disconnect() }
        var retries = 0
        connection.onRetrying = { _ in retries += 1 }
        connection.connect(to: try await hub.start(), token: "wrong")
        await until("failed") { connection.state == .failed(.unauthorized) }
        try await Task.sleep(for: .milliseconds(1200))
        #expect(hub.connectionCount == 1 && retries == 0, "a wrong key won't fix itself")
    }

    @Test func explainsAServerThatOnlyAnswersOverTailscale() async throws {
        let hub = FakeHub(.refuse(status: "403 Forbidden"))
        defer { hub.stop() }
        let connection = makeConnection()
        defer { connection.disconnect() }
        connection.connect(to: try await hub.start(), token: "k")
        await until("retrying") {
            if case .retrying(_, _, .unreachable(let reason)) = connection.state { return reason.contains(".ts.net") }
            return false
        }
    }

    @Test func stopsTryingWhenTheServerRefusesTheProtocol() async throws {
        let hub = FakeHub { text, client in
            if text.contains(#""type":"hello""#) { client.send(#"{"type":"error","code":"unsupported_protocol","message":"too old"}"#) }
        }
        defer { hub.stop() }
        let connection = makeConnection()
        defer { connection.disconnect() }
        connection.connect(to: try await hub.start(), token: "k")
        await until("failed") { connection.state == .failed(.unsupportedProtocol("too old")) }
    }

    @Test func readsTheProtocolCloseCode() async throws {
        let hub = FakeHub { text, client in
            if text.contains(#""type":"hello""#) { client.close(code: 4000) }
        }
        defer { hub.stop() }
        let connection = makeConnection()
        defer { connection.disconnect() }
        connection.connect(to: try await hub.start(), token: "k")
        await until("failed") { connection.state == .failed(.unsupportedProtocol("protocol mismatch")) }
    }

    @Test func comesBackAfterADroppedConnection() async throws {
        let dropped = DropOnce()
        let hub = FakeHub { text, client in
            // Its first ping shows the app has the welcome, so the connection was really up.
            if text.contains(#""type":"ping""#), dropped.first() { client.drop() } else { FakeHub.friendly(text, client) }
        }
        defer { hub.stop() }
        let connection = makeConnection()
        defer { connection.disconnect() }
        var attempts: [Int] = []
        connection.onRetrying = { attempts.append($0) }
        connection.connect(to: try await hub.start(), token: "k")
        await until("retrying") { !attempts.isEmpty }
        await until("connected again") { connection.state.server != nil && hub.connectionCount == 2 }
    }

    @Test func retriesWhenNothingListens() async throws {
        let hub = FakeHub()
        let address = try await hub.start()
        hub.stop()
        try await Task.sleep(for: .milliseconds(100))
        let connection = makeConnection()
        defer { connection.disconnect() }
        var attempts: [Int] = []
        connection.onRetrying = { attempts.append($0) }
        connection.connect(to: address, token: "k")
        await until("retrying") { !attempts.isEmpty }
        if case .retrying(let at, _, let reason) = connection.state {
            #expect(reason.isRetryable)
            #expect(at > Date().addingTimeInterval(-1))
        }
    }

    @Test func disconnectingEndsTheTrying() async throws {
        let hub = FakeHub()
        defer { hub.stop() }
        let connection = makeConnection()
        connection.connect(to: try await hub.start(), token: "k")
        await until("connected") { connection.state.server != nil }
        connection.disconnect()
        #expect(connection.state == .disconnected && connection.latency == nil)
        await #expect(throws: URLError.self) { try await connection.send(.ping(id: "late")) }
        try await Task.sleep(for: .milliseconds(1200))
        #expect(hub.connectionCount == 1, "no new attempt")
    }

    @Test func saysWhenAConnectionThatWasUpIsLost() async throws {
        let dropped = DropOnce()
        let hub = FakeHub { text, client in
            // Its first ping shows the app has the welcome, so the connection was really up.
            if text.contains(#""type":"ping""#), dropped.first() { client.drop() } else { FakeHub.friendly(text, client) }
        }
        defer { hub.stop() }
        let connection = makeConnection()
        var losses = 0
        connection.onConnectionLost = { losses += 1 }
        connection.connect(to: try await hub.start(), token: "k")
        await until("lost") { losses == 1 }
        await until("back") { connection.state.server != nil && hub.connectionCount == 2 }
        #expect(losses == 1, "coming back isn't a loss")
        connection.disconnect()
        #expect(losses == 2, "disconnecting ends it too")
    }

    @Test func aServerThatWasNeverReachedHasLostNothing() async throws {
        let hub = FakeHub(.refuse(status: "403 Forbidden"))
        defer { hub.stop() }
        let connection = makeConnection()
        defer { connection.disconnect() }
        var losses = 0
        var attempts = 0
        connection.onConnectionLost = { losses += 1 }
        connection.onRetrying = { _ in attempts += 1 }
        connection.connect(to: try await hub.start(), token: "k")
        await until("retrying") { attempts > 0 }
        #expect(losses == 0)
    }

    @Test func onlyNetworkTroubleIsWorthRetrying() {
        #expect(ConnectionFailure.unreachable("x").isRetryable)
        #expect(!ConnectionFailure.unauthorized.isRetryable)
        #expect(!ConnectionFailure.unsupportedProtocol("x").isRetryable)
    }
}

private final class DropOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func first() -> Bool {
        lock.withLock {
            defer { done = true }
            return !done
        }
    }
}
