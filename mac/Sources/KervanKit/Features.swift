import Foundation

/// A file edit the agent reported. Paths are relative to the session folder when inside it.
public struct FileDiff: Codable, Equatable, Sendable {
    public let path: String
    /// nil for a new file.
    public let oldText: String?
    public let newText: String
    public let truncated: Bool

    public init(path: String, oldText: String? = nil, newText: String, truncated: Bool = false) {
        self.path = path
        self.oldText = oldText
        self.newText = newText
        self.truncated = truncated
    }

    private enum CodingKeys: String, CodingKey { case path, oldText, newText, truncated }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        oldText = try c.decodeIfPresent(String.self, forKey: .oldText)
        newText = try c.decode(String.self, forKey: .newText)
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }

    /// The changed lines with a little context, the way a code review shows them.
    public var lines: [DiffLine] { DiffLine.compare(oldText ?? "", newText) }
}

public struct DiffLine: Equatable, Sendable, Identifiable {
    public enum Kind: Sendable { case context, added, removed, gap }
    public let id: Int
    public let kind: Kind
    public let text: String

    public init(id: Int, kind: Kind, text: String) {
        self.id = id
        self.kind = kind
        self.text = text
    }

    /// Lines kept around each change; longer unchanged stretches fold into one `gap` line.
    public static let context = 3

    /// A line diff of two texts (Swift's own Myers difference), unchanged stretches shortened.
    public static func compare(_ old: String, _ new: String) -> [DiffLine] {
        let before = old.isEmpty ? [] : old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let after = new.isEmpty ? [] : new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in after.difference(from: before) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        // Walk both texts together: removals at their old position, insertions at their new one.
        var all: [(kind: Kind, text: String)] = []
        var i = 0, j = 0
        while i < before.count || j < after.count {
            if i < before.count, removed.contains(i) {
                all.append((.removed, before[i]))
                i += 1
            } else if j < after.count, inserted.contains(j) {
                all.append((.added, after[j]))
                j += 1
            } else {
                if i < before.count { all.append((.context, before[i])) }
                i += 1
                j += 1
            }
        }
        let changed = all.indices.filter { all[$0].kind != .context }
        guard !changed.isEmpty else { return [] }
        var keep = Set<Int>()
        for index in changed {
            for near in max(0, index - context)...min(all.count - 1, index + context) { keep.insert(near) }
        }
        var lines: [DiffLine] = []
        var skipping = false
        for index in all.indices {
            if keep.contains(index) {
                lines.append(DiffLine(id: lines.count, kind: all[index].kind, text: all[index].text))
                skipping = false
            } else if !skipping {
                lines.append(DiffLine(id: lines.count, kind: .gap, text: ""))
                skipping = true
            }
        }
        return lines
    }

    /// The lines of a unified git patch (one file's part of it), headers dropped and hunks marked as gaps.
    public static func parse(patch: String) -> [DiffLine] {
        var lines: [DiffLine] = []
        var inHunk = false
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@") {
                if inHunk { lines.append(DiffLine(id: lines.count, kind: .gap, text: "")) }
                inHunk = true
                continue
            }
            guard inHunk, !line.hasPrefix("\\") else { continue }
            let kind: Kind = line.hasPrefix("+") ? .added : line.hasPrefix("-") ? .removed : .context
            lines.append(DiffLine(id: lines.count, kind: kind, text: String(line.dropFirst())))
        }
        return lines
    }
}

/// One step of the agent's plan.
public struct PlanEntry: Codable, Equatable, Sendable {
    public let content: String
    /// pending | in_progress | completed
    public let status: String
    /// high | medium | low
    public let priority: String

    public init(content: String, status: String, priority: String = "medium") {
        self.content = content
        self.status = status
        self.priority = priority
    }
}

/// A slash command the agent offers, e.g. /review.
public struct SlashCommand: Codable, Equatable, Sendable, Identifiable {
    public let name: String
    public let description: String
    /// What to type after the command, when it takes input.
    public let hint: String?
    public var id: String { name }

    public init(name: String, description: String, hint: String? = nil) {
        self.name = name
        self.description = description
        self.hint = hint
    }
}

