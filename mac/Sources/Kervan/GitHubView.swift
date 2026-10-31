import AppKit
import KervanKit
import SwiftUI

/// Signs the server in to GitHub from the app, so pull requests open without a terminal: the server starts gh's
/// browser sign-in, this view shows the code and opens github.com/login/device, and the status updates when it's done.
struct GitHubConnection: View {
    @Environment(AppModel.self) private var model
    @State private var device: GitHubDeviceCode?
    @State private var failure: String?
    @State private var working = false
    @State private var copied = false

    var body: some View {
        let status = model.store.github
        VStack(alignment: .leading, spacing: 10) {
            if let status {
                if !status.available {
                    Text(L(
                        "GitHub's gh isn't installed on the server. Servers set up with Kervan 0.3.0 or later have it; on this one run: sudo apt-get install gh",
                        "Sunucuda GitHub'ın gh aracı kurulu değil. Kervan 0.3.0 ve sonrasıyla kurulan sunucularda var; bunda şunu çalıştırın: sudo apt-get install gh"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                } else if status.signedIn {
                    HStack(spacing: 8) {
                        StatusDot(color: .kervanOasis, size: 7)
                        Text(L("Connected as \(status.account ?? "?")", "\(status.account ?? "?") olarak bağlı"))
                        Spacer()
                        Button(L("Disconnect", "Bağlantıyı kes")) { Task { await disconnect() } }
                            .disabled(working)
                    }
                } else if let device, status.signingIn {
                    waiting(device)
                } else {
                    HStack(spacing: 8) {
                        StatusDot(color: .secondary.opacity(0.5), size: 7)
                        Text(L("Not connected", "Bağlı değil")).foregroundStyle(.secondary)
                        Spacer()
                        Button(L("Connect GitHub…", "GitHub'a bağlan…")) { Task { await connect() } }
                            .disabled(working || !model.connection.state.isConnected)
                    }
                }
            } else if model.connection.state.isConnected {
                ProgressView().controlSize(.small)
            }

            if let error = failure ?? model.store.githubError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Color.kervanCoral)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .task(id: model.connection.state.isConnected) {
            if model.connection.state.isConnected { failure = await model.store.loadGitHub() }
        }
        .onChange(of: model.store.github?.signedIn) { _, signedIn in
            if signedIn == true { device = nil }
        }
    }

    private func waiting(_ device: GitHubDeviceCode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Enter this code on GitHub, in the page that just opened:", "Az önce açılan GitHub sayfasına bu kodu girin:"))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Text(device.code)
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .tracking(2)
                    .textSelection(.enabled)
                    .accessibilityLabel(device.code.map(String.init).joined(separator: " "))
                Button(copied ? L("Copied", "Kopyalandı") : L("Copy", "Kopyala")) { copy(device.code) }
                    .buttonStyle(.borderless)
                Spacer()
                Button(L("Open GitHub", "GitHub'ı aç")) { NSWorkspace.shared.open(device.url) }
            }
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L("Waiting for you to approve it…", "Onaylamanız bekleniyor…")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("Cancel", "Vazgeç")) { Task { await disconnect() } }
                    .buttonStyle(.borderless)
            }
        }
        .padding(12)
        .softSurface(radius: Radius.chip)
    }

    private func connect() async {
        working = true
        defer { working = false }
        failure = nil
        switch await model.store.connectGitHub() {
        case .success(let code):
            device = code
            copy(code.code)
            NSWorkspace.shared.open(code.url)
            await model.store.loadGitHub()
        case .failure(let error):
            failure = error.message
        }
    }

    private func disconnect() async {
        working = true
        defer { working = false }
        device = nil
        failure = await model.store.disconnectGitHub()
    }

    private func copy(_ code: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true
    }
}
