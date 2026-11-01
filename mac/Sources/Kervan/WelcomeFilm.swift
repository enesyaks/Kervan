import KervanKit
import SwiftUI

/// The welcome step's short film: what Kervan does, in four chapters on one stage. Your Mac on the left, your
/// server on the right, and the caravan carrying work along the gold route between them.
///
/// 1. You write a task on the Mac and the caravan takes it to the server.
/// 2. Agents work there while the Mac sleeps; code and keys stay on the server.
/// 3. An agent needs an OK: the phone gets a note, you allow it, the caravan takes the answer back.
/// 4. The work comes home: the changes, then a pull request.
///
/// It plays once (about 20 seconds) with chapter marks to jump around, and stops on the last frame. With Reduce
/// Motion it doesn't play: each chapter shows its finished frame and the button steps to the next one.
/// Everything is drawn with shapes and text, so it follows the language and stays sharp at any size.
struct WelcomeFilm: View {
    /// A fixed moment instead of playing, for snapshots.
    var fixedTime: Double?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Where the film is while paused, and where it started from while playing.
    @State private var base: Double = 0
    /// Set while playing.
    @State private var startedAt: Date?
    @State private var started = false

    private var playing: Bool { startedAt != nil }

    init(fixedTime: Double? = nil) {
        self.fixedTime = fixedTime
        _base = State(initialValue: fixedTime ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !playing)) { context in
                let time = time(at: context.date)
                FilmStage(time: time, still: reduceMotion || fixedTime != nil)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Film.caption(Film.chapter(at: time)).spoken)
            }
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !playing)) { context in
                FilmControls(
                    time: time(at: context.date),
                    playing: playing,
                    stepping: reduceMotion,
                    toggle: toggle,
                    seek: seek
                )
            }
        }
        .onAppear {
            guard !started else { return }
            started = true
            if fixedTime != nil {
                return
            } else if reduceMotion {
                base = Film.finished(0)
            } else {
                startedAt = .now
            }
        }
        .onDisappear { startedAt = nil }
        // Stops on the last frame instead of ticking on.
        .task(id: startedAt) {
            guard let from = startedAt else { return }
            let left = Film.length - base
            try? await Task.sleep(for: .seconds(max(0, left)))
            guard !Task.isCancelled, startedAt == from else { return }
            base = Film.length
            startedAt = nil
        }
    }

    private func time(at now: Date) -> Double {
        let running = startedAt.map { now.timeIntervalSince($0) } ?? 0
        return min(Film.length, base + running)
    }

    private func toggle() {
        if reduceMotion {
            let next = Film.chapter(at: base) + 1
            base = Film.finished(next < Film.chapters ? next : 0)
        } else if let startedAt {
            base = min(Film.length, base + Date.now.timeIntervalSince(startedAt))
            self.startedAt = nil
        } else {
            if base >= Film.length - 0.01 { base = 0 }
            startedAt = .now
        }
    }

    private func seek(_ chapter: Int) {
        if reduceMotion {
            base = Film.finished(chapter)
        } else {
            base = Double(chapter) * Film.chapterLength
            startedAt = .now
        }
    }
}

// MARK: - Timing and words

enum Film {
    static let chapters = 4
    static let chapterLength: Double = 5
    static let length = Double(chapters) * chapterLength

    static func chapter(at time: Double) -> Int {
        min(chapters - 1, max(0, Int(time / chapterLength)))
    }

    /// How far into its chapter `time` is, 0 to 1.
    static func progress(at time: Double) -> Double {
        let chapter = chapter(at: time)
        return min(1, max(0, (time - Double(chapter) * chapterLength) / chapterLength))
    }

    /// A chapter's finished frame, where everything in it has happened (for Reduce Motion and the chapter marks).
    static func finished(_ chapter: Int) -> Double {
        (Double(chapter) + 0.92) * chapterLength
    }

    struct Caption {
        let mark: String
        let title: String
        let text: String
        var spoken: String { "\(title). \(text)" }
    }

