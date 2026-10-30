import AppKit
import KervanKit
import UserNotifications

/// Posts a macOS notification when an agent needs the user or has finished, unless the user is
/// already looking at that session. Clicking one opens the session.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private let open: (String) -> Void
    private var asked = false

    init(open: @escaping (String) -> Void) {
        self.open = open
        super.init()
        center.delegate = self
    }

    func post(_ alert: SessionAlert, selected: String?) {
        if NSApp.isActive && selected == alert.sessionID { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.userInfo = ["sessionID": alert.sessionID]
        content.threadIdentifier = alert.sessionID
        if alert.kind != .answered { content.sound = .default }
        let request = UNNotificationRequest(identifier: alert.identifier, content: content, trigger: nil)
        if asked {
            center.add(request)
            return
        }
        // Asked once, the first time there is something to say; the system remembers the answer.
        // The async form: the callback form answers on a background queue, which a main-actor closure can't run on.
        asked = true
        let center = center
        Task {
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            try? await center.add(request)
        }
    }

    /// The approval was given or the session opened: its notification is no longer news.
    func clear(_ sessionID: String) {
        center.removeDeliveredNotifications(withIdentifiers: SessionAlert.Kind.allIdentifiers(sessionID))
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let sessionID = response.notification.request.content.userInfo["sessionID"] as? String else { return }
        await MainActor.run {
            NSApp.activate()
            open(sessionID)
        }
    }
}

extension SessionAlert.Kind {
    static func allIdentifiers(_ sessionID: String) -> [String] {
        [Self.waiting, .answered, .failed].map { "\(sessionID)-\($0.rawValue)" }
    }
}