public struct ProjectInfo: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// Absolute path on the server.
    public let path: String
    public let instructions: String
    public let createdAt: String
    /// What an agent learned scanning the repository once; later sessions get it so they don't rescan it.
    public let map: ProjectMapInfo?

    public init(id: String, name: String, path: String, instructions: String = "", createdAt: String = "", map: ProjectMapInfo? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.instructions = instructions
        self.createdAt = createdAt
        self.map = map
    }
}

public struct ProjectMapInfo: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case building, ready, failed }
    public let status: Status
    /// The agent that builds or built it.
    public let agent: String
    /// The commit the project folder was at when the map was started; nil outside git.
    public let commit: String?
    public let updatedAt: String
    /// The session that builds or built it.
    public let sessionId: String?
    public let error: String?

    public init(status: Status, agent: String, commit: String? = nil, updatedAt: String, sessionId: String? = nil, error: String? = nil) {
        self.status = status
        self.agent = agent
        self.commit = commit
        self.updatedAt = updatedAt
        self.sessionId = sessionId
        self.error = error
    }
}

/// What project.save takes: an existing project by id (only name and instructions change), or a new
/// one from a folder on the server, a repository to clone, or neither (an empty folder).
/// Phone alerts as the server reports them: the ntfy token and webhook address only as "set".
public struct AlertSettings: Codable, Equatable, Sendable {
    public struct Events: Codable, Equatable, Sendable {
        public var approval: Bool
        public var finished: Bool
        public var error: Bool
        public init(approval: Bool, finished: Bool, error: Bool) {
            self.approval = approval
            self.finished = finished
            self.error = error
        }
    }

    public struct Ntfy: Codable, Equatable, Sendable {
        public let server: String
        public let topic: String
        public let tokenSet: Bool
    }

    public let enabled: Bool
    public let events: Events
    public let ntfy: Ntfy?
    public let webhookSet: Bool
    public let openUrl: String?
    /// Alerts carry the session's name, which starts as the first line of its first message.
    public let includeNames: Bool?
}

/// Changes to alert settings. `ntfyToken` nil keeps the stored token, "" removes it; `webhook` nil keeps the
/// stored address, "" removes it; `ntfyTopic` empty removes ntfy.
public struct AlertInput: Encodable, Equatable, Sendable {
    public var enabled: Bool
    public var events: AlertSettings.Events
    public var ntfyServer: String
    public var ntfyTopic: String
    public var ntfyToken: String?
    public var webhook: String?
    public var openUrl: String
    public var includeNames: Bool

    public init(
        enabled: Bool, events: AlertSettings.Events, ntfyServer: String, ntfyTopic: String, ntfyToken: String? = nil,
        webhook: String? = nil, openUrl: String = "", includeNames: Bool = false
    ) {
        self.enabled = enabled
        self.events = events
        self.ntfyServer = ntfyServer
        self.ntfyTopic = ntfyTopic
        self.ntfyToken = ntfyToken
        self.webhook = webhook
        self.openUrl = openUrl
        self.includeNames = includeNames
    }

    private enum Keys: String, CodingKey { case enabled, events, ntfy, webhook, openUrl, server, topic, token, includeNames }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(events, forKey: .events)
        if ntfyTopic.isEmpty {
            try c.encode("", forKey: .ntfy)
        } else {
            var n = c.nestedContainer(keyedBy: Keys.self, forKey: .ntfy)
            try n.encode(ntfyServer, forKey: .server)
            try n.encode(ntfyTopic, forKey: .topic)
            // null keeps the stored token, so the app never needs to know it.
            if let ntfyToken { try n.encode(ntfyToken, forKey: .token) } else { try n.encodeNil(forKey: .token) }
        }
        if let webhook { try c.encode(webhook, forKey: .webhook) }
        try c.encode(openUrl, forKey: .openUrl)
        try c.encode(includeNames, forKey: .includeNames)
    }
}

/// A column of a project's task board.
public enum CardColumn: String, Codable, CaseIterable, Sendable, Identifiable {
    case todo, working, needs, review, done
    public var id: String { rawValue }
}

/// A task on a project's board. Once moved to Working it has a session, and its column follows that session.
public struct CardInfo: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let projectId: String
    public let title: String
    public let prompt: String
    public let agent: String
    public let split: Bool?
    /// "<upload id>/<name>" references from `FileClient.uploadCardFile`.
    public let files: [String]?
    public let column: CardColumn
    public let sessionId: String?
    public let createdAt: String
    public let updatedAt: String
}

