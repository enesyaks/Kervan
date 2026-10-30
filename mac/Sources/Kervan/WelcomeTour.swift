import AppKit
import KervanKit
import SwiftUI

/// The first-use tour: six short cards right after the onboarding, then never again unless asked for.
/// It is a sheet on the main window, so the app is right there behind it while you read.
///
/// - Shown once: `tourSeen` in UserDefaults is set when it closes, whether finished or skipped.
/// - Replay from anywhere with `WelcomeTour.show()`, e.g. a Help menu item.
/// - `KERVAN_TOUR=1` opens it on launch even when seen, once RootView carries `.welcomeTour()`.
public enum WelcomeTour {
    static let seenKey = "tourSeen"

    static var seen: Bool { UserDefaults.standard.bool(forKey: seenKey) }

    /// KERVAN_TOUR=1 (anything but empty or 0) shows the tour regardless of `tourSeen`, for checking it.
    static var requestedByEnvironment: Bool {
        guard let value = ProcessInfo.processInfo.environment["KERVAN_TOUR"] else { return false }
        return !value.isEmpty && value != "0"
    }

    @MainActor private static var sheet: NSWindow?
    /// What to do once the tour closes (the onboarding's "Start the first session" waits for it).
    @MainActor private static var afterwards: [@MainActor () -> Void] = []
    /// The launch flag opens the tour at most once per launch, and not on top of one already showing.
    @MainActor private static var launchHandled = false

    /// Plays the tour now, whether or not it has been seen.
    @MainActor public static func show() {
        present()
    }

    /// After the onboarding: the tour if it hasn't been seen yet, then `then`. If it has been seen, `then` runs now.
    /// `delay` lets the onboarding fade out first, so the sheet lands on the app rather than on the fade.
    @MainActor static func showIfNew(after delay: Double = 0, then: (@MainActor () -> Void)? = nil) {
        guard !seen || requestedByEnvironment else {
            then?()
            return
        }
        launchHandled = true
        Task { @MainActor in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            present(then: then)
        }
    }

    /// Called by `.welcomeTour()` when the window is clear (no intro, no onboarding).
    @MainActor static func showForLaunchFlag() {
        guard requestedByEnvironment, !launchHandled else { return }
        launchHandled = true
        Task { @MainActor in
            // The window is still settling on the first pass; a moment later it can carry a sheet.
            try? await Task.sleep(for: .seconds(0.5))
            present()
        }
    }

    @MainActor private static func present(then: (@MainActor () -> Void)? = nil) {
        if let then { afterwards.append(then) }
        guard sheet == nil else { return }
        guard let parent = hostWindow() else {
            // Nowhere to show it; don't hold up what comes next, and don't count it as seen.
            runAfterwards()
            return
        }
        let host = NSHostingController(rootView: WelcomeTourView(close: close).fontDesign(.rounded))
        host.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: host)
        window.title = L("Welcome tour", "Tanıtım turu")
        // Follow the app's Light/Dark choice, which lives on the main window.
        window.appearance = parent.appearance
        sheet = window
        parent.beginSheet(window)
    }

    @MainActor private static func close() {
        UserDefaults.standard.set(true, forKey: seenKey)
        if let sheet { sheet.sheetParent?.endSheet(sheet) }
        sheet = nil
        runAfterwards()
    }

    @MainActor private static func runAfterwards() {
        let pending = afterwards
        afterwards = []
        pending.forEach { $0() }
    }

    /// The app's main window: not Settings, not a panel, not another sheet.
    @MainActor private static func hostWindow() -> NSWindow? {
        let candidates = [NSApp.mainWindow, NSApp.keyWindow].compactMap { $0 } + NSApp.windows
        return candidates.first { window in
            window.isVisible && window.canBecomeMain && window.sheetParent == nil && !(window is NSPanel)
                && !window.frameAutosaveName.contains("Settings")
                && !(window.identifier?.rawValue.contains("Settings") ?? false)
        }
    }
}

