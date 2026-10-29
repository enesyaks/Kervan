import Foundation

/// One row of a chat as the UI shows it. Built from the raw event log by `Transcript.build`.
public enum TranscriptItem: Equatable, Sendable, Identifiable {
    case user(id: Int, text: String)
    case agent(id: Int, text: String)
    case thought(id: Int, text: String)
    case tool(id: Int, toolCallId: String, title: String, kind: String, status: String)
    case permissionRejected(id: Int, title: String)
    case stopped(id: Int, reason: String)
    case error(id: Int, message: String)

    /// The seq of the event that started the row; stable while chunks stream in.
    public var id: Int {
        switch self {
        case .user(let id, _), .agent(let id, _), .thought(let id, _), .tool(let id, _, _, _, _),
             .permissionRejected(let id, _), .stopped(let id, _), .error(let id, _):
            id
        }
    }
}

public enum Transcript {
    /// Folds events into rows: consecutive chunks join into one message, tool updates
    /// patch their tool row, and a normal end of turn adds nothing.
    public static func build(_ events: [SessionEvent]) -> [TranscriptItem] {
        var items: [TranscriptItem] = []
        var toolRows: [String: Int] = [:]

        for event in events {
            switch event.body {
            case .userMessage(let text):
                items.append(.user(id: event.seq, text: text))
            case .agentMessageChunk(let text):
                if case .agent(let id, let existing)? = items.last {
                    items[items.count - 1] = .agent(id: id, text: existing + text)
                } else {
                    items.append(.agent(id: event.seq, text: text))
                }
            case .agentThoughtChunk(let text):
                if case .thought(let id, let existing)? = items.last {
                    items[items.count - 1] = .thought(id: id, text: existing + text)
                } else {
                    items.append(.thought(id: event.seq, text: text))
                }
            case .toolCall(let toolCallId, let title, let kind, let status):
                toolRows[toolCallId] = items.count
                items.append(.tool(id: event.seq, toolCallId: toolCallId, title: title, kind: kind, status: status))
            case .toolCallUpdate(let toolCallId, let newTitle, let newStatus):
                guard let index = toolRows[toolCallId],
                      case .tool(let id, _, let title, let kind, let status) = items[index]
                else { continue }
                items[index] = .tool(id: id, toolCallId: toolCallId, title: newTitle ?? title, kind: kind, status: newStatus ?? status)
            case .permissionAutoRejected(let title):
                items.append(.permissionRejected(id: event.seq, title: title))
            case .turnEnd(let reason):
                if reason != "end_turn" { items.append(.stopped(id: event.seq, reason: reason)) }
            case .error(let message):
                items.append(.error(id: event.seq, message: message))
            case .unknown:
                continue
            }
        }
        return items
    }
}
