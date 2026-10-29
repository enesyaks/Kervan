import AppKit
import KervanKit
import SwiftUI

// Lapis, saffron and oasis: the route a caravan takes. Each has a lighter dark-mode variant
// so the line keeps its contrast on dark window backgrounds.
extension Color {
    static let kervanLapis = Color(light: 0x2F5D8A, dark: 0x6F9BD1)
    static let kervanSaffron = Color(light: 0xC98A1E, dark: 0xE8B65A)
    static let kervanOasis = Color(light: 0x2F7D5B, dark: 0x5DB38C)

    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// How each connection state reads in the UI. One vocabulary for sidebar, route and detail.
extension ConnectionState {
    var tint: Color {
        switch self {
        case .disconnected: .secondary
        case .connecting, .retrying: .kervanSaffron
        case .connected: .kervanOasis
        case .failed: .red
        }
    }

    var shortLabel: String {
        switch self {
        case .disconnected: "Bağlı değil"
        case .connecting: "Bağlanıyor…"
        case .retrying: "Ulaşılamıyor"
        case .connected: "Bağlı"
        case .failed: "Bağlanamadı"
        }
    }

    var isBusy: Bool {
        switch self {
        case .connecting, .retrying: true
        default: false
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

extension SessionStatus {
    var tint: Color {
        switch self {
        case .starting, .running, .waiting: .kervanSaffron
        case .idle: .kervanOasis
        case .error: .red
        case .closed, .unknown: .secondary
        }
    }

    var label: String {
        switch self {
        case .starting: "Başlatılıyor"
        case .idle: "Hazır"
        case .running: "Yanıtlıyor"
        case .waiting: "Onay bekliyor"
        case .error: "Sona erdi"
        case .closed: "Kapandı"
        case .unknown: "Bilinmiyor"
        }
    }
}

extension String {
    /// "claude" → "Claude". M7's agent registry will carry real display names.
    var agentDisplayName: String {
        ["claude": "Claude", "codex": "Codex", "gemini": "Gemini"][self] ?? capitalized
    }
}

/// Three saffron dots in single file, the caravan from the route line in miniature.
struct CaravanDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate * 3
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color.kervanSaffron)
                        .frame(width: 5, height: 5)
                        .opacity(reduceMotion ? 0.8 : 0.35 + 0.65 * max(0, sin(phase - Double(index) * 0.7)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}