    /// Built when drawn, so a language change shows up right away.
    static func caption(_ chapter: Int) -> Caption {
        switch chapter {
        case 0:
            Caption(
                mark: L("Ask", "Yazın"),
                title: L("Tell it what to do", "Ne yapılacağını yazın"),
                text: L("Write a task on your Mac. Kervan carries it to your own server.", "Görevi Mac'inizde yazın. Kervan onu kendi sunucunuza taşır.")
            )
        case 1:
            Caption(
                mark: L("Work", "Çalışsın"),
                title: L("Agents work on your server", "Ajanlar sunucunuzda çalışır"),
                text: L("Claude, Codex and Gemini keep going while your Mac sleeps. Your code and keys stay there.", "Claude, Codex ve Gemini, Mac'iniz uyurken de çalışır. Kodunuz ve anahtarlarınız orada kalır.")
            )
        case 2:
            Caption(
                mark: L("Approve", "Onaylayın"),
                title: L("It asks before it acts", "Gerekince size sorar"),
                text: L("When an agent needs your OK, your Mac or phone gets a note. One tap and it goes on.", "Bir ajan onayınızı isteyince Mac'inize ya da telefonunuza bildirim gelir. Tek dokunuşla devam eder.")
            )
        default:
            Caption(
                mark: L("Ship", "Gönderin"),
                title: L("Review and ship", "İnceleyin, gönderin"),
                text: L("See every change, undo what you don't want, and open a pull request.", "Her değişikliği görün, istemediğinizi geri alın ve pull request açın.")
            )
        }
    }

    /// 0 before `from`, 1 after `to`, eased in between.
    static func ramp(_ p: Double, _ from: Double, _ to: Double) -> Double {
        let x = min(1, max(0, (p - from) / (to - from)))
        return x * x * (3 - 2 * x)
    }
}

// MARK: - The stage

/// Drawn at 480 × 262 points and scaled to the width it is given.
private struct FilmStage: View {
    let time: Double
    /// No caravan on the road: Reduce Motion and snapshots show finished frames.
    let still: Bool

    static let size = CGSize(width: 480, height: 262)

    var body: some View {
        let chapter = Film.chapter(at: time)
        let p = Film.progress(at: time)
        Color.clear
            .aspectRatio(Self.size.width / Self.size.height, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    let scale = proxy.size.width / Self.size.width
                    canvas(chapter: chapter, p: p)
                        .frame(width: Self.size.width, height: Self.size.height)
                        .scaleEffect(scale, anchor: .topLeading)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
    }

    private func canvas(chapter: Int, p: Double) -> some View {
        ZStack(alignment: .topLeading) {
            NightSky()
            Road(chapter: chapter, p: p, still: still)
            MacScreen(chapter: chapter, p: p)
                .position(x: 112, y: 96)
            Phone(chapter: chapter, p: p)
                .position(x: 86, y: 104)
            ServerCard(chapter: chapter, p: p)
                .position(x: 376, y: 96)
            CaptionBand(chapter: chapter, p: p, last: chapter == Film.chapters - 1)
                .frame(width: Self.size.width, height: 76)
                .position(x: Self.size.width / 2, y: Self.size.height - 38)
        }
        .environment(\.colorScheme, .dark)
    }
}

private enum Palette {
    static let gold = Color(light: 0xE8B65A, dark: 0xE8B65A)
    static let light = Color(light: 0xF5C76A, dark: 0xF5C76A)
    static let oasis = Color(light: 0x5DB38C, dark: 0x5DB38C)
    static let lapis = Color(light: 0x8AAEDB, dark: 0x8AAEDB)
    static let coral = Color(light: 0xE8968A, dark: 0xE8968A)
    static let window = Color(light: 0x1E2A3D, dark: 0x1E2A3D)
    static let well = Color(light: 0x2A3A55, dark: 0x2A3A55)
}

/// The intro's sky: lapis fading to night, with a few still stars.
private struct NightSky: View {
    private static let stars: [(CGFloat, CGFloat, CGFloat)] = [
        (36, 14, 1.4), (150, 10, 1), (226, 22, 1.6), (268, 8, 1), (330, 16, 1.2), (440, 12, 1.5),
        (250, 120, 1), (232, 160, 1.3), (466, 150, 1), (14, 170, 1.2), (290, 176, 1),
    ]

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(light: 0x2F5D8A, dark: 0x2F5D8A), Color(light: 0x16243A, dark: 0x16243A)], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color.white.opacity(0.10), .clear], center: .init(x: 0.5, y: 0), startRadius: 0, endRadius: 300)
            ForEach(Self.stars.indices, id: \.self) { index in
                let star = Self.stars[index]
                Circle()
                    .fill(Color.white.opacity(0.55))
                    .frame(width: star.2 * 2, height: star.2 * 2)
                    .position(x: star.0, y: star.1)
            }
        }
    }
}

