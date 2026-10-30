import Foundation
import Observation

/// The app's language: English unless the user picks Turkish, or macOS prefers Turkish and the user left it on System.
@Observable
public final class Language: @unchecked Sendable {
    public enum Choice: String, CaseIterable, Sendable, Identifiable {
        case system, english, turkish
        public var id: String { rawValue }
    }

    public static let shared = Language()
    private static let key = "appLanguage"

    /// Views that call `L` while drawing redraw when this changes.
    public var choice: Choice {
        didSet {
            UserDefaults.standard.set(choice.rawValue, forKey: Self.key)
            // System menus and dialogs follow the app's language from the next launch.
            switch choice {
            case .system: UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            case .english: UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
            case .turkish: UserDefaults.standard.set(["tr"], forKey: "AppleLanguages")
            }
        }
    }

    public var isTurkish: Bool {
        switch choice {
        case .english: false
        case .turkish: true
        // The bundle declares en and tr; outside an app bundle (tests, swift run) this is English.
        case .system: Bundle.main.preferredLocalizations.first == "tr"
        }
    }

    /// Dates and numbers follow the chosen language too.
    public var locale: Locale { Locale(identifier: isTurkish ? "tr_TR" : "en_US") }

    private init() {
        choice = UserDefaults.standard.string(forKey: Self.key).flatMap(Choice.init(rawValue:)) ?? .system
    }
}

/// A user-facing text in English, with its Turkish translation next to it.
public func L(_ english: String, _ turkish: String) -> String {
    Language.shared.isTurkish ? turkish : english
}
