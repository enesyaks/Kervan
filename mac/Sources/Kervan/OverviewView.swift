import KervanKit
import SwiftUI

/// Shown when connected (or briefly reconnecting) and no session is selected.
struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let state = model.connection.state
        let host = model.activeAddress?.host ?? model.serverInput

        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                RouteView(state: state, host: host)
                    .frame(maxWidth: 460)

                VStack(alignment: .leading, spacing: 6) {
                    Text(state.isConnected ? "\(host) sunucusuna bağlısınız" : "\(host) sunucusuna yeniden bağlanılıyor…")
                        .font(.title2.weight(.semibold))
                    Text("Oturumlar sunucuda çalışır. Mac uyusa da kapansa da devam eder; tekrar bağlandığınızda kaldığı yerden görürsünüz.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 10) {
                    NewSessionButton()
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .fixedSize()

                    if model.store.sessions.isEmpty {
                        Text("Henüz oturum yok. İlk oturumu başlattığınızda soldaki listede görünecek.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Devam etmek için soldaki listeden bir oturum seçin.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider().frame(maxWidth: 460)

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    if case .connected(let server) = state {
                        GridRow {
                            Text("Sunucu sürümü").foregroundStyle(.secondary)
                            Text(server.version).monospacedDigit()
                        }
                    }
                    GridRow {
                        Text("Gecikme").foregroundStyle(.secondary)
                        Text(latencyText).monospacedDigit()
                    }
                    GridRow {
                        Text("Ajanlar").foregroundStyle(.secondary)
                        Text(model.store.agents.map(\.displayName).joined(separator: ", "))
                    }
                    GridRow {
                        Text("Adres").foregroundStyle(.secondary)
                        Text(model.activeAddress?.url.absoluteString ?? "")
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                    }
                }

                Button("Bağlantıyı kes") { model.disconnect() }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(40)
        }
    }

    private var latencyText: String {
        guard let latency = model.connection.latency else { return "ölçülüyor…" }
        let ms = Double(latency.components.attoseconds) / 1e15 + Double(latency.components.seconds) * 1000
        return ms < 1 ? "<1 ms" : "\(Int(ms.rounded())) ms"
    }
}
