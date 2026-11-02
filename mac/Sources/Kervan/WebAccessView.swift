import AppKit
import KervanKit
import SwiftUI

/// Settings › Web access: whether the server offers its web client, and which browsers may use it.
/// A browser is paired with a one-time code and gets a key of its own; the server's key never leaves the app.
struct WebAccessSection: View {
    @Environment(AppModel.self) private var model
    @State private var failure: String?
    @State private var pairing: WebPairing?
    @State private var removing: WebDevice?
    @State private var working = false

    var body: some View {
        let web = model.store.webAccess
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: Binding(get: { web?.enabled ?? false }, set: { on in Task { await setEnabled(on) } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Allow web access", "Web erişimine izin ver")).font(.headline)
                    Text(L(
                        "Use Kervan from a phone or another computer's browser. Paired browsers can follow sessions, send messages, answer approvals and start sessions; settings, agents, nodes and files stay with this app.",
                        "Kervan'ı telefondan ya da başka bir bilgisayarın tarayıcısından kullanın. Eşleştirilen tarayıcılar oturumları izleyebilir, mesaj gönderebilir, onay verebilir ve oturum başlatabilir; ayarlar, ajanlar, node'lar ve dosyalar bu uygulamada kalır."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .disabled(web == nil || working || !model.connection.state.isConnected)

            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Color.kervanCoral)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let web, web.enabled {
                WebAddressList(links: webLinks, hasTailscale: WebLinks.hasTailscale(model.store.hubAddresses))

                HStack {
                    Text(L("Paired browsers", "Eşleştirilen tarayıcılar")).font(.headline)
                    Spacer()
                    Button(L("Add a device…", "Cihaz ekle…")) { Task { await pair() } }
                        .disabled(working)
                }
                if web.devices.isEmpty {
                    Text(L("None yet. Choose Add a device, open the address above in the browser and enter the code.", "Henüz yok. Cihaz ekle'yi seçin, yukarıdaki adresi tarayıcıda açın ve kodu girin."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(web.devices) { device in
                    HStack(spacing: 10) {
                        Image(systemName: Self.symbol(for: device.name)).foregroundStyle(.secondary).frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                            Text(Self.detail(device)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L("Remove", "Kaldır"), role: .destructive) { removing = device }.buttonStyle(.borderless)
                    }
                    .padding(12)
                    .softSurface(radius: Radius.chip)
                }

                Text(L(
                    "The connection isn't encrypted by Kervan itself, so use it on your home network or over Tailscale, never open to the internet. A lost phone: remove it here and its access ends at once.",
                    "Bağlantıyı Kervan'ın kendisi şifrelemez; ev ağınızda ya da Tailscale üzerinden kullanın, asla internete açmayın. Telefon kaybolursa buradan kaldırın, erişimi anında biter."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: model.connection.state.isConnected) {
            if model.connection.state.isConnected { failure = await model.store.loadWebAccess() }
        }
        .sheet(item: $pairing, onDismiss: { Task { await model.store.loadWebAccess() } }) { pairing in
            let before = Set(model.store.webAccess?.devices.map(\.id) ?? [])
            PairingSheet(pairing: pairing, address: webAddress) {
                // The browser pairs over HTTP, so the app looks for it rather than being told.
                await model.store.loadWebAccess()
                return model.store.webAccess?.devices.first { !before.contains($0.id) }?.name
            }
        }
        .confirmationDialog(
            L("Remove \(removing?.name ?? "")?", "\(removing?.name ?? "") kaldırılsın mı?"),
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
        ) {
            Button(L("Remove", "Kaldır"), role: .destructive) {
                if let device = removing { Task { failure = await model.store.revokeWebDevice(device.id) } }
            }
        } message: {
            Text(L("Its key stops working and an open page is disconnected. Pairing it again needs a new code.", "Anahtarı geçersiz olur ve açık sayfanın bağlantısı kesilir. Yeniden eşleştirmek için yeni bir kod gerekir."))
        }
    }

    /// Where a browser finds the web client: the hub's Tailscale and LAN addresses, or the one this app uses.
    private var webLinks: [WebLink] {
        WebLinks.all(addresses: model.store.hubAddresses, current: model.activeAddress?.url)
    }

    /// The address the pairing sheet shows: one that also works away from home, when there is one.
    private var webAddress: String? {
        WebLinks.preferred(addresses: model.store.hubAddresses, current: model.activeAddress?.url)
    }

    private func setEnabled(_ on: Bool) async {
        working = true
        defer { working = false }
        failure = await model.store.setWebAccess(on)
    }

    private func pair() async {
        working = true
        defer { working = false }
        switch await model.store.pairWebDevice() {
        case .success(let code): pairing = code; failure = nil
        case .failure(let error): failure = error.message
        }
    }

    private static func symbol(for name: String) -> String {
        if name.hasPrefix("iPhone") || name.hasPrefix("Android") { return "iphone" }
        if name.hasPrefix("iPad") { return "ipad" }
        return "laptopcomputer"
    }

    private static func detail(_ device: WebDevice) -> String {
        let paired = SessionGroups.parse(device.createdAt).map { $0.formatted(date: .abbreviated, time: .omitted) } ?? device.createdAt
        guard let seen = device.lastSeenAt.flatMap(SessionGroups.parse) else {
            return L("Paired \(paired)", "Eşleşme \(paired)")
        }
        let relative = seen.formatted(.relative(presentation: .named))
        return L("Paired \(paired) · last used \(relative)", "Eşleşme \(paired) · son kullanım \(relative)")
    }
}

extension WebPairing: Identifiable {
    public var id: String { code }
}

/// The addresses a browser can open, grouped by how far they reach: Tailscale anywhere, the LAN only at home.
private struct WebAddressList: View {
    let links: [WebLink]
    let hasTailscale: Bool
    @Environment(AppModel.self) private var model
    @State private var settingUpTailscale = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let tailscale = links.filter { $0.reach == .tailscale }
            let lan = links.filter { $0.reach == .lan }
            let current = links.filter { $0.reach == .current }
            if !tailscale.isEmpty {
                group(
                    symbol: "globe",
                    tint: Color.kervanOasis,
                    title: L("Tailscale: works anywhere you're signed in to Tailscale", "Tailscale: Tailscale'e giriş yaptığınız her yerde çalışır"),
                    links: tailscale
                )
            }
            if !lan.isEmpty {
                group(symbol: "house", tint: Color.kervanLapis, title: L("Home network only", "Yalnızca yerel ağda"), links: lan)
            }
            if !current.isEmpty {
                group(symbol: "link", tint: Color.kervanLapis, title: L("The address this app uses", "Bu uygulamanın kullandığı adres"), links: current)
            }
            if !hasTailscale {
                awayFromHome
            }
        }
    }

    private func group(symbol: String, tint: Color, title: String, links: [WebLink]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            ForEach(links) { link in
                HStack(spacing: 8) {
                    Text(link.url).font(.callout.monospaced()).textSelection(.enabled)
                    if link.isName {
                        Text(L("name", "ad")).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L("Copy", "Kopyala")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(link.url, forType: .string)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .softSurface(radius: Radius.chip)
    }

    /// No Tailscale on the server: how to use the web client away from home, without opening it to the internet.
    private var awayFromHome: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L("Away from home", "Evden uzaktayken"), systemImage: "airplane")
                .font(.caption.weight(.semibold))
            Text(L(
                "These addresses work only on the same network as the server. To use Kervan from anywhere, set up Tailscale on the server and on the phone, signed in with the same account; a Tailscale address then shows up here.",
                "Bu adresler yalnızca sunucuyla aynı ağdayken çalışır. Her yerden kullanmak için sunucuya ve telefona Tailscale kurup ikisinde aynı hesapla giriş yapın; ardından burada bir Tailscale adresi görünür."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(L("Set up Tailscale on the server…", "Sunucuya Tailscale kur…")) { settingUpTailscale = true }
                    .disabled(!model.connection.state.isConnected)
                Spacer()
            }
            .padding(.vertical, 2)
            DisclosureGroup(L("Or run it on the server yourself", "Ya da sunucuda kendiniz çalıştırın")) {
                HStack(spacing: 8) {
                    Text(NodeSetup.tailscaleCommand).font(.caption.monospaced()).textSelection(.enabled).lineLimit(2)
                    Spacer()
                    Button(L("Copy", "Kopyala")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(NodeSetup.tailscaleCommand, forType: .string)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.top, 4)
            }
            .font(.caption)
            Text(L(
                "On the phone, get the Tailscale app from the App Store or Google Play. Don't forward the port on your router instead: Kervan's web access isn't meant to face the internet.",
                "Telefona Tailscale uygulamasını App Store ya da Google Play'den yükleyin. Bunun yerine modemden port yönlendirmeyin: Kervan'ın web erişimi internete açık olacak şekilde tasarlanmadı."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .softSurface(radius: Radius.chip)
        .sheet(isPresented: $settingUpTailscale) {
            ServerUpdateSheet(access: .both).environment(model)
        }
    }
}

/// The one-time code, large enough to read across a desk, with how long it has left.
private struct PairingSheet: View {
    let pairing: WebPairing
    let address: String?
    /// The name of a browser that paired since the sheet opened, if one has.
    let newDevice: () async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var paired: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Pair a browser", "Tarayıcı eşleştir")).font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                if let address {
                    Text(L("1. On the phone or computer, open", "1. Telefonda ya da bilgisayarda şunu açın:"))
                    Text(address).font(.body.monospaced()).textSelection(.enabled)
                }
                Text(L("2. Enter this code:", "2. Bu kodu girin:"))
            }
            .foregroundStyle(.secondary)

            Text(pairing.code)
                .font(.system(size: 40, weight: .semibold, design: .monospaced))
                .tracking(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .softSurface(radius: Radius.card)
                .accessibilityLabel(pairing.code.map(String.init).joined(separator: " "))

            if let paired {
                Label(L("\(paired) is paired.", "\(paired) eşleştirildi."), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.kervanOasis)
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = max(0, Int(pairing.expiresAt.timeIntervalSince(context.date)))
                    Text(left > 0
                        ? L("Works once, for \(left / 60):\(String(format: "%02d", left % 60)) more.", "Bir kez ve \(left / 60):\(String(format: "%02d", left % 60)) daha geçerli.")
                        : L("This code has expired; make a new one.", "Bu kodun süresi doldu; yenisini oluşturun."))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(left > 0 ? Color.secondary : Color.kervanCoral)
                }
            }

            HStack {
                Spacer()
                Button(L("Done", "Tamam")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
        .fontDesign(.rounded)
        .task {
            while paired == nil, pairing.expiresAt > .now, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if let name = await newDevice() {
                    paired = name
                    try? await Task.sleep(for: .seconds(1.5))
                    dismiss()
                }
            }
        }
    }
}