extension View {
    /// The one hook RootView needs for KERVAN_TOUR=1: opens the tour once the intro and onboarding are gone.
    func welcomeTour() -> some View { modifier(WelcomeTourLaunch()) }
}

private struct WelcomeTourLaunch: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.onChange(of: !model.showIntro && !model.showOnboarding, initial: true) { _, clear in
            if clear { WelcomeTour.showForLaunchFlag() }
        }
    }
}

// MARK: - The cards

private struct TourCard: Identifiable {
    enum Art { case sessions, projects, approvals, panel, sidebar, help }

    let art: Art
    let title: String
    let text: String
    var id: Art { art }

    /// Built when drawn, so a language change in Settings shows up right away.
    static var all: [TourCard] {
        [
            TourCard(
                art: .sessions,
                title: L("Sessions and agents", "Oturumlar ve ajanlar"),
                text: L("Start a session, then choose its agent and model right under the message box.", "Bir oturum başlatın; ajanını ve modelini mesaj kutusunun hemen altından seçin.")
            ),
            TourCard(
                art: .projects,
                title: L("Projects", "Projeler"),
                text: L("A project is a folder with instructions that every agent working in it follows.", "Proje, içinde çalışan her ajanın uyduğu talimatları taşıyan bir klasördür.")
            ),
            TourCard(
                art: .approvals,
                title: L("Approvals", "Onaylar"),
                text: L("When an agent needs your OK, it stops and waits, and the Dock badge and a notification let you know.", "Bir ajanın onayınıza ihtiyacı olduğunda durup bekler; Dock'taki rozet ve bir bildirim size haber verir.")
            ),
            TourCard(
                art: .panel,
                title: L("The side panel", "Yan panel"),
                text: L("Next to each chat you can browse Files, review Changes to revert or commit them, use a Terminal, or open a Preview.", "Her sohbetin yanında Dosyalar'a göz atabilir, Değişiklikler'i inceleyip geri alabilir ya da commit edebilir, Terminal kullanabilir veya Önizleme açabilirsiniz.")
            ),
            TourCard(
                art: .sidebar,
                title: L("Scheduled tasks and usage", "Zamanlanmış görevler ve kullanım"),
                text: L("In the sidebar, Scheduled tasks run agents at the times you set, and Usage shows what each one has spent.", "Kenar çubuğunda Zamanlanmış görevler ajanları belirlediğiniz saatlerde çalıştırır, Kullanım da her birinin ne harcadığını gösterir.")
            ),
            TourCard(
                art: .help,
                title: L("Where to find help", "Yardım nerede"),
                text: L("If something doesn't work, choose Help › Report a Problem… and send us the details.", "Bir şey çalışmazsa Yardım › Sorun Bildir… ile ayrıntıları bize gönderin.")
            ),
        ]
    }
}

struct WelcomeTourView: View {
    let close: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page: Int
    @State private var forward = true
    @AccessibilityFocusState private var textFocused: Bool

    init(close: @escaping () -> Void, initialPage: Int = 0) {
        self.close = close
        _page = State(initialValue: initialPage)
    }

