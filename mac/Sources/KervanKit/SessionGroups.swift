import Foundation

/// Sidebar sections: active sessions by when they were last used, archived ones apart.
public struct SessionGroup: Equatable, Sendable, Identifiable {
    public let title: String
    public let sessions: [SessionInfo]
    public var id: String { title }
}

public enum SessionGroups {
    /// `lastActivity`: ISO-8601 time per session. Newest first inside each group; empty groups are left out.
    public static func group(
        _ sessions: [SessionInfo],
        lastActivity: (SessionInfo) -> String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> (active: [SessionGroup], archived: [SessionInfo]) {
        let dated = sessions
            .map { ($0, parse(lastActivity($0)) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }

        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: today)!

        var buckets: [(String, [SessionInfo])] = [(L("Today", "Bugün"), []), (L("Yesterday", "Dün"), []), (L("Last 7 days", "Son 7 gün"), []), (L("Older", "Daha eski"), [])]
        var archived: [SessionInfo] = []
        for (session, date) in dated {
            if session.archived {
                archived.append(session)
                continue
            }
            let index = date >= today ? 0 : date >= yesterday ? 1 : date >= weekAgo ? 2 : 3
            buckets[index].1.append(session)
        }
        let active = buckets.filter { !$0.1.isEmpty }.map { SessionGroup(title: $0.0, sessions: $0.1) }
        return (active, archived)
    }

    /// The server writes `2026-10-29T10:00:00.000Z`; tolerate the variant without fractions too.
    public static func parse(_ text: String) -> Date? {
        let withFractions = ISO8601DateFormatter()
        withFractions.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFractions.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
