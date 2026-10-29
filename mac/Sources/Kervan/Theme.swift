import AppKit
import KervanKit
import SwiftUI

// Lapis, saffron and oasis: the route a caravan takes. Each has a lighter dark-mode variant
// so the line keeps its contrast on dark window backgrounds.
extension Color {
    // Calm by design: blue for trust, sage for "all is well", honey for "your turn", never alarm red.
    static let kervanLapis = Color(light: 0x4A6FA5, dark: 0x8AAEDB)
    static let kervanSaffron = Color(light: 0xC9953A, dark: 0xE6BE6E)
    static let kervanOasis = Color(light: 0x5E9C7E, dark: 0x7FC0A0)
    /// Problems in a soft coral: noticeable, not frightening.
    static let kervanCoral = Color(light: 0xD27466, dark: 0xE8968A)

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
        case .failed: .kervanCoral
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
        case .error: .kervanCoral
        case .closed, .unknown: .secondary
        }
    }

    var label: String {
        switch self {
        case .starting: "Hazırlanıyor"
        case .idle: "Hazır"
        case .running: "Çalışıyor"
        case .waiting: "Onayınızı bekliyor"
        case .error: "Durdu"
        case .closed: "Kapandı"
        case .unknown: "Bilinmiyor"
        }
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

/// Dollars as the agents report them, written the Turkish way: $0,42.
func usd(_ amount: Double) -> String {
    amount.formatted(.currency(code: "USD").locale(Locale(identifier: "tr_TR")))
}

extension SessionStore {
    /// What a session has spent, for subtitles. A lead counts its helpers too and shows its budget.
    func costSummary(_ session: SessionInfo) -> String? {
        let crew = crewCost(session.id)
        if let budget = session.budgetUsd {
            return "\(usd(crew ?? 0)) / \(usd(budget)) bütçe"
        }
        if !helpers(of: session.id).isEmpty, let crew {
            return "yardımcılarla \(usd(crew)) harcandı"
        }
        return session.usage?.costUsd.map { "\(usd($0)) harcandı" }
    }
}

// MARK: - Night caravan: the soft surfaces, shapes and motion every screen shares

extension Color {
    /// The window's floor: a night-blue tint (mist by day) instead of neutral gray, taken from the icon.
    static let kervanCanvas = Color(light: 0xF4F6F9, dark: 0x131B27)
    /// The sidebar, a shade off the canvas so the two read as one calm room.
    static let kervanSidebar = Color(light: 0xECF0F5, dark: 0x0F1620)
    /// One step up from the canvas: cards, bubbles, the composer.
    static let kervanSurface = Color(light: 0xFFFFFF, dark: 0x1A2433)
    /// Recessed inside a surface: code, tool rows, chips.
    static let kervanWell = Color(light: 0xEAEFF6, dark: 0x22304A)
}

/// Corner radii. Nested shapes follow outer = inner + padding, so a chip inside a card stays concentric.
enum Radius {
    static let chip: CGFloat = 10
    static let card: CGFloat = 14
    static let panel: CGFloat = 18
    static let composer: CGFloat = 20
}

/// Every animation in the app picks from these, so movement has one character: quick, soft, never bouncy.
enum Motion {
    /// Button feedback, hover, small state flips.
    static let fast = Animation.easeOut(duration: 0.18)
    /// Things arriving: messages, cards, sheets of content.
    static let smooth = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.35)
    /// Panels and larger surfaces settling into place.
    static let gentle = Animation.spring(response: 0.45, dampingFraction: 0.86)
    /// With Reduce Motion on, every movement becomes this short fade.
    static let reduced = Animation.easeOut(duration: 0.15)

    static func pick(_ animation: Animation, reduce: Bool) -> Animation { reduce ? reduced : animation }
}

extension AnyTransition {
    /// New content rises a few points while fading in; with Reduce Motion it only fades.
    static func arrive(reduce: Bool) -> AnyTransition {
        reduce ? .opacity : .opacity.combined(with: .offset(y: 6))
    }
}

/// A raised surface: filled, continuous corners, and two faint shadows (contact + ambient) instead of a hairline border.
private struct SoftSurface: ViewModifier {
    let radius: CGFloat
    let fill: Color
    let lift: Bool

    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(fill)
                .shadow(color: .black.opacity(lift ? 0.06 : 0), radius: 1, y: 1)
                .shadow(color: .black.opacity(lift ? 0.10 : 0), radius: 14, y: 6)
        }
    }
}

extension View {
    func softSurface(radius: CGFloat = Radius.card, fill: Color = .kervanSurface, lift: Bool = true) -> some View {
        modifier(SoftSurface(radius: radius, fill: fill, lift: lift))
    }
}

/// Presses shrink a touch and spring back, so a click feels like it landed.
struct SoftPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(Motion.fast, value: configuration.isPressed)
    }
}

/// A status light with a faint halo, so the color reads without a hard edge.
struct StatusDot: View {
    let color: Color
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .background(Circle().fill(color.opacity(0.22)).frame(width: size + 6, height: size + 6))
            .frame(width: size + 6, height: size + 6)
            .accessibilityHidden(true)
    }
}

/// Light, dark or follow the system; light by default. Chosen in Settings › Genel.
enum Appearance: String, CaseIterable, Identifiable {
    case light, dark, system
    static let key = "appearance"

    var id: String { rawValue }
    var scheme: ColorScheme? {
        switch self {
        case .light: .light
        case .dark: .dark
        case .system: nil
        }
    }
    var label: String {
        switch self {
        case .light: "Açık"
        case .dark: "Koyu"
        case .system: "Sistem"
        }
    }
}

extension View {
    /// A settings list as a soft card on the canvas instead of a bordered box.
    func softList() -> some View {
        listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.kervanSurface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .softSurface()
    }

    /// The background every settings page and sheet sits on.
    func settingsPage() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.kervanCanvas)
    }
}

extension ShapeStyle where Self == Color {
    /// Lets `.foregroundStyle(.kervanCoral)` read like the system colors it replaced.
    static var kervanCoral: Color { Color.kervanCoral }
}
