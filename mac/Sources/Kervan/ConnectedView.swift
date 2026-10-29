import KervanKit
import SwiftUI

struct ConnectedView: View {
    let server: PeerInfo
    @Environment(AppModel.self) private var model

    var body: some View {
        let host = model.activeAddress?.host ?? server.name

        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                RouteView(state: model.connection.state, host: host)
                    .frame(maxWidth: 460)

                VStack(alignment: .leading, spacing: 6) {
                    Text("\(host) sunucusuna bağlısınız")
                        .font(.title2.weight(.semibold))
                    Text("Mac uykudan uyanınca ya da ağ değişince bağlantı kendiliğinden yeniden kurulur.")
                        .foregroundStyle(.secondary)
                }

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("Sunucu sürümü").foregroundStyle(.secondary)
                        Text(server.version).monospacedDigit()
                    }
                    GridRow {
                        Text("Gecikme").foregroundStyle(.secondary)
                        Text(latencyText).monospacedDigit()
                    }
                    GridRow {
                        Text("Adres").foregroundStyle(.secondary)
                        Text(model.activeAddress?.url.absoluteString ?? "")
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                    }
                }

                Divider().frame(maxWidth: 460)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Henüz oturum yok")
                        .font(.headline)
                    Text("Ajan oturumu başlatma bir sonraki sürümde ekleniyor. Oturumlar ve takımlar soldaki listede görünecek.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