extension CardInfo {
    /// What a card file reference is called: the part after the upload id.
    public static func fileName(_ reference: String) -> String {
        reference.split(separator: "/", maxSplits: 1).last.map(String.init) ?? reference
    }
}

/// A new card, or new wording for one that hasn't started.
public struct CardInput: Encodable, Equatable, Sendable {
    public var id: String?
    public var projectId: String
    public var title: String
    public var prompt: String
    public var agent: String
    public var split: Bool
    public var files: [String]

    public init(id: String? = nil, projectId: String, title: String, prompt: String, agent: String, split: Bool = false, files: [String] = []) {
        self.split = split
        self.files = files
        self.id = id
        self.projectId = projectId
        self.title = title
        self.prompt = prompt
        self.agent = agent
    }
}

public struct ProjectInput: Encodable, Equatable, Sendable {
    public var id: String?
    public var name: String
    public var instructions: String
    public var path: String?
    public var gitUrl: String?
    /// A new project only: the agent that maps it right after it's added.
    public var mapAgent: String?

    public init(id: String? = nil, name: String, instructions: String = "", path: String? = nil, gitUrl: String? = nil, mapAgent: String? = nil) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.path = path
        self.gitUrl = gitUrl
        self.mapAgent = mapAgent
    }
}

public enum ScheduleWhen: Codable, Equatable, Sendable {
    /// `time` is HH:MM; weekdays are ISO (1 = Monday … 7 = Sunday).
    case daily(time: String, weekdays: [Int])
    case interval(minutes: Int)

    private enum CodingKeys: String, CodingKey { case kind, time, weekdays, minutes }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if try c.decode(String.self, forKey: .kind) == "interval" {
            self = .interval(minutes: try c.decode(Int.self, forKey: .minutes))
        } else {
            self = .daily(time: try c.decode(String.self, forKey: .time), weekdays: try c.decode([Int].self, forKey: .weekdays))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .daily(let time, let weekdays):
            try c.encode("daily", forKey: .kind)
            try c.encode(time, forKey: .time)
            try c.encode(weekdays, forKey: .weekdays)
        case .interval(let minutes):
            try c.encode("interval", forKey: .kind)
            try c.encode(minutes, forKey: .minutes)
        }
    }

    /// "Hafta içi 09:00", "Her gün 18:30", "30 dakikada bir".
    public var label: String {
        switch self {
        case .interval(let minutes):
            return minutes % 60 == 0 ? L("Every \(minutes / 60) h", "\(minutes / 60) saatte bir") : L("Every \(minutes) min", "\(minutes) dakikada bir")
        case .daily(let time, let weekdays):
            let days: String = switch Set(weekdays) {
            case Set(1...7): L("Every day", "Her gün")
            case Set(1...5): L("Weekdays", "Hafta içi")
            case Set([6, 7]): L("Weekends", "Hafta sonu")
            default: weekdays.sorted().map { Self.dayNames[$0 - 1] }.joined(separator: ", ")
            }
            return "\(days) \(time)"
        }
    }

    public static let dayNames = [L("Mon", "Pzt"), L("Tue", "Sal"), L("Wed", "Çar"), L("Thu", "Per"), L("Fri", "Cum"), L("Sat", "Cmt"), L("Sun", "Paz")]
}

public struct ScheduleInfo: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var agent: String
    public var projectId: String?
    public var prompt: String
    public var when: ScheduleWhen
    public var timeZone: String
    public var enabled: Bool
    public var lastRunAt: String?
    public var lastSessionId: String?
    public var lastError: String?

    public init(
        id: String, title: String, agent: String, projectId: String? = nil, prompt: String, when: ScheduleWhen,
        timeZone: String = TimeZone.current.identifier, enabled: Bool = true, lastRunAt: String? = nil,
        lastSessionId: String? = nil, lastError: String? = nil
    ) {
        self.id = id
        self.title = title
        self.agent = agent
        self.projectId = projectId
        self.prompt = prompt
        self.when = when
        self.timeZone = timeZone
        self.enabled = enabled
        self.lastRunAt = lastRunAt
        self.lastSessionId = lastSessionId
        self.lastError = lastError
    }
}

/// What schedule.save takes; no id makes a new task.
public struct ScheduleInput: Encodable, Equatable, Sendable {
    public var id: String?
    public var title: String
    public var agent: String
    public var projectId: String?
    public var prompt: String
    public var when: ScheduleWhen
    public var timeZone: String
    public var enabled: Bool