    var body: some View {
        let cards = TourCard.all
        let card = cards[page]
        let last = page == cards.count - 1
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                TourArt(art: card.art)
                    .frame(maxWidth: .infinity)
                    .frame(height: 190)
                    .background(Color.kervanWell.opacity(0.55), in: RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
                    .accessibilityHidden(true)
                    .padding(.bottom, 22)

                VStack(alignment: .leading, spacing: 8) {
                    Text(card.title)
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text(card.text)
                        .font(.system(.title3, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($textFocused)
            }
            .id(page)
            .transition(slide)

            Spacer(minLength: 16)

            HStack(spacing: 12) {
                // The same width on every card, so the dots and buttons don't shift on the last one.
                Button(L("Skip tour", "Turu geç"), action: close)
                    .buttonStyle(QuietPillStyle())
                    .opacity(last ? 0 : 1)
                    .disabled(last)
                    .accessibilityHidden(last)
                Spacer()
                PageDots(count: cards.count, page: page) { move(to: $0) }
                Spacer()
                if page > 0 {
                    Button(L("Back", "Geri")) { move(to: page - 1) }
                        .buttonStyle(QuietPillStyle())
                        .keyboardShortcut(.leftArrow, modifiers: [])
                }
                Button(last ? L("Done", "Tamam") : L("Next", "İleri")) {
                    if last { close() } else { move(to: page + 1) }
                }
                .buttonStyle(PrimaryPillStyle())
                .keyboardShortcut(.defaultAction)
            }
            // Escape closes the tour from any card and the right arrow goes forward; zero-size buttons carry the keys.
            .background {
                ZStack {
                    Button("", action: close)
                        .keyboardShortcut(.cancelAction)
                    Button("") { if !last { move(to: page + 1) } }
                        .keyboardShortcut(.rightArrow, modifiers: [])
                }
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            }
        }
        .padding(28)
        .frame(width: 560, height: 430)
        .background(Color.kervanCanvas)
        .onAppear { textFocused = true }
    }

    private var slide: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: forward ? 18 : -18)),
            removal: .opacity
        )
    }

    private func move(to next: Int) {
        guard next != page, next >= 0, next < TourCard.all.count else { return }
        forward = next > page
        withAnimation(Motion.pick(Motion.smooth, reduce: reduceMotion)) { page = next }
        // VoiceOver reads the new card instead of staying on the button.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            textFocused = true
        }
    }
}

/// Where you are in the tour; each dot jumps to its card.
private struct PageDots: View {
    let count: Int
    let page: Int
    let pick: (Int) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { index in
                Button { pick(index) } label: {
                    Capsule()
                        .fill(index == page ? Color.kervanLapis : Color.primary.opacity(0.18))
                        .frame(width: index == page ? 18 : 7, height: 7)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .animation(Motion.pick(Motion.fast, reduce: reduceMotion), value: page)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Step \(page + 1) of \(count)", "Adım \(page + 1) / \(count)"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: pick(min(page + 1, count - 1))
            case .decrement: pick(max(page - 1, 0))
            @unknown default: break
            }
        }
    }
}

// MARK: - Illustrations
// Small drawings of the real screens, built from soft shapes. Saffron rings mark the part each card talks about.

private struct TourArt: View {
    let art: TourCard.Art

    var body: some View {
        switch art {
        case .sessions: SessionsArt()
        case .projects: ProjectsArt()
        case .approvals: ApprovalsArt()
        case .panel: PanelArt()
        case .sidebar: SidebarArt()
        case .help: HelpArt()
        }
    }
}

/// A placeholder line of text.
private struct Line: View {
    let width: CGFloat
    var tint: Color = Color.primary.opacity(0.13)
    var height: CGFloat = 6

    var body: some View {
        Capsule().fill(tint).frame(width: width, height: height)
    }
}

/// A tiny window: three quiet dots for the title bar, then its content.
private struct MiniWindow<Content: View>: View {
    let width: CGFloat
    let height: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(Color.primary.opacity(0.14)).frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: width, height: height)
        .softSurface(radius: Radius.card)
    }
}

private extension View {
    /// The saffron ring that says "this part".
    func tourHighlight(radius: CGFloat = Radius.chip) -> some View {
        overlay {
            RoundedRectangle(cornerRadius: radius + 3, style: .continuous)
                .strokeBorder(Color.kervanSaffron, lineWidth: 1.5)
                .padding(-4)
        }
    }

    func artFont(_ size: CGFloat = 10, weight: Font.Weight = .medium) -> some View {
        font(.system(size: size, weight: weight, design: .rounded))
    }
}

private struct Chip: View {
    let symbol: String
    let text: String
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(text)
        }
        .artFont()
        .foregroundStyle(tint)
        .lineLimit(1)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color.kervanWell, in: Capsule())
    }
}

