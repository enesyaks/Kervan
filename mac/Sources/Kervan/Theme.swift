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
}
