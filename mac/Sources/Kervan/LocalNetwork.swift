import Foundation
import Network

/// macOS asks before an app reaches devices on the local network, and only when the app itself tries; the ssh
/// it starts gets "No route to host" until then. So before the setup's SSH, the app knocks on the machine's
/// SSH port once: that brings up the system's question, and the answer says whether to go on.
enum LocalNetwork {
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!

    /// True when the machine answered, false when macOS refused; nil when it is unclear (left to ssh to report).
    static func check(host: String, port: UInt16 = 22, timeout: TimeInterval = 60) async -> Bool? {
        guard let port = NWEndpoint.Port(rawValue: port) else { return nil }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        let answer: Bool? = await withCheckedContinuation { continuation in
            let once = Once(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.resume(true)
                case .waiting:
                    // Waiting for the person to answer the system question, or refused.
                    if connection.currentPath?.unsatisfiedReason == .localNetworkDenied { once.resume(false) }
                case .failed:
                    once.resume(nil)
                default:
                    break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.resume(nil) }
        }
        connection.cancel()
        return answer
    }
}

private final class Once: @unchecked Sendable {
    private var continuation: CheckedContinuation<Bool?, Never>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<Bool?, Never>) { self.continuation = continuation }

    func resume(_ value: Bool?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