/// The gold route from the Mac to the server, and the caravan on it when something is on its way.
private struct Road: View {
    let chapter: Int
    let p: Double
    let still: Bool

    static let start = CGPoint(x: 204, y: 92)
    static let end = CGPoint(x: 292, y: 92)
    static let bend = CGPoint(x: 248, y: 48)

    var body: some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: Self.start)
                path.addQuadCurve(to: Self.end, control: Self.bend)
            }
            .stroke(Palette.gold.opacity(0.55), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [1, 6]))
            if let trip, !still {
                ForEach(0..<3, id: \.self) { index in
                    let s = trip.at - Double(index) * 0.09
                    if s > 0 && s < 1 {
                        Circle()
                            .fill(Palette.light)
                            .frame(width: 8, height: 8)
                            .shadow(color: Palette.gold.opacity(0.8), radius: 5)
                            .opacity(sin(s * .pi) * 0.7 + 0.3)
                            .position(Self.point(trip.forward ? s : 1 - s))
                    }
                }
            }
        }
    }

    /// Where the caravan is on this chapter's trip, if it is travelling: there with the task, back with the answer
    /// and then the results.
    private var trip: (at: Double, forward: Bool)? {
        let leg: (Double, Double, Bool)? = switch chapter {
        case 0: (0.58, 0.86, true)
        case 2: (0.62, 0.88, true)
        case 3: (0.02, 0.3, false)
        default: nil
        }
        guard let leg, p > leg.0, p < leg.1 + 0.2 else { return nil }
        return ((p - leg.0) / (leg.1 - leg.0), leg.2)
    }

    static func point(_ s: Double) -> CGPoint {
        let a = start, b = end, c = bend, t = CGFloat(s), u = 1 - t
        return CGPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * b.x, y: u * u * a.y + 2 * u * t * c.y + t * t * b.y)
    }
}

/// A small window, in the app's dark colors.
private struct StageWindow<Content: View>: View {
    let width: CGFloat
    let height: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(Color.white.opacity(0.18)).frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: width, height: height)
        .background(Palette.window, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
    }
}

private extension View {
    func stageFont(_ size: CGFloat = 9, weight: Font.Weight = .medium) -> some View {
        font(.system(size: size, weight: weight, design: .rounded))
    }
}

/// The Mac: the chat with your task, then asleep, then the changes and the pull request.
private struct MacScreen: View {
    let chapter: Int
    let p: Double

    private var prompt: String { L("Add dark mode to Settings", "Ayarlara karanlık mod ekle") }

