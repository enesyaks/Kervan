import Foundation
import Network
import Observation

/// Makes a port on the server reachable as localhost on this Mac: each connection to the local port
/// travels over a WebSocket to the server's /v1/tunnel, which connects to the port there. Dev servers
/// usually listen only on the server's own localhost, so this is the way to open them in a browser.
@MainActor
@Observable
final class PortForwarder {
    struct Forward: Identifiable, Equatable {
        /// The port on the server.
        let remote: Int
        /// Where it answers on this Mac; the same number when it was free.
        let local: UInt16
        var id: Int { remote }
        var url: URL { URL(string: "http://localhost:\(local)")! }
    }

    private(set) var forwards: [Int: Forward] = [:]
    private var listeners: [Int: NWListener] = [:]
    private let queue = DispatchQueue(label: "kervan.forward")

    /// Starts forwarding `port` (or finds the running forward) and returns where it answers here.
    /// `request` is the authorized WebSocket request for the server side of the tunnel.
    func open(_ port: Int, request: URLRequest) async throws -> Forward {
        if let forward = forwards[port] { return forward }
        let listener: NWListener
        do {
            listener = try await listen(on: UInt16(port), request: request)
        } catch {
            // The same number is taken on this Mac (often by its own dev server): any free port will do.
            listener = try await listen(on: 0, request: request)
        }
        let forward = Forward(remote: port, local: listener.port?.rawValue ?? UInt16(port))
        listeners[port] = listener
        forwards[port] = forward
        return forward
    }

    func stop(_ port: Int) {
        listeners.removeValue(forKey: port)?.cancel()
        forwards.removeValue(forKey: port)
    }

    func stopAll() {
        for port in Array(listeners.keys) { stop(port) }
    }

    private func listen(on port: UInt16, request: URLRequest) async throws -> NWListener {
        let parameters = NWParameters.tcp
        // Only this Mac may use the forward; it carries the server's access with it.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { connection in
            TunnelConnection(local: connection, request: request).start()
        }
        let queue = self.queue
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let once = ResumeOnce(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: once.resume(with: .success(()))
                case .failed(let error): once.resume(with: .failure(error))
                case .waiting(let error):
                    listener.cancel()
                    once.resume(with: .failure(error))
                default: break
                }
            }
            listener.start(queue: queue)
        }
        return listener
    }
}

/// One forwarded connection: local TCP bytes ↔ WebSocket binary frames.
private final class TunnelConnection: @unchecked Sendable {
    private let local: NWConnection
    private let remote: URLSessionWebSocketTask
    private let queue = DispatchQueue(label: "kervan.tunnel")

    init(local: NWConnection, request: URLRequest) {
        self.local = local
        remote = URLSession.shared.webSocketTask(with: request)
        remote.maximumMessageSize = 16 * 1024 * 1024
    }

    func start() {
        local.start(queue: queue)
        remote.resume()
        readLocal()
        readRemote()
    }

    private func readLocal() {
        local.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, complete, error in
            if let data, !data.isEmpty {
                remote.send(.data(data)) { [self] sendError in
                    if sendError != nil { close() } else if !complete && error == nil { readLocal() }
                }
                if complete || error != nil { close(after: 0.5) }
                return
            }
            if complete || error != nil { close() } else { readLocal() }
        }
    }

    private func readRemote() {
        remote.receive { [self] result in
            switch result {
            case .success(let message):
                let data: Data = switch message {
                case .data(let data): data
                case .string(let text): Data(text.utf8)
                @unknown default: Data()
                }
                local.send(content: data, completion: .contentProcessed { [self] error in
                    if error != nil { close() } else { readRemote() }
                })
            case .failure:
                // The server closed its side: let what was sent drain, then end ours.
                local.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [self] _ in close() })
            }
        }
    }

    private func close(after delay: TimeInterval = 0) {
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            remote.cancel(with: .normalClosure, reason: nil)
            local.cancel()
        }
    }
}

/// Resumes a continuation once, whatever calls it later.
private final class ResumeOnce: @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, any Error>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<Void, any Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<Void, any Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}
