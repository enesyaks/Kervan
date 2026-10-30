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
                    Text(L("Connect to your server", "Sunucunuza bağlanalım"))
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                    Text(L("The saved server can't be reached right now, or details are missing. Check the address and key, then connect again.", "Kayıtlı sunucuya şu an ulaşılamıyor ya da bilgiler eksik. Adresi ve anahtarı kontrol edip yeniden bağlanın."))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Form {
                    LabeledContent(L("Server", "Sunucu")) {
                        VStack(alignment: .leading, spacing: 4) {
                            TextField(L("Server", "Sunucu"), text: $model.serverInput, prompt: Text(L("e.g. 192.168.1.21 or kervan", "ör. 192.168.1.21 ya da kervan")))
                                .labelsHidden()
                                .font(.body.monospaced())
                                .textContentType(.URL)
                            Text(L("Tailscale name or IP address. Port 7420 is used if you leave it out.", "Tailscale adı ya da IP adresi. Port yazılmazsa 7420 kullanılır."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent(L("Access key", "Erişim anahtarı")) {
                        VStack(alignment: .leading, spacing: 4) {
                            SecureField(L("Access key", "Erişim anahtarı"), text: $model.tokenInput)
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
                    ConnectStatus(state: state, host: model.address?.host ?? L("the server", "sunucu"))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        if state.isBusy {
                            Button(L("Cancel", "Vazgeç")) { model.disconnect() }
                                .keyboardShortcut(.cancelAction)
                        } else {
                            Button(L("Set up a new server…", "Yeni sunucu kur…")) {
                                withAnimation(Motion.smooth) { model.showOnboarding = true }
                            }
                            .buttonStyle(.link)
                            Spacer()
                            Button(L("Connect", "Bağlan")) { model.connect() }
                                .buttonStyle(.borderedProminent)
                                .tint(.kervanLapis)
                                .controlSize(.large)
                                .keyboardShortcut(.defaultAction)
                                .disabled(!model.canConnect)
                        }
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
            Text(L("To see it on the server:", "Sunucuda görmek için:"))
            Text(command)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Button(copied ? L("Copied", "Kopyalandı") : L("Copy", "Kopyala")) {
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