    var body: some View {
        StageWindow(width: 180, height: 136) {
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 7) {
                    if chapter == 3 && p > 0.3 {
                        ChangesCard(p: p).opacity(Film.ramp(p, 0.3, 0.42))
                    } else {
                        if sent { bubble.opacity(chapter == 0 ? Film.ramp(p, 0.52, 0.6) : 1) }
                        if chapter >= 1 { reply }
                    }
                    Spacer(minLength: 0)
                    composer
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                sleep
            }
        }
        .overlay {
            // Home again: the oasis glow once the pull request is open.
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Palette.oasis, lineWidth: 1.5)
                .shadow(color: Palette.oasis.opacity(0.8), radius: 10)
                .opacity(chapter == 3 ? Film.ramp(p, 0.72, 0.85) : 0)
        }
    }

    private var sent: Bool { chapter > 0 || p > 0.52 }

    private var bubble: some View {
        HStack {
            Spacer(minLength: 20)
            Text(prompt)
                .stageFont(9)
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Palette.lapis.opacity(0.30), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }

    private var reply: some View {
        HStack(spacing: 5) {
            Image(systemName: "sparkle").foregroundStyle(Palette.lapis)
            Text(chapter == 1 ? L("Working on it…", "Üzerinde çalışıyor…") : L("Changing 3 files", "3 dosyayı değiştiriyor"))
                .foregroundStyle(.white.opacity(0.7))
        }
        .stageFont(8.5)
    }

    private var composer: some View {
        let typed = chapter == 0 && !sent ? Film.ramp(p, 0.06, 0.44) : 0
        let shown = String(prompt.prefix(Int((Double(prompt.count) * typed).rounded())))
        let pressed = chapter == 0 && p > 0.46 && p < 0.56
        return HStack(spacing: 6) {
            Text(shown.isEmpty ? L("Message", "Mesaj") : shown)
                .stageFont(8.5)
                .foregroundStyle(.white.opacity(shown.isEmpty ? 0.35 : 0.9))
                .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Palette.lapis)
                .scaleEffect(pressed ? 1.25 : 1)
                .shadow(color: Palette.lapis.opacity(pressed ? 0.9 : 0), radius: 6)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Palette.well, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    /// The lid closed: dimmed with a moon, while the server keeps working.
    private var sleep: some View {
        let amount = chapter == 1 ? Film.ramp(p, 0.22, 0.4) : chapter == 2 ? 1 - Film.ramp(p, 0, 0.12) : 0
        return ZStack {
            RoundedRectangle(cornerRadius: Radius.card - 2, style: .continuous).fill(Color(light: 0x0B111A, dark: 0x0B111A).opacity(0.86))
            VStack(spacing: 6) {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Palette.light)
                Text(L("Mac is asleep", "Mac uyuyor"))
                    .stageFont(9, weight: .semibold)
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .padding(.top, -20)
        .opacity(amount)
    }
}

/// What came back: the files changed, then the pull request.
private struct ChangesCard: View {
    let p: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text(L("3 files changed", "3 dosya değişti")).foregroundStyle(.white.opacity(0.9))
                Spacer(minLength: 0)
                Text("+42").foregroundStyle(Palette.oasis)
                Text("−7").foregroundStyle(Palette.coral)
            }
            .stageFont(8.5, weight: .semibold)
            row("SettingsView.swift", added: 52, removed: 10)
            row("Theme.swift", added: 34, removed: 0)
            row("README.md", added: 12, removed: 4)
            pullRequest.padding(.top, 2)
        }
    }

    private func row(_ name: String, added: CGFloat, removed: CGFloat) -> some View {
        HStack(spacing: 4) {
            Text(name)
                .font(.system(size: 7.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)
            Spacer(minLength: 0)
            Capsule().fill(Palette.oasis).frame(width: added * 0.5, height: 3)
            if removed > 0 { Capsule().fill(Palette.coral).frame(width: removed * 0.5, height: 3) }
        }
    }

    private var pullRequest: some View {
        let open = p > 0.66
        let pressed = p > 0.56 && p <= 0.66
        return HStack(spacing: 4) {
            Image(systemName: open ? "checkmark.circle.fill" : "arrow.triangle.pull")
            Text(open ? L("Pull request opened", "Pull request açıldı") : L("Open pull request", "Pull request aç"))
        }
        .stageFont(8.5, weight: .semibold)
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(open ? Palette.oasis.opacity(0.85) : Palette.lapis.opacity(pressed ? 0.75 : 0.45), in: Capsule())
        .scaleEffect(pressed ? 0.94 : 1)
    }
}

