import Foundation

/// Something a person away from the app should hear about.
public struct SessionAlert: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        /// The agent is blocked until someone approves a tool call.
        case waiting
        /// A turn ended and the answer is ready.
        case answered
        case failed
    }

    public let sessionID: String
    public let kind: Kind
    public let title: String
    public let body: String

    /// One per session and kind, so a newer alert replaces an older one in Notification Center.
    public var identifier: String { "\(sessionID)-\(kind.rawValue)" }

    /// The alert a status change deserves, if any. `events` is the session's log, already holding
    /// the event that caused the change (the server records it before updating the status).
    public static func on(
        _ session: SessionInfo, from previous: SessionStatus?, events: [SessionEvent], agentName: String
    ) -> SessionAlert? {
        guard let previous, previous != session.status else { return nil }
        switch session.status {
        case .waiting:
            let request = events.last { if case .permissionRequest = $0.body { true } else { false } }
            guard case .permissionRequest(_, let title, _, _, _)? = request?.body else { return nil }
            return SessionAlert(sessionID: session.id, kind: .waiting, title: "Onay bekliyor: \(session.title)", body: "\(agentName) şunu yapmak istiyor: \(title)")
        case .idle where previous == .running || previous == .waiting:
            // A helper answers its lead, who reads the reply; the user hears from the lead.
            guard session.parentId == nil else { return nil }
            return SessionAlert(sessionID: session.id, kind: .answered, title: "Yanıt hazır: \(session.title)", body: lastReply(events) ?? "\(agentName) turunu bitirdi.")
        case .error:
            return SessionAlert(sessionID: session.id, kind: .failed, title: "Oturum durdu: \(session.title)", body: session.error ?? "Ajan bir hata verdi.")
        default:
            return nil
        }
    }

    /// The first line of the agent's last answer.
    static func lastReply(_ events: [SessionEvent]) -> String? {
        var reply = ""
        for event in events {
            switch event.body {
            case .userMessage: reply = ""
            case .agentMessageChunk(let text): reply += text
            default: break
            }
        }
        let line = reply.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        guard !line.isEmpty else { return nil }
        return line.count > 140 ? String(line.prefix(139)) + "…" : line
    }
}