    public init(
        id: String? = nil, title: String, agent: String, projectId: String? = nil, prompt: String, when: ScheduleWhen,
        timeZone: String = TimeZone.current.identifier, enabled: Bool = true
    ) {
        self.id = id
        self.title = title
        self.agent = agent
        self.projectId = projectId
        self.prompt = prompt
        self.when = when
        self.timeZone = timeZone
        self.enabled = enabled
    }

    public init(_ schedule: ScheduleInfo) {
        self.init(
            id: schedule.id, title: schedule.title, agent: schedule.agent, projectId: schedule.projectId,
            prompt: schedule.prompt, when: schedule.when, timeZone: schedule.timeZone, enabled: schedule.enabled
        )
    }
}

public struct ChangedFile: Codable, Equatable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable { case added, modified, deleted }
    public let path: String
    public let status: Status
    public let additions: Int
    public let deletions: Int
    public var id: String { path }

    public init(path: String, status: Status, additions: Int, deletions: Int) {
        self.path = path
        self.status = status
        self.additions = additions
        self.deletions = deletions
    }
}

/// What changed in a session's folder since one of its checkpoints.
public struct ChangeSet: Codable, Equatable, Sendable {
    public let files: [ChangedFile]
    public let patch: String
    public let truncated: Bool
    /// The user message the changes are counted from; nil before the first message.
    public let sinceSeq: Int?
    /// The folder is a git repository, so the changes can be committed there.
    public let repository: Bool
    public let branch: String?

    public init(files: [ChangedFile], patch: String = "", truncated: Bool = false, sinceSeq: Int? = nil, repository: Bool = false, branch: String? = nil) {
        self.files = files
        self.patch = patch
        self.truncated = truncated
        self.sinceSeq = sinceSeq
        self.repository = repository
        self.branch = branch
    }

    /// The patch split per file, keyed by path (from each "diff --git a/… b/…" header).
    public var patches: [String: String] {
        var result: [String: String] = [:]
        var current: String?
        var lines: [Substring] = []
        func flush() { if let current { result[current] = lines.joined(separator: "\n") } }
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                flush()
                lines = []
                // The b/ side names the file as it is now.
                current = line.range(of: " b/", options: .backwards).map { String(line[$0.upperBound...]) }
            }
            lines.append(line)
        }
        flush()
        return result
    }
}

public struct UsageReport: Codable, Equatable, Sendable {
    public struct Day: Codable, Equatable, Sendable {
        /// YYYY-MM-DD in the time zone asked for.
        public let date: String
        public let agent: String
        public let costUsd: Double

        public init(date: String, agent: String, costUsd: Double) {
            self.date = date
            self.agent = agent
            self.costUsd = costUsd
        }
    }

    public struct SessionCost: Codable, Equatable, Sendable {
        public let sessionId: String
        public let costUsd: Double

        public init(sessionId: String, costUsd: Double) {
            self.sessionId = sessionId
            self.costUsd = costUsd
        }
    }

    public let days: [Day]
    public let sessions: [SessionCost]

    public init(days: [Day], sessions: [SessionCost]) {
        self.days = days
        self.sessions = sessions
    }

    public var total: Double { days.reduce(0) { $0 + $1.costUsd } }

    /// Spending on and after `date` (YYYY-MM-DD).
    public func total(since date: String) -> Double {
        days.filter { $0.date >= date }.reduce(0) { $0 + $1.costUsd }
    }

    /// Each agent's total, largest first.
    public var byAgent: [(agent: String, costUsd: Double)] {
        Dictionary(grouping: days, by: \.agent)
            .map { (agent: $0.key, costUsd: $0.value.reduce(0) { $0 + $1.costUsd }) }
            .sorted { $0.costUsd > $1.costUsd }
    }
}

/// Whether the server can push and open pull requests: gh installed, and signed in to GitHub as `account`.
public struct GitHubStatus: Codable, Equatable, Sendable {
    public let available: Bool
    public let signedIn: Bool
    /// A sign-in is waiting for its code to be entered.
    public let signingIn: Bool
    public let account: String?
}

/// The code to enter at `url` (github.com/login/device) to sign the server in.
public struct GitHubDeviceCode: Equatable, Sendable {
    public let code: String
    public let url: URL
}