/// A chat with the composer, and the agent and model chips under it.
private struct SessionsArt: View {
    var body: some View {
        MiniWindow(width: 300, height: 156) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Line(width: 90, tint: Color.kervanLapis.opacity(0.45))
                        Line(width: 60, tint: Color.kervanLapis.opacity(0.45))
                    }
                    .padding(8)
                    .background(Color.kervanLapis.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Line(width: 150)
                    Line(width: 120)
                }
                Spacer(minLength: 0)
                HStack {
                    Line(width: 110)
                    Spacer()
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.kervanLapis)
                }
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(Color.kervanWell, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                HStack(spacing: 6) {
                    Chip(symbol: "sparkle", text: "Claude Code", tint: .kervanLapis)
                    Chip(symbol: "cpu", text: L("Model", "Model"))
                }
                .tourHighlight(radius: 10)
                .padding(.leading, 4)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }
}

/// A project folder with its instructions, shared by every agent working in it.
private struct ProjectsArt: View {
    private let agents = ["Claude Code", "Codex", "Gemini"]

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Lines from the folder to each agent.
            Path { path in
                for index in 0..<3 {
                    path.move(to: CGPoint(x: 112, y: 78))
                    path.addLine(to: CGPoint(x: 176, y: 34 + CGFloat(index) * 44))
                }
            }
            .stroke(Color.kervanSaffron.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 4]))

            VStack(spacing: 6) {
                ZStack {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 62))
                        .foregroundStyle(Color.kervanLapis.opacity(0.85))
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.kervanSurface)
                        .offset(y: 5)
                }
                Text(L("Instructions", "Talimatlar"))
                    .artFont(10, weight: .semibold)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 104)
            .position(x: 62, y: 80)

            VStack(alignment: .leading, spacing: 16) {
                ForEach(agents, id: \.self) { name in
                    HStack(spacing: 6) {
                        StatusDot(color: .kervanOasis, size: 6)
                        Text(name).artFont(11)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .softSurface(radius: Radius.chip)
                }
            }
            .offset(x: 180, y: 20)
        }
        .frame(width: 300, height: 156)
    }
}

/// An agent waiting on an approval, a notification, and the Dock icon with its badge.
private struct ApprovalsArt: View {
    var body: some View {
        HStack(alignment: .center, spacing: 22) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 5) {
                    StatusDot(color: .kervanSaffron, size: 6)
                    Text(L("Waiting for you", "Onayınızı bekliyor"))
                        .artFont(10, weight: .semibold)
                        .foregroundStyle(Color.kervanSaffron)
                }
                Text("npm test")
                    .font(.system(size: 10, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.kervanWell, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                HStack(spacing: 6) {
                    Text(L("Allow", "İzin ver"))
                        .artFont(10, weight: .semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.kervanLapis, in: Capsule())
                    Text(L("Deny", "Reddet"))
                        .artFont(10)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                }
            }
            .padding(12)
            .frame(width: 160)
            .softSurface(radius: Radius.card)
            .tourHighlight(radius: Radius.card)

            VStack(alignment: .trailing, spacing: 16) {
                HStack(spacing: 7) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 4) {
                        Line(width: 70, tint: Color.primary.opacity(0.28))
                        Line(width: 50)
                    }
                }
                .padding(8)
                .softSurface(radius: Radius.chip)

                HStack(spacing: 8) {
                    ForEach(0..<2, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.10))
                            .frame(width: 32, height: 32)
                    }
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 36, height: 36)
                        .overlay(alignment: .topTrailing) {
                            Text("1")
                                .artFont(10, weight: .bold)
                                .foregroundStyle(.white)
                                .frame(width: 16, height: 16)
                                .background(Color.kervanSaffron, in: Circle())
                                .offset(x: 4, y: -4)
                        }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.kervanSurface.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }
}

/// A chat with the side panel open on Changes: a small diff, Revert and Commit.
private struct PanelArt: View {
    private let tabs = ["folder", "plus.forwardslash.minus", "terminal", "globe"]

