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
        case .disconnected: L("Not connected", "Bağlı değil")
        case .connecting: L("Connecting…", "Bağlanıyor…")
        case .retrying: L("Unreachable", "Ulaşılamıyor")
        case .connected: L("Connected", "Bağlı")
        case .failed: L("Couldn't connect", "Bağlanamadı")
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
        case .starting: L("Starting", "Hazırlanıyor")
        case .idle: L("Ready", "Hazır")
        case .running: L("Running", "Çalışıyor")
        case .waiting: L("Waiting for you", "Onayınızı bekliyor")
        case .error: L("Stopped", "Durdu")
        case .closed: L("Closed", "Kapandı")
        case .unknown: L("Unknown", "Bilinmiyor")
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
    amount.formatted(.currency(code: "USD").locale(Language.shared.locale))
}

extension SessionStore {
    /// What a session has spent, for subtitles. A lead counts its helpers too and shows its budget.
    func costSummary(_ session: SessionInfo) -> String? {
        let crew = crewCost(session.id)
        if let budget = session.budgetUsd {
            return L("\(usd(crew ?? 0)) of \(usd(budget)) budget", "\(usd(crew ?? 0)) / \(usd(budget)) bütçe")
        }
        if !helpers(of: session.id).isEmpty, let crew {
            return L("\(usd(crew)) spent with helpers", "yardımcılarla \(usd(crew)) harcandı")
        }
        return session.usage?.costUsd.map { L("\(usd($0)) spent", "\(usd($0)) harcandı") }
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
    /// The edge of a raised surface: invisible by day, a faint line at night.
    /// Words on a lapis or coral fill: white by day, night-blue on the lighter night variants.
    static let kervanOnAccent = Color(light: 0xFFFFFF, dark: 0x0F1620)
    static let kervanHairline = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.07) : NSColor.black.withAlphaComponent(0.04)
    })
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
                // Shadows vanish on the night canvas; a hairline keeps the card's edge there.
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.kervanHairline, lineWidth: 1))
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
        case .light: L("Light", "Açık")
        case .dark: L("Dark", "Koyu")
        case .system: L("System", "Sistem")
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

/// A status said in words on its own color: "Waiting for you" in saffron, "Stopped" in coral.
struct StatusPill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
            .lineLimit(1)
            .fixedSize()
    }
}

/// "5 min ago" for the server's ISO timestamps; nil when the text isn't a date.
enum RelativeTime {
    /// Short enough for a sidebar row: "now", "5m", "3h", "2d", then the day itself.
    static func short(_ iso: String, now: Date = Date()) -> String? {
        guard let date = SessionGroups.parse(iso) else { return nil }
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return L("now", "şimdi")
        case ..<3600: return L("\(Int(seconds / 60))m", "\(Int(seconds / 60)) dk")
        case ..<86400: return L("\(Int(seconds / 3600))h", "\(Int(seconds / 3600)) sa")
        case ..<(86400 * 7): return L("\(Int(seconds / 86400))d", "\(Int(seconds / 86400)) g")
        default: return date.formatted(.dateTime.day().month(.abbreviated).locale(Language.shared.locale))
        }
    }
}

/// The app's own buttons, in the pill shape the first run introduced: lapis for the one thing a screen
/// is for, a quiet well for everything beside it, coral when the action removes something.
struct KervanButtonStyle: ButtonStyle {
    enum Kind { case primary, quiet }
    let kind: Kind
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let destructive = configuration.role == .destructive
        let fill: Color = switch kind {
        case .primary: destructive ? .kervanCoral : .kervanLapis
        case .quiet: .kervanWell
        }
        let (horizontal, vertical, font): (CGFloat, CGFloat, Font) = switch controlSize {
        case .mini, .small: (10, 4, .callout)
        case .large, .extraLarge: (20, 10, .body)
        default: (14, 6.5, .body)
        }
        return configuration.label
            .font(font.weight(kind == .primary ? .semibold : .medium))
            .foregroundStyle(kind == .primary ? Color.kervanOnAccent : destructive ? Color.kervanCoral : Color.primary)
            .lineLimit(1)
            .padding(.horizontal, horizontal)
            .padding(.vertical, vertical)
            .background(fill.opacity(configuration.isPressed ? 0.8 : 1), in: Capsule())
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(Motion.fast, value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == KervanButtonStyle {
    static var kervanPrimary: KervanButtonStyle { KervanButtonStyle(kind: .primary) }
    static var kervanQuiet: KervanButtonStyle { KervanButtonStyle(kind: .quiet) }
}

/// A dotted stretch of road ending at a stop nobody has reached yet: how every empty place in the app looks.
struct EmptyRoute: View {
    let symbol: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.kervanLapis.opacity(0.55)).frame(width: 7, height: 7)
            Line()
                .stroke(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [1.5, 6]))
                .frame(width: 64, height: 2)
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.kervanLapis)
                .frame(width: 42, height: 42)
                .background(Color.kervanLapis.opacity(0.12), in: Circle())
                .overlay(Circle().strokeBorder(Color.kervanLapis.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [3, 4])))
        }
        .accessibilityHidden(true)
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: rect.minX, y: rect.midY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            }
        }
    }
}