/// Your phone, with the note that an agent is waiting for you.
private struct Phone: View {
    let chapter: Int
    let p: Double

    var body: some View {
        let shown = chapter == 2 ? Film.ramp(p, 0.04, 0.2) : 0
        VStack(spacing: 6) {
            Capsule().fill(Color.black).frame(width: 22, height: 6).padding(.top, 6)
            note.opacity(chapter == 2 ? Film.ramp(p, 0.18, 0.3) : 0)
            Spacer(minLength: 0)
        }
        .frame(width: 78, height: 136)
        .background(Color(light: 0x0F1620, dark: 0x0F1620), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 1.5)
        }
        .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
        .offset(y: (1 - shown) * 40)
        .opacity(shown)
    }

    private var note: some View {
        let allowed = p > 0.58
        let pressed = p > 0.48 && p <= 0.58
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Circle().fill(Palette.gold).frame(width: 7, height: 7)
                Text("Kervan").stageFont(7.5, weight: .semibold).foregroundStyle(.white.opacity(0.9))
            }
            Text(L("Claude Code is waiting for your OK", "Claude Code onayınızı bekliyor"))
                .stageFont(7.5)
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 3) {
                if allowed { Image(systemName: "checkmark") }
                Text(allowed ? L("Allowed", "İzin verildi") : L("Allow", "İzin ver"))
            }
            .stageFont(7.5, weight: .semibold)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(allowed ? Palette.oasis.opacity(0.85) : Palette.lapis.opacity(pressed ? 0.9 : 0.55), in: Capsule())
            .scaleEffect(pressed ? 0.92 : 1)
        }
        .padding(6)
        .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(.horizontal, 5)
    }
}

/// The server: three agents and how far each has got.
private struct ServerCard: View {
    let chapter: Int
    let p: Double

    var body: some View {
        StageWindow(width: 172, height: 150) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "server.rack").foregroundStyle(Palette.lapis)
                    Text(L("Your server", "Sunucunuz")).foregroundStyle(.white.opacity(0.9))
                    Spacer(minLength: 0)
                    Circle().fill(Palette.oasis).frame(width: 6, height: 6)
                        .shadow(color: Palette.oasis.opacity(0.8), radius: 3)
                }
                .stageFont(9, weight: .semibold)
                AgentRow(name: "Claude Code", task: L("Dark mode", "Karanlık mod"), done: progress(0), waiting: waiting)
                AgentRow(name: "Codex", task: L("Tests", "Testler"), done: progress(1), waiting: false)
                AgentRow(name: "Gemini", task: L("Docs", "Belgeler"), done: progress(2), waiting: false)
                HStack(spacing: 4) {
                    Image(systemName: "lock.fill")
                    Text(L("Code and keys stay here", "Kod ve anahtarlar burada"))
                }
                .stageFont(7.5)
                .foregroundStyle(Palette.light.opacity(0.9))
                .opacity(chapter == 1 ? Film.ramp(p, 0.5, 0.62) : chapter > 1 ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
    }

    /// Claude stops for your OK in chapter three until you allow it.
    private var waiting: Bool { chapter == 2 && p > 0.14 && p < 0.86 }

    private func progress(_ agent: Int) -> Double {
        switch chapter {
        case 0:
            return agent == 0 ? 0.08 * Film.ramp(p, 0.86, 1) : 0
        case 1:
            let starts = [0.0, 0.12, 0.24], reach = [0.6, 0.55, 0.45]
            return 0.08 * (agent == 0 ? 1 : 0) + reach[agent] * Film.ramp(p, starts[agent], 1)
        case 2:
            let from = [0.68, 0.55, 0.45]
            if agent == 0 { return from[0] + 0.22 * Film.ramp(p, 0.86, 1) }
            return from[agent] + (1 - from[agent]) * Film.ramp(p, 0, 0.9)
        default:
            return agent == 0 ? 0.9 + 0.1 * Film.ramp(p, 0, 0.1) : 1
        }
    }
}

