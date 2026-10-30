import KervanKit
import SwiftUI

/// The opening, about two seconds: the icon's route is drawn across a night sky, three dots travel it
/// like a caravan, the oasis at the end lights up and the name appears; then the window opens up.
/// A click skips it. With Reduce Motion the finished picture shows briefly and fades.
struct IntroView: View {
    let finish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn: CGFloat = 0
    @State private var travelled: CGFloat = 0
    @State private var arrived = false
    @State private var named = false

    private static let gold = Color(light: 0xE8B65A, dark: 0xE8B65A)

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(light: 0x2F5D8A, dark: 0x2B527A), Color(light: 0x16243A, dark: 0x0D1420)],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(colors: [Color.white.opacity(0.10), .clear], center: .init(x: 0.5, y: 0.15), startRadius: 0, endRadius: 420)

            VStack(spacing: 30) {
                ZStack {
                    Route()
                        .trim(from: 0, to: drawn)
                        .stroke(Self.gold, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .shadow(color: Self.gold.opacity(0.35), radius: 6)
                    Oasis(lit: arrived)
                    Caravan(progress: travelled)
                }
                .frame(width: 280, height: 190)

                VStack(spacing: 8) {
                    Text("Kervan")
                        .font(.system(size: 42, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(L("Your agents are setting out", "Ajanlarınız yola çıkıyor"))
                        .font(.system(.title3, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .opacity(named ? 1 : 0)
                .offset(y: named || reduceMotion ? 0 : 10)
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture(perform: finish)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Kervan is starting", "Kervan açılıyor"))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(L("Click to skip", "Geçmek için tıklayın"))
        .task { await play() }
    }

    private func play() async {
        if reduceMotion {
            drawn = 1
            travelled = 1
            arrived = true
            named = true
            try? await Task.sleep(for: .milliseconds(700))
        } else {
            withAnimation(.easeInOut(duration: 0.7)) { drawn = 1 }
            try? await Task.sleep(for: .milliseconds(150))
            withAnimation(.timingCurve(0.45, 0, 0.25, 1, duration: 1.0)) { travelled = 1 }
            try? await Task.sleep(for: .milliseconds(750))
            withAnimation(Motion.smooth) { named = true }
            try? await Task.sleep(for: .milliseconds(250))
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { arrived = true }
            try? await Task.sleep(for: .milliseconds(800))
        }
        guard !Task.isCancelled else { return }
        finish()
    }
}

/// The S-shaped path from the icon, from lower left to the oasis at upper right.
private struct Route: Shape {
    static func point(_ t: CGFloat, in rect: CGRect) -> CGPoint {
        // Cubic Bézier through the icon's control points, in the unit square.
        let p0 = CGPoint(x: 0.04, y: 0.96), p1 = CGPoint(x: 0.22, y: 0.38)
        let p2 = CGPoint(x: 0.68, y: 0.80), p3 = CGPoint(x: 0.92, y: 0.10)
        let u = 1 - t
        let x = u * u * u * p0.x + 3 * u * u * t * p1.x + 3 * u * t * t * p2.x + t * t * t * p3.x
        let y = u * u * u * p0.y + 3 * u * u * t * p1.y + 3 * u * t * t * p2.y + t * t * t * p3.y
        return CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
    }

    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: Self.point(0, in: rect))
            for step in 1...64 { path.addLine(to: Self.point(CGFloat(step) / 64, in: rect)) }
        }
    }
}

/// Three dots in single file along the route; `progress` is where the leader is (0…1).
private struct Caravan: View, Animatable {
    var progress: CGFloat
    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        GeometryReader { geometry in
            let rect = CGRect(origin: .zero, size: geometry.size)
            ForEach(0..<3, id: \.self) { index in
                // The leader stops short of the oasis; the others keep their spacing behind it.
                let t = progress * 0.82 - CGFloat(index) * 0.13
                if t > 0 {
                    Circle()
                        .fill(Color(light: 0xF5C76A, dark: 0xF5C76A))
                        .frame(width: 16, height: 16)
                        .shadow(color: Color(light: 0xE8B65A, dark: 0xE8B65A).opacity(0.7), radius: 6)
                        .position(Route.point(t, in: rect))
                }
            }
        }
    }
}

/// The green point at the end of the route; it brightens and breathes out a ring when the caravan arrives.
private struct Oasis: View {
    let lit: Bool

    var body: some View {
        GeometryReader { geometry in
            let center = Route.point(1, in: CGRect(origin: .zero, size: geometry.size))
            let green = Color(light: 0x5DB38C, dark: 0x5DB38C)
            ZStack {
                Circle().fill(green.opacity(lit ? 0.22 : 0)).frame(width: 52, height: 52).scaleEffect(lit ? 1 : 0.5)
                Circle().fill(green.opacity(lit ? 1 : 0.45)).frame(width: 26, height: 26)
                    .shadow(color: green.opacity(lit ? 0.8 : 0), radius: 12)
            }
            .position(center)
        }
    }
}
