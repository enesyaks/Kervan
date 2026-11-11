import KervanKit
import SwiftUI

/// Settings › Alerts: the server tells your phone when an agent needs you or is done, through ntfy or a webhook,
/// even while this Mac is asleep. Alerts carry the session's name and what happened, never code or prompts.
struct AlertsSection: View {
    @Environment(AppModel.self) private var model
    @State private var enabled = false
    @State private var events = AlertSettings.Events(approval: true, finished: true, error: true)
    @State private var server = "https://ntfy.sh"
    @State private var topic = ""
    @State private var token = ""
    @State private var webhook = ""
    @State private var removeWebhook = false
    @State private var includeNames = false
    @State private var loaded = false
    @State private var working = false
    @State private var note: (text: String, good: Bool)?

    var body: some View {
        let settings = model.store.alerts
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: $enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Send alerts to my phone", "Telefonuma bildirim gönder")).font(.headline)
                    Text(L(
                        "The server sends them itself, so they arrive even when this Mac is asleep. They say which session and what happened, never code or files.",
                        "Bildirimleri sunucu kendisi gönderir; bu Mac uyurken bile gelir. Hangi oturum ve ne olduğunu söyler, asla kod ya da dosya içermez."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)

            SettingsCard(
                title: "ntfy",
                footer: L(
                    "Install the ntfy app on your phone, tap +, and subscribe to this topic. On ntfy.sh anyone who knows the topic can read it, so keep it hard to guess, or use your own ntfy server with an access token.",
                    "Telefonunuza ntfy uygulamasını kurun, +'ya dokunup bu konuya abone olun. ntfy.sh'de konuyu bilen herkes okuyabilir; tahmin edilmesi zor tutun ya da erişim token'ıyla kendi ntfy sunucunuzu kullanın."
                )
            ) {
                // Labelled rows: outside a Form, a text field shows no label of its own.
                LabeledContent(L("Server", "Sunucu")) {
                    TextField("", text: $server).labelsHidden()
                }
                LabeledContent(L("Topic", "Konu")) {
                    HStack {
                        TextField("", text: $topic, prompt: Text("kervan-…")).labelsHidden().font(.body.monospaced())
                        Button(L("New topic", "Yeni konu")) { topic = Self.newTopic() }
                    }
                }
                LabeledContent(L("Access token", "Erişim token'ı")) {
                    SecureField(
                        "",
                        text: $token,
                        prompt: Text(settings?.ntfy?.tokenSet == true ? L("Set; leave empty to keep it", "Ayarlı; korumak için boş bırakın") : L("Optional", "İsteğe bağlı"))
                    )
                    .labelsHidden()
                }
            }

            SettingsCard(
                title: "Webhook",
                footer: L(
                    "Kervan POSTs JSON here for each alert: event, sessionId, title, message, url, at.",
                    "Kervan her bildirim için buraya JSON gönderir (POST): event, sessionId, title, message, url, at."
                )
            ) {
                if settings?.webhookSet == true && !removeWebhook {
                    HStack {
                        Label(L("A webhook is set", "Bir webhook ayarlı"), systemImage: "checkmark.circle").foregroundStyle(Color.kervanOasis)
                        Spacer()
                        Button(L("Remove", "Kaldır")) { removeWebhook = true }
                    }
                }
                LabeledContent(L("Address", "Adres")) {
                    TextField("", text: $webhook, prompt: Text(settings?.webhookSet == true ? L("Replace with a new address", "Yeni adresle değiştir") : "https://…"))
                        .labelsHidden()
                }
            }

            SettingsCard(title: L("Tell me when", "Ne zaman haber verilsin")) {
                Toggle(L("An agent needs my approval", "Bir ajan onayımı beklediğinde"), isOn: $events.approval)
                Toggle(L("An agent finishes its turn", "Bir ajan turunu bitirdiğinde"), isOn: $events.finished)
                Toggle(L("A session stops with an error", "Bir oturum hatayla durduğunda"), isOn: $events.error)
                Divider()
                Toggle(isOn: $includeNames) {
                    Text(L("Show session names", "Oturum adlarını göster"))
                    Text(L(
                        "A session's name is the first line of its first message until you rename it, so it's off unless you turn it on. Off, alerts only say which agent and what happened.",
                        "Oturumun adı, siz değiştirene kadar ilk mesajının ilk satırıdır; bu yüzden siz açmadıkça kapalıdır. Kapalıyken bildirimler yalnızca hangi ajan ve ne olduğunu söyler."
                    ))
                }
            }

            if let note {
                Label(note.text, systemImage: note.good ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(note.good ? Color.kervanOasis : Color.kervanCoral)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(L("Send a test alert", "Deneme bildirimi gönder")) { Task { await test() } }
                    .disabled(working || (topic.isEmpty && webhook.isEmpty && settings?.webhookSet != true))
                Spacer()
                Button(L("Save", "Kaydet")) { Task { await save() } }
                    .buttonStyle(.kervanPrimary)
                    .tint(.kervanLapis)
                    .disabled(working || !model.connection.state.isConnected)
            }
            Text(L(
                "Tapping an alert opens the session in Kervan's web version, when Web access is on.",
                "Bir bildirime dokunmak, Web erişimi açıksa oturumu Kervan'ın web sürümünde açar."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .task(id: model.connection.state.isConnected) {
            guard model.connection.state.isConnected else { return }
            await model.store.loadAlerts()
            fill(from: model.store.alerts)
        }
    }

    private func fill(from settings: AlertSettings?) {
        guard let settings, !loaded else { return }
        loaded = true
        enabled = settings.enabled
        events = settings.events
        includeNames = settings.includeNames ?? false
        server = settings.ntfy?.server ?? "https://ntfy.sh"
        topic = settings.ntfy?.topic ?? ""
    }

    private var input: AlertInput {
        // Alerts are read away from home too, so the link prefers the hub's Tailscale address.
        let open = WebLinks.preferred(addresses: model.store.hubAddresses, current: model.activeAddress?.url) ?? ""
        return AlertInput(
            enabled: enabled,
            events: events,
            ntfyServer: server,
            ntfyTopic: topic.trimmingCharacters(in: .whitespaces),
            ntfyToken: token.isEmpty ? nil : token,
            webhook: removeWebhook && webhook.isEmpty ? "" : (webhook.isEmpty ? nil : webhook),
            openUrl: open,
            includeNames: includeNames
        )
    }

    @discardableResult
    private func save() async -> Bool {
        working = true
        defer { working = false }
        if let failure = await model.store.saveAlerts(input) {
            note = (failure, false)
            return false
        }
        token = ""
        webhook = ""
        removeWebhook = false
        note = (L("Saved.", "Kaydedildi."), true)
        return true
    }

    private func test() async {
        guard await save() else { return }
        working = true
        defer { working = false }
        if let failure = await model.store.testAlerts() {
            note = (failure, false)
        } else {
            note = (L("Sent. It should be on your phone now.", "Gönderildi. Telefonunuza şimdi gelmiş olmalı."), true)
        }
    }

    /// Hard to guess, since on ntfy.sh a topic is all it takes to read it.
    private static func newTopic() -> String {
        let letters = Array("abcdefghijkmnpqrstuvwxyz23456789")
        return "kervan-" + String((0..<16).map { _ in letters.randomElement()! })
    }
}
