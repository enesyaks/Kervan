import KervanKit
import SwiftUI

/// Mac ●────● server. The line *is* the connection status: dotted when idle, a caravan of three
/// dots travelling while connecting, solid when connected, broken when it failed.
struct RouteView: View {
    let state: ConnectionState
    let host: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            RouteNode(title: "Mac", symbol: "laptopcomputer", color: .kervanLapis, filled: true)
            TimelineView(.animation(paused: !isAnimating)) { context in
                Canvas { canvas, size in
                    drawLine(in: &canvas, size: size, time: context.date.timeIntervalSinceReferenceDate)
                }
            }
            .frame(height: 12)
            RouteNode(title: host.isEmpty ? "Sunucu" : host, symbol: "server.rack", color: state.tint, filled: isConnected)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Bağlantı: \(state.shortLabel), \(host)")
    }

    private var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    private var isAnimating: Bool {
        if case .connecting = state { return !reduceMotion }
        return false
    }

    private func drawLine(in canvas: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let y = size.height / 2
        func segment(_ from: CGFloat, _ to: CGFloat) -> Path {
            Path { path in
                path.move(to: CGPoint(x: size.width * from, y: y))
                path.addLine(to: CGPoint(x: size.width * to, y: y))
            }
        }

        switch state {
        case .disconnected:
            canvas.stroke(segment(0, 1), with: .color(.secondary.opacity(0.5)),
                          style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [1.5, 6]))

        case .connected:
            canvas.stroke(segment(0, 1), with: .color(.kervanLapis), style: StrokeStyle(lineWidth: 2, lineCap: .round))

        case .failed:
            let style = StrokeStyle(lineWidth: 2, lineCap: .round)
            canvas.stroke(segment(0, 0.44), with: .color(.kervanCoral.opacity(0.8)), style: style)
            canvas.stroke(segment(0.56, 1), with: .color(.kervanCoral.opacity(0.35)), style: style)

        case .connecting, .retrying:
            canvas.stroke(segment(0, 1), with: .color(.kervanSaffron.opacity(0.3)),
                          style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 5]))
            for position in caravanPositions(time: time) {
                let dot = CGRect(x: size.width * position - 3.5, y: y - 3.5, width: 7, height: 7)
                canvas.fill(Path(ellipseIn: dot), with: .color(.kervanSaffron))
            }
        }
    }

    /// Three dots in single file. Moving while connecting; resting mid-way while waiting to retry
    /// or when Reduce Motion is on.
    private func caravanPositions(time: TimeInterval) -> [CGFloat] {
        let spacing: CGFloat = 0.07
        guard isAnimating else { return [0.5 - spacing, 0.5, 0.5 + spacing] }
        let lead = CGFloat(time.truncatingRemainder(dividingBy: 1.8) / 1.8)
        return (0..<3).map { index in
            let position = lead - CGFloat(index) * spacing
            return position < 0 ? position + 1 : position
        }
    }
}

private struct RouteNode: View {
    let title: String
    let symbol: String
    let color: Color
    let filled: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 44, height: 36)
                .background(color.opacity(filled ? 0.14 : 0.06), in: RoundedRectangle(cornerRadius: 9))
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(minWidth: 64)
    }
}

