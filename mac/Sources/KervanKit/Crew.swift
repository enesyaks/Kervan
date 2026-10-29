import Foundation

/// The sessions that work together: a team's members, or a lead and its helpers.
/// Ordered for the team view: leads first, each followed by its helpers.
public struct Crew: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case team(TeamInfo)
        case lead(String)
    }

    public let kind: Kind
    public let members: [SessionInfo]

    public var title: String {
        switch kind {
        case .team(let team): team.title
        case .lead(let id): members.first { $0.id == id }?.title ?? "Ana ajan"
        }
    }

    /// The crew `sessionID` belongs to, or nil for a session that works alone.
    public static func of(_ sessionID: String, sessions: [SessionInfo], teams: [TeamInfo]) -> Crew? {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return nil }
        let helpers = { (lead: String) in
            sessions.filter { $0.parentId == lead }.sorted { $0.createdAt < $1.createdAt }
        }

        if let teamID = session.teamId, let team = teams.first(where: { $0.id == teamID }) {
            let leads = sessions.filter { $0.teamId == teamID && $0.parentId == nil }.sorted { $0.createdAt < $1.createdAt }
            return Crew(kind: .team(team), members: leads.flatMap { [$0] + helpers($0.id) })
        }
        let leadID = session.parentId ?? session.id
        guard let lead = sessions.first(where: { $0.id == leadID }) else { return nil }
        let crew = [lead] + helpers(leadID)
        return crew.count > 1 ? Crew(kind: .lead(leadID), members: crew) : nil
    }
}

/// One hand-off or turn in the team view's flow strip.
public struct FlowItem: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        /// A lead gave this session a task; `from` is the lead.
        case assigned(from: String)
        /// The user wrote to this session.
        case userWrote
        /// The session finished a turn; `text` is the start of its answer.
        case replied
        /// The session is blocked on the user's approval.
        case waiting
        case failed
    }

    public let sessionID: String
    public let seq: Int
    public let at: String
    public let kind: Kind
    public let text: String

    public var id: String { "\(sessionID)-\(seq)" }

    public init(sessionID: String, seq: Int, at: String, kind: Kind, text: String) {
        self.sessionID = sessionID
        self.seq = seq
        self.at = at
        self.kind = kind
        self.text = text
    }
}

public enum Flow {
    /// The crew's latest hand-offs, oldest first. `events` is each member's event log.
    public static func build(_ members: [SessionInfo], events: [String: [SessionEvent]], limit: Int = 24) -> [FlowItem] {
        var items: [FlowItem] = []
        for member in members {
            var reply = ""
            var open: [String: SessionEvent] = [:]
            for event in events[member.id] ?? [] {
                switch event.body {
                case .userMessage(let text, _, let from):
                    reply = ""
                    let kind: FlowItem.Kind = from.map { .assigned(from: $0) } ?? .userWrote
                    items.append(FlowItem(sessionID: member.id, seq: event.seq, at: event.at, kind: kind, text: clip(text)))
                case .agentMessageChunk(let text):
                    reply += text
                case .turnEnd(let reason) where reason == "end_turn":
                    items.append(FlowItem(sessionID: member.id, seq: event.seq, at: event.at, kind: .replied, text: clip(reply)))
                case .permissionRequest(let requestId, _, _, _, _):
                    open[requestId] = event
                case .permissionResolved(let requestId, _):
                    open[requestId] = nil
                case .error(let message):
                    items.append(FlowItem(sessionID: member.id, seq: event.seq, at: event.at, kind: .failed, text: clip(message)))
                default:
                    break
                }
            }
            // Only approvals still open belong in the strip; answered ones are history.
            for event in open.values {
                guard case .permissionRequest(_, let title, _, _, _) = event.body else { continue }
                items.append(FlowItem(sessionID: member.id, seq: event.seq, at: event.at, kind: .waiting, text: clip(title)))
            }
        }
        let sorted = items.sorted { ($0.at, $0.sessionID, $0.seq) < ($1.at, $1.sessionID, $1.seq) }
        return Array(sorted.suffix(limit))
    }

    static func clip(_ text: String, to length: Int = 80) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return line.count > length ? String(line.prefix(length - 1)) + "…" : line
    }
}
