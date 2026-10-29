import Foundation

public struct PermissionPrompt: Equatable, Sendable {
    public enum Resolution: Equatable, Sendable {
        case chose(PermissionChoice)
        case cancelled
    }

    public var requestId: String
    public var title: String
    public var toolKind: String
    public var detail: String?
    public var options: [PermissionChoice]
    /// nil while the agent is still waiting for an answer.
    public var resolution: Resolution?

    public init(
        requestId: String, title: String, toolKind: String, detail: String?,
        options: [PermissionChoice], resolution: Resolution? = nil
    ) {
        self.requestId = requestId
        self.title = title
        self.toolKind = toolKind
        self.detail = detail
        self.options = options
        self.resolution = resolution
    }
}

/// One row of a chat as the UI shows it. Built from the raw event log by `Transcript.build`.
public enum TranscriptItem: Equatable, Sendable, Identifiable {
    /// `from` is the lead session when a lead agent wrote it.
    case user(id: Int, text: String, attachments: [String] = [], from: String? = nil)
    case agent(id: Int, text: String)
    case thought(id: Int, text: String)
    case tool(id: Int, toolCallId: String, title: String, kind: String, status: String)
    case permission(id: Int, PermissionPrompt)
    case stopped(id: Int, reason: String)
    case notice(id: Int, text: String)
    case error(id: Int, message: String)

    /// The seq of the event that started the row; stable while chunks stream in.
    public var id: Int {
        switch self {
        case .user(let id, _, _, _), .agent(let id, _), .thought(let id, _), .tool(let id, _, _, _, _),
             .permission(let id, _), .stopped(let id, _), .notice(let id, _), .error(let id, _):
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
        var permissionRows: [String: Int] = [:]

        for event in events {
            switch event.body {
            case .userMessage(let text, let attachments, let from):
                items.append(.user(id: event.seq, text: text, attachments: attachments, from: from))
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
            case .permissionRequest(let requestId, let title, let toolKind, let detail, let options):
                permissionRows[requestId] = items.count
                let prompt = PermissionPrompt(requestId: requestId, title: title, toolKind: toolKind, detail: detail, options: options)
                items.append(.permission(id: event.seq, prompt))
            case .permissionResolved(let requestId, let optionId):
                guard let index = permissionRows[requestId], case .permission(let id, var prompt) = items[index] else { continue }
                prompt.resolution = optionId
                    .flatMap { chosen in prompt.options.first { $0.optionId == chosen } }
                    .map(PermissionPrompt.Resolution.chose) ?? .cancelled
                items[index] = .permission(id: id, prompt)
            case .turnEnd(let reason):
                if reason != "end_turn" { items.append(.stopped(id: event.seq, reason: reason)) }
            case .notice(let text):
                items.append(.notice(id: event.seq, text: text))
            case .error(let message):
                items.append(.error(id: event.seq, message: message))
            case .unknown:
                continue
            }
        }
        return items
    }
}
