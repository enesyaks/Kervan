import Foundation

/// This build's version. The app, its Info.plist and the server it carries (server/src/version.ts) are
/// released together under one number; a test keeps the three in step.
public enum KervanVersion {
    public static let current = "0.3.7"
}

/// "0.2.0", "v0.10.1": numbers compared one by one, missing parts counting as 0. Anything after a "-" is ignored.
public struct SemanticVersion: Comparable, Sendable, CustomStringConvertible {
    public let parts: [Int]

    public init?(_ text: String) {
        var text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        let core = text.split(separator: "-", maxSplits: 1).first.map(String.init) ?? text
        let parts = core.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        self.parts = parts.compactMap { $0 }
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        for i in 0..<max(lhs.parts.count, rhs.parts.count) {
            let a = i < lhs.parts.count ? lhs.parts[i] : 0
            let b = i < rhs.parts.count ? rhs.parts[i] : 0
            if a != b { return a < b }
        }
        return false
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}

/// A published release of the Mac app, as GitHub's "latest release" describes it.
public struct AppRelease: Equatable, Sendable {
    public let version: String
    public let notes: String
    /// The release page, for "What's new".
    public let page: URL
    /// Kervan-<version>-macOS.zip
    public let archive: URL
    /// The archive's SHA-256, published next to it as <archive>.sha256.
    public let checksum: URL?

    public static let latestURL = URL(string: "https://api.github.com/repos/enesyaks/Kervan/releases/latest")!

    public init(version: String, notes: String, page: URL, archive: URL, checksum: URL?) {
        self.version = version
        self.notes = notes
        self.page = page
        self.archive = archive
        self.checksum = checksum
    }

    /// The release in GitHub's JSON, if it carries a macOS archive.
    public static func parse(_ data: Data) -> AppRelease? {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        struct Release: Decodable {
            let tag_name: String
            let body: String?
            let html_url: URL
            let draft: Bool?
            let prerelease: Bool?
            let assets: [Asset]
        }
        guard let release = try? JSONDecoder().decode(Release.self, from: data),
              release.draft != true, release.prerelease != true,
              let archive = release.assets.first(where: { $0.name.hasSuffix("-macOS.zip") })
        else { return nil }
        let checksum = release.assets.first { $0.name == archive.name + ".sha256" }
        return AppRelease(
            version: SemanticVersion(release.tag_name)?.description ?? release.tag_name,
            notes: release.body ?? "",
            page: release.html_url,
            archive: archive.browser_download_url,
            checksum: checksum?.browser_download_url
        )
    }

    /// Whether this release is newer than `current`.
    public func isNewer(than current: String) -> Bool {
        guard let mine = SemanticVersion(current), let theirs = SemanticVersion(version) else { return false }
        return mine < theirs
    }

    /// The hex digest in a `shasum -a 256` line ("<64 hex>  <file name>").
    public static func digest(inChecksumFile text: String) -> String? {
        let first = text.split(whereSeparator: \.isWhitespace).first.map { String($0).lowercased() } ?? ""
        return first.count == 64 && first.allSatisfy(\.isHexDigit) ? first : nil
    }
}

/// Takes secrets out of text the user is about to share (a bug report): API keys, tokens, bearer headers.
public enum Redact {
    private static let patterns: [(String, String)] = [
        (#"sk-ant-[A-Za-z0-9_\-]{8,}"#, "sk-ant-…"),
        (#"sk-[A-Za-z0-9_\-]{16,}"#, "sk-…"),
        (#"AIza[0-9A-Za-z_\-]{20,}"#, "AIza…"),
        (#"gh[pousr]_[A-Za-z0-9]{20,}"#, "gh…"),
        (#"(?i)bearer\s+\S+"#, "Bearer …"),
        (#"(?i)\b([A-Z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD))\s*[=:]\s*\S+"#, "$1=…"),
        // Kervan's own tokens and invite codes: long runs of hex.
        (#"\b[0-9a-f]{32,}\b"#, "…"),
    ]

    public static func text(_ text: String) -> String {
        patterns.reduce(text) { result, pattern in
            result.replacingOccurrences(of: pattern.0, with: pattern.1, options: .regularExpression)
        }
    }
}

/// A bug report the user reviews and then files as a GitHub issue (the bug form, with its fields filled in).
public struct BugReport: Equatable, Sendable {
    public var title: String
    public var what: String
    public var versions: String
    public var logs: String

    public static let newIssueURL = URL(string: "https://github.com/enesyaks/Kervan/issues/new")!
    /// GitHub turns away very long URLs; the logs are cut to fit and the rest can be pasted from the copy.
    public static let maxURLLength = 7_500

    public init(title: String = "", what: String = "", versions: String, logs: String) {
        self.title = title
        self.what = what
        self.versions = versions
        self.logs = logs
    }

    /// Versions and recent trouble, redacted. `errors` are the last error and notice lines the app saw.
    public static func make(
        app: String, macOS: String, language: String, connection: String, server: Diagnostics?, errors: [String],
        serverVersion: String? = nil
    ) -> BugReport {
        var versions = "Kervan app \(app), macOS \(macOS), \(language)"
        if let server {
            versions += "; server \(server.version) (Node \(server.node), \(server.os))"
        } else if let serverVersion {
            versions += "; server \(serverVersion)"
        }
        var logs = ["Connection: \(connection)"]
        if let server {
            let agents = server.agents.map { agent in
                "\(agent.id)\(agent.node == "local" ? "" : "@\(agent.node)")=\(agent.available ? "ok" : "unavailable")"
                    + (agent.signedIn == false ? ", not signed in" : "")
            }
            logs.append("Agents: " + (agents.isEmpty ? "none" : agents.joined(separator: "; ")))
            if !server.nodes.isEmpty {
                logs.append("Nodes: " + server.nodes.map { "\($0.name)=\($0.connected ? "connected" : "offline")" }.joined(separator: "; "))
            }
            logs.append("Sessions: " + server.sessions.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
            logs.append("Server uptime: \(server.uptimeSec / 60) min")
        } else {
            logs.append("Server details: not available (not connected, or the server is older than 0.2).")
        }
        if !errors.isEmpty { logs += ["", "Recent errors in the app:"] + errors }
        if let server, !server.logs.isEmpty { logs += ["", "Recent server log:"] + server.logs }
        return BugReport(versions: Redact.text(versions), logs: Redact.text(logs.joined(separator: "\n")))
    }

    /// The bug form with every field filled in, the logs cut from the top so the URL stays short enough.
    public var issueURL: URL {
        func url(logs: String) -> URL {
            var components = URLComponents(url: Self.newIssueURL, resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "template", value: "bug.yml"),
                URLQueryItem(name: "title", value: title),
                URLQueryItem(name: "what", value: what),
                URLQueryItem(name: "versions", value: versions),
                URLQueryItem(name: "logs", value: logs),
            ]
            return components.url!
        }
        var lines = logs.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var candidate = url(logs: logs)
        // Older lines go first: the newest server log lines are the ones that matter.
        while candidate.absoluteString.count > Self.maxURLLength, lines.count > 1 {
            lines.removeFirst(max(1, lines.count / 10))
            candidate = url(logs: "…\n" + lines.joined(separator: "\n"))
        }
        return candidate
    }

    /// Everything as one text, for copying.
    public var text: String {
        "## \(title)\n\n\(what)\n\n**Versions:** \(versions)\n\n```\n\(logs)\n```\n"
    }
}