/// Where an agent's account sign-in goes on: open `url`; for Codex enter `code` there, for Claude bring back the
/// code the page shows (`needsCode`).
public struct AgentLoginPrompt: Equatable, Sendable {
    public let agent: String
    public let url: URL
    public let code: String?
    public let needsCode: Bool
}

/// An agent from the ACP registry and where it stands on the server.
public struct OfferedAgent: Codable, Equatable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable {
        /// Comes with Kervan.
        case builtin
        /// Already one of the server's agents.
        case added
        /// Installed on the server by hand; it only needs adding.
        case found
        /// Can be installed from the app.
        case installable
        /// Can't be added from here; `reason` says why.
        case unavailable
    }

    public let id: String
    public let name: String
    public let description: String
    public let version: String?
    public let website: String?
    public let status: Status
    /// npm, download or uvx, for installable agents.
    public let source: String?
    public let path: String?
    public let reason: String?
    /// Can run a local model from that machine's Ollama or LM Studio.
    public let ollama: Bool

    public init(id: String, name: String, description: String, version: String? = nil, website: String? = nil, status: Status, source: String? = nil, path: String? = nil, reason: String? = nil, ollama: Bool = false) {
        self.id = id
        self.name = name
        self.description = description
        self.version = version
        self.website = website
        self.status = status
        self.source = source
        self.path = path
        self.reason = reason
        self.ollama = ollama
    }
}

/// Ollama or LM Studio on a machine: whether it answers, and the models it has.
public struct OllamaStatus: Codable, Equatable, Sendable {
    public let running: Bool
    public let url: String
    public let models: [String]

    public init(running: Bool, url: String, models: [String]) {
        self.running = running
        self.url = url
        self.models = models
    }
}

/// How an account sign-in ended.
public enum AgentLoginOutcome: Equatable, Sendable {
    case signedIn
    case failed(String)
}

/// A browser paired for the web client. Its key never comes back to the app, only who it is.
public struct WebDevice: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let createdAt: String
    public let lastSeenAt: String?
}

public struct WebAccessStatus: Codable, Equatable, Sendable {
    public let enabled: Bool
    public let devices: [WebDevice]
}

/// A one-time code a browser trades for its own key.
public struct WebPairing: Equatable, Sendable {
    public let code: String
    public let expiresAt: Date
}

/// A session's work put up for review. `url` is the pull request, or GitHub's compare page when `created` is false.
public struct PullRequestInfo: Codable, Equatable, Sendable {
    public let branch: String
    public let base: String
    public let url: URL?
    public let created: Bool
}

/// The server's part of a bug report: versions, what runs, and recent log lines it already redacted.
public struct Diagnostics: Codable, Equatable, Sendable {
    public struct Agent: Codable, Equatable, Sendable {
        public let id: String
        public let available: Bool
        public let signedIn: Bool?
        public let node: String
    }

    public struct Node: Codable, Equatable, Sendable {
        public let name: String
        public let connected: Bool
        public let version: String?
    }

    public let version: String
    public let node: String
    public let os: String
    public let uptimeSec: Int
    public let agents: [Agent]
    public let nodes: [Node]
    public let sessions: [String: Int]
    public let logs: [String]
}

public struct ListeningPort: Codable, Equatable, Sendable, Identifiable {
    public let port: Int
    public let process: String?
    public var id: Int { port }

    public init(port: Int, process: String? = nil) {
        self.port = port
        self.process = process
    }
}

/// The `id` a request carries and its answer echoes; nil for messages without one (hello, events).
private func requestID(of value: Any) -> String? {
    guard let payload = Mirror(reflecting: value).children.first?.value else { return nil }
    // A case whose only value is its id (`.ok(id:)`) has that string as its payload, not a tuple.
    if let id = payload as? String { return id }
    guard let id = Mirror(reflecting: payload).children.first(where: { $0.label == "id" })?.value else { return nil }
    return (id as? String) ?? (id as? String?) ?? nil
}

extension ClientMessage {
    public var requestID: String? { KervanKit.requestID(of: self) }
}

extension ServerMessage {
    public var requestID: String? { KervanKit.requestID(of: self) }
}

/// The server's refusal of a request that otherwise answers with something.
public struct RequestFailure: Error, Equatable, Sendable {
    public let message: String
}
