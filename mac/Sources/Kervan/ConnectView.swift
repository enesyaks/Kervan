import AppKit
import KervanKit
import SwiftUI

struct ConnectView: View {
    @Environment(AppModel.self) private var model

    private static let tokenCommand = "sudo grep KERVAN_TOKEN /etc/kervan/env"

    var body: some View {
        @Bindable var model = model
        let state = model.connection.state

        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                RouteView(state: state, host: model.address?.host ?? "")
                    .frame(maxWidth: 460)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Sunucuya bağlanın")
                        .font(.title2.weight(.semibold))
                    Text("Ajanlar kendi sunucunuzda çalışır. Kervan ona Tailscale üzerinden bağlanır; Mac kapansa da işler sunucuda sürer.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Form {
                    LabeledContent("Sunucu") {
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Sunucu", text: $model.serverInput, prompt: Text("kervan"))
                                .labelsHidden()
                                .font(.body.monospaced())
                                .textContentType(.URL)
                            Text("Tailscale adı ya da IP adresi. Port yazılmazsa 7420 kullanılır.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Erişim anahtarı") {
                        VStack(alignment: .leading, spacing: 4) {
                            SecureField("Erişim anahtarı", text: $model.tokenInput)
                                .labelsHidden()
                                .font(.body.monospaced())
                            TokenHint(command: Self.tokenCommand)
                        }
                    }
                }
                .formStyle(.columns)
                .padding(18)
                .softSurface()
                .disabled(state.isBusy)

                VStack(alignment: .leading, spacing: 12) {
                    StatusMessage(state: state, host: model.address?.host ?? "sunucu")
                        .fixedSize(horizontal: false, vertical: true)
                    if state.isBusy {
                        Button("Vazgeç") { model.disconnect() }
                            .keyboardShortcut(.cancelAction)
                    } else {
                        Button("Bağlan") { model.connect() }
                            .buttonStyle(.borderedProminent)
                            .tint(.kervanLapis)
                            .controlSize(.large)
                            .keyboardShortcut(.defaultAction)
                            .disabled(!model.canConnect)
                    }
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.vertical, 48)
            .frame(maxWidth: .infinity)
        }
        .background(Color.kervanCanvas)
    }
}

private struct TokenHint: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 6) {
            Text("Sunucuda görmek için:")
            Text(command)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Button(copied ? "Kopyalandı" : "Kopyala") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
            }
            .buttonStyle(.link)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct StatusMessage: View {
    let state: ConnectionState
    let host: String

    var body: some View {
        switch state {
        case .disconnected, .connected:
            EmptyView()
        case .connecting(let attempt):
            Text(attempt > 1 ? "\(host) adresine yeniden bağlanılıyor (\(attempt). deneme)…" : "\(host) adresine bağlanılıyor…")
                .foregroundStyle(.secondary)
        case .retrying(let at, _, _):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = max(0, Int(at.timeIntervalSince(context.date).rounded(.up)))
                Text("\(host) adresine ulaşılamadı. Tailscale'in açık olduğunu kontrol edin. \(seconds) sn sonra yeniden denenecek.")
                    .foregroundStyle(.secondary)
            }
        case .failed(let failure):
            Label(Self.text(for: failure), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    private static func text(for failure: ConnectionFailure) -> String {
        switch failure {
        case .unauthorized:
            "Sunucu bu anahtarı kabul etmedi. Sunucudaki değerle karşılaştırıp yeniden girin."
        case .unsupportedProtocol:
            "Sunucu ile uygulama farklı protokol sürümleri kullanıyor. İkisini de güncelleyin."
        case .unreachable(let reason):
            "Sunucuya ulaşılamadı: \(reason)"
        }
    }
}