private struct AgentRow: View {
    let name: String
    let task: String
    let done: Double
    let waiting: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(name).stageFont(8.5, weight: .semibold).foregroundStyle(.white.opacity(0.9))
                    .layoutPriority(1)
                Text(task).stageFont(7.5).foregroundStyle(.white.opacity(0.5))
                Spacer(minLength: 0)
                status
            }
            .lineLimit(1)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10))
                    Capsule().fill(done >= 1 ? Palette.oasis : waiting ? Palette.gold : Palette.lapis)
                        .frame(width: proxy.size.width * min(1, done))
                }
            }
            .frame(height: 3)
        }
    }

    @ViewBuilder
    private var status: some View {
        if done >= 1 {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 9)).foregroundStyle(Palette.oasis)
        } else if waiting {
            Image(systemName: "hand.raised.fill").font(.system(size: 8.5)).foregroundStyle(Palette.gold)
        } else if done > 0 {
            Circle().fill(Palette.lapis).frame(width: 5, height: 5)
        }
    }
}

/// The subtitles, over a dark band at the foot of the stage.
private struct CaptionBand: View {
    let chapter: Int
    let p: Double
    let last: Bool

    var body: some View {
        let caption = Film.caption(chapter)
        let shown = Film.ramp(p, 0, 0.06) * (last ? 1 : 1 - Film.ramp(p, 0.95, 1))
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [.clear, Color.black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 3) {
                Text(caption.title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(caption.text)
                    .font(.system(size: 11.5, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 12)
            .opacity(shown)
            .offset(y: (1 - shown) * 4)
        }
    }
}

// MARK: - Controls

/// Play or pause, and one mark per chapter that fills as it plays; a mark starts its chapter.
private struct FilmControls: View {
    let time: Double
    let playing: Bool
    /// Reduce Motion: the button goes to the next chapter instead of playing.
    let stepping: Bool
    let toggle: () -> Void
    let seek: (Int) -> Void

    var body: some View {
        let chapter = Film.chapter(at: time)
        HStack(alignment: .top, spacing: 12) {
            Button(action: toggle) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.kervanLapis)
                    .frame(width: 30, height: 30)
                    .background(Color.kervanLapis.opacity(0.12), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(SoftPressStyle())
            .help(label)
            .accessibilityLabel(label)

            ForEach(0..<Film.chapters, id: \.self) { index in
                Button { seek(index) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.10))
                                Capsule().fill(Color.kervanLapis)
                                    .frame(width: proxy.size.width * fill(index))
                            }
                        }
                        .frame(height: 4)
                        Text(Film.caption(index).mark)
                            .font(.system(.caption, design: .rounded).weight(index == chapter ? .semibold : .regular))
                            .foregroundStyle(index == chapter ? Color.primary : Color.secondary)
                    }
                    .padding(.top, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Film.caption(index).title)
                .accessibilityAddTraits(index == chapter ? .isSelected : [])
            }
        }
    }

    private var ended: Bool { time >= Film.length - 0.01 }

    private var symbol: String {
        if stepping { return "forward.end.fill" }
        if playing { return "pause.fill" }
        return ended ? "arrow.counterclockwise" : "play.fill"
    }

    private var label: String {
        if stepping { return L("Next chapter", "Sonraki bölüm") }
        if playing { return L("Pause", "Duraklat") }
        return ended ? L("Watch again", "Tekrar izle") : L("Play", "Oynat")
    }

    private func fill(_ index: Int) -> Double {
        let chapter = Film.chapter(at: time)
        if index < chapter { return 1 }
        if index > chapter { return 0 }
        return stepping ? 1 : Film.progress(at: time)
    }
}
