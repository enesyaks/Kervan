import AppKit
import KervanKit
import SwiftUI

/// Shown when connected (or briefly reconnecting) and no session is selected.
struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let state = model.connection.state
        let host = model.activeAddress?.host ?? model.serverInput

        ScrollView {
            VStack(spacing: 26) {
                // The icon, the name and the route: who you are talking to, at a glance.
                VStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 96, height: 96)
                        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
                        .accessibilityHidden(true)
                    Text(Self.greeting())
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                    Text(state.isConnected ? "\(host) sunucusuna bağlısınız" : "\(host) sunucusuna yeniden bağlanıyoruz…")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("Ajanlarınız sunucuda çalışır. Mac uyusa da kapansa da işleriniz sürer; döndüğünüzde kaldığınız yerden devam edersiniz.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 440)
                }

                RouteView(state: state, host: host)
                    .frame(maxWidth: 380)

                VStack(spacing: 10) {
                    NewSessionButton()
                        .buttonStyle(.borderedProminent)
                        .tint(.kervanLapis)
                        .controlSize(.large)
                        .fixedSize()
                    Text(model.store.sessions.isEmpty
                         ? "Henüz oturum yok. İlk oturumu başlattığınızda soldaki listede görünecek."
                         : "Devam etmek için soldaki listeden bir oturum seçin.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(alignment: .leading, spacing: 0) {
                    if case .connected(let server) = state {
                        InfoRow(label: "Sunucu sürümü", value: server.version)
                        Divider().opacity(0.5)
                    }
                    InfoRow(label: "Gecikme", value: latencyText)
                    Divider().opacity(0.5)
                    InfoRow(label: "Ajanlar", value: model.store.agents.map(\.displayName).joined(separator: ", "))
                    Divider().opacity(0.5)
                    InfoRow(label: "Adres", value: model.activeAddress?.url.absoluteString ?? "", monospaced: true)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 6)
                .softSurface()
                .frame(maxWidth: 480)

                Button("Bağlantıyı kes") { model.disconnect() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 48)
            .frame(maxWidth: .infinity)
        }
        .background(Color.kervanCanvas)
    }

    /// A small human touch: the greeting follows the time of day.
    static func greeting(at date: Date = Date()) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: "Günaydın"
        case 12..<18: "İyi günler"
        case 18..<23: "İyi akşamlar"
        default: "İyi geceler"
        }
    }

    private var latencyText: String {
        guard let latency = model.connection.latency else { return "ölçülüyor…" }
        let ms = Double(latency.components.attoseconds) / 1e15 + Double(latency.components.seconds) * 1000
        return ms < 1 ? "<1 ms" : "\(Int(ms.rounded())) ms"
    }
}

private struct InfoRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(monospaced ? .callout.monospaced() : .body)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}