    var body: some View {
        MiniWindow(width: 320, height: 156) {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Line(width: 80)
                    Line(width: 60)
                    Spacer(minLength: 0)
                    Line(width: 70, tint: Color.kervanWell, height: 20)
                }
                .padding([.leading, .bottom], 10)
                .frame(width: 106, alignment: .leading)

                Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1)

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 2) {
                        ForEach(tabs.indices, id: \.self) { index in
                            Image(systemName: tabs[index])
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(index == 1 ? Color.white : Color.secondary)
                                .frame(width: 34, height: 18)
                                .background(index == 1 ? Color.kervanLapis : Color.clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                    }
                    .padding(2)
                    .background(Color.kervanWell, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .tourHighlight(radius: 7)

                    VStack(alignment: .leading, spacing: 3) {
                        diff(added: false, width: 110)
                        diff(added: true, width: 130)
                        diff(added: true, width: 90)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 6) {
                        Text(L("Revert", "Geri al"))
                            .artFont(9)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.kervanWell, in: Capsule())
                        Text("Commit")
                            .artFont(9, weight: .semibold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.kervanLapis, in: Capsule())
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 2)
                .padding(.bottom, 10)
            }
        }
    }

    private func diff(added: Bool, width: CGFloat) -> some View {
        let tint = added ? Color.kervanOasis : Color.kervanCoral
        return HStack(spacing: 5) {
            Image(systemName: added ? "plus" : "minus")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(tint)
            Line(width: width, tint: tint.opacity(0.45), height: 5)
        }
        .padding(.horizontal, 5)
        .frame(height: 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

/// The sidebar's first two rows, with a schedule and a small usage chart beside them.
private struct SidebarArt: View {
    private let bars: [CGFloat] = [0.35, 0.6, 0.45, 0.8, 0.55, 0.95]

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 6) {
                    row(symbol: "calendar.badge.clock", text: L("Scheduled tasks", "Zamanlanmış görevler"))
                    row(symbol: "chart.bar", text: L("Usage", "Kullanım"))
                }
                .tourHighlight(radius: 7)
                .padding(.bottom, 6)
                ForEach(0..<3, id: \.self) { index in
                    HStack(spacing: 6) {
                        StatusDot(color: index == 0 ? .kervanSaffron : .kervanOasis, size: 5)
                        Line(width: CGFloat(70 - index * 12))
                    }
                    .padding(.leading, 6)
                }
            }
            .padding(12)
            .frame(width: 158, height: 150, alignment: .topLeading)
            .background(Color.kervanSidebar, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))

            VStack(alignment: .leading, spacing: 12) {
                Chip(symbol: "clock", text: L("Every day 09:00", "Her gün 09:00"), tint: .kervanSaffron)
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(bars.indices, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.kervanLapis.opacity(index == bars.count - 1 ? 0.9 : 0.45))
                            .frame(width: 12, height: 70 * bars[index])
                    }
                }
                .frame(height: 70, alignment: .bottom)
                .padding(10)
                .softSurface(radius: Radius.chip)
            }
        }
    }

    private func row(symbol: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(Color.kervanLapis)
                .frame(width: 14)
            Text(text)
        }
        .artFont(10)
        .lineLimit(1)
    }
}

/// The menu bar with the Help menu open on Report a Problem.
private struct HelpArt: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "apple.logo").font(.system(size: 10))
                Text("Kervan").artFont(10, weight: .bold)
                Text(L("File", "Dosya")).artFont(10)
                Text(L("Edit", "Düzen")).artFont(10)
                Text(L("View", "Görüntü")).artFont(10)
                Text(L("Window", "Pencere")).artFont(10)
                Text(L("Help", "Yardım"))
                    .artFont(10, weight: .semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.kervanLapis, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.kervanSurface.opacity(0.85))

            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Report a Problem…", "Sorun Bildir…"))
                        .artFont(11)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.kervanLapis, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    Text(L("Kervan on GitHub", "GitHub'da Kervan"))
                        .artFont(11)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                .lineLimit(1)
                .padding(5)
                .frame(width: 170)
                .softSurface(radius: 8)
                .tourHighlight(radius: 8)
                .padding(.top, 4)
                .padding(.trailing, 18)
            }
        }
        .frame(width: 340)
        .padding(.bottom, 40)
    }
}
