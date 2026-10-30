import AppKit
import KervanKit
import SwiftUI

/// The first run, over the whole window. On the left the intro's night sky goes on as a route with one stop
/// per step, and the caravan waits at the stop you are on (it travels while something is happening). On the
/// right, one question at a time: hello, which way, then connect to a server or set one up, then ready.
struct OnboardingView: View {
    enum Stage: Hashable {
        case welcome, choose, connect, setupForm, permission, setupProgress, done

        /// Which stop on the route this stage belongs to.
        var stop: Int {
            switch self {
            case .welcome: 0
            case .choose: 1
            case .connect, .setupForm, .permission, .setupProgress: 2
            case .done: 3
            }
        }
    }

    enum Path: Hashable { case connect, setup }

    /// The local network question: not asked yet, waiting for the answer, refused, or the machine didn't answer.
    enum Permission: Hashable { case ask, checking, denied, unreachable }

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stage: Stage = .welcome
    @State private var path: Path = .connect
    @State private var host = ""
    @State private var user = "ubuntu"
    @State private var access: HubSetup.Access = .lan
    @State private var installer = HubInstaller()
    @State private var permission: Permission = .ask

    var body: some View {
        HStack(spacing: 0) {
            RouteRail(stops: stops, current: stage.stop, travelling: travelling, arrived: stage == .done)
                .frame(width: 250)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    content
                        .id(stage)
                        .transition(.arrive(reduce: reduceMotion))
                }
                .frame(maxWidth: 520, alignment: .leading)
                .padding(.horizontal, 56)
                .padding(.top, 72)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.kervanCanvas)
        }
        .ignoresSafeArea()
        .onChange(of: isConnected) { _, connected in
            if connected && (stage == .connect || stage == .setupProgress) { go(.done) }
        }
        .onDisappear { installer.stop() }
    }

    private var stops: [String] {
        ["Hoş geldiniz", "Yolunuzu seçin", path == .setup ? "Sunucuyu kurun" : "Sunucuya bağlanın", "Hazır"]
    }

    private var isConnected: Bool {
        if case .connected = model.connection.state { return true }
        return false
    }

    private var travelling: Bool {
        switch stage {
        case .connect: model.connection.state.isBusy
        case .permission: permission == .checking
        case .setupProgress: installer.isRunning || installer.waitingForTerminal
        default: false
        }
    }

    private func go(_ next: Stage) {
        withAnimation(Motion.pick(Motion.smooth, reduce: reduceMotion)) { stage = next }
    }

    private func finish(startSession: Bool) {
        withAnimation(Motion.pick(Motion.smooth, reduce: reduceMotion)) { model.showOnboarding = false }
        if startSession { model.newSession() }
    }

    private func install() {
        let host = host.trimmed
        installer.run(user: user.trimmed, host: host, access: access) { token in
            model.serverInput = host
            model.tokenInput = token
            model.connect()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch stage {
        case .welcome: welcome
        case .choose: choose
        case .connect: connect
        case .setupForm: setupForm
        case .permission: permissionStep
        case .setupProgress: setupProgress
        case .done: done
        }
    }

    // MARK: Stages

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 28) {
            Heading(
                title: "Ajanlarınız kendi sunucunuzda çalışsın",
                lead: "Kervan; Claude, Codex ve Gemini gibi ajanları sizin makinenizde çalıştırır, siz de hepsini bu Mac'ten yönetirsiniz."
            )
            VStack(alignment: .leading, spacing: 18) {
                Promise(symbol: "moon.stars", title: "Mac kapansa da iş sürer", text: "Ajanlar sunucuda çalışır; döndüğünüzde kaldıkları yerden görürsünüz.")
                Promise(symbol: "lock", title: "Her şey sizde kalır", text: "Kodunuz ve API anahtarlarınız kendi sunucunuzda durur, başka bir yere gitmez.")
                Promise(symbol: "clock", title: "Birkaç dakikada hazır", text: "Sunucunuz varsa bir dakika, yoksa birlikte kurmak 3–5 dakika.")
            }
            Actions {
                Spacer()
                Button("Başlayalım") { go(.choose) }
                    .buttonStyle(PrimaryStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var choose: some View {
        VStack(alignment: .leading, spacing: 28) {
            Heading(title: "Sunucunuz hazır mı?", lead: "Kervan'ın çalışacağı bir makine gerekiyor: ev sunucusu, bir sanal makine ya da buluttaki bir sunucu olabilir.")
            VStack(spacing: 12) {
                ChoiceTile(
                    symbol: "server.rack",
                    title: "Kervan kurulu bir sunucum var",
                    text: "Adresini ve erişim anahtarını girip bağlanırsınız.",
                    selected: path == .connect
                ) { path = .connect }
                ChoiceTile(
                    symbol: "shippingbox",
                    title: "Bir makineye birlikte kuralım",
                    text: "Ubuntu ya da Debian bir makineye Mac'inizden SSH ile kurulur. Parolanız uygulamaya girilmez.",
                    selected: path == .setup
                ) { path = .setup }
            }
            Actions {
                Button("Geri") { go(.welcome) }.buttonStyle(QuietStyle())
                Spacer()
                Button("Devam") { go(path == .setup ? .setupForm : .connect) }
                    .buttonStyle(PrimaryStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var connect: some View {
        @Bindable var model = model
        let state = model.connection.state
        return VStack(alignment: .leading, spacing: 28) {
            Heading(title: "Sunucunuza bağlanalım", lead: "Bu bilgiler bir kez sorulur. Erişim anahtarı Mac'inizin Keychain'inde saklanır.")
            VStack(alignment: .leading, spacing: 18) {
                Field(title: "Sunucu adresi", hint: "IP adresi, Tailscale adı ya da ağdaki adı. Port yazmazsanız 7420 kullanılır.") {
                    TextField("Sunucu adresi", text: $model.serverInput, prompt: Text("ör. 192.168.1.21"))
                        .textContentType(.URL)
                }
                Field(title: "Erişim anahtarı", hint: nil) {
                    SecureField("Erişim anahtarı", text: $model.tokenInput, prompt: Text("Sunucudaki KERVAN_TOKEN değeri"))
                }
                Guidance(text: "Anahtarı sunucuda şu komutla görebilirsiniz:", command: "sudo grep KERVAN_TOKEN /etc/kervan/env")
            }
            .padding(20)
            .softSurface(radius: Radius.panel)
            .disabled(state.isBusy)

            ConnectStatus(state: state, host: model.address?.host ?? "sunucu")

            Actions {
                Button("Geri") {
                    if state.isBusy { model.disconnect() }
                    go(.choose)
                }
                .buttonStyle(QuietStyle())
                Spacer()
                if state.isBusy {
                    Button("Vazgeç") { model.disconnect() }
                        .buttonStyle(QuietStyle())
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button("Bağlan") { model.connect() }
                        .buttonStyle(PrimaryStyle())
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canConnect)
                }
            }
        }
    }

    private var setupForm: some View {
        VStack(alignment: .leading, spacing: 28) {
            Heading(title: "Hangi makineye kuralım?", lead: "Ubuntu ya da Debian çalışan, Mac'inizin SSH ile girebildiği bir makine yeterli.")
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    Field(title: "Makinenin adresi", hint: nil) {
                        TextField("Makinenin adresi", text: $host, prompt: Text("ör. 192.168.1.30"))
                    }
                    Field(title: "Kullanıcı", hint: nil) {
                        TextField("Kullanıcı", text: $user)
                    }
                    .frame(width: 150)
                }
                Guidance(
                    text: "Mac'iniz bu makineye parolasız giremiyorsa önce Terminal'de bir kez şunu çalıştırın:",
                    command: "ssh-copy-id \(user.trimmed.isEmpty ? "ubuntu" : user.trimmed)@\(host.trimmed.isEmpty ? "ADRES" : host.trimmed)"
                )
            }
            .padding(20)
            .softSurface(radius: Radius.panel)

            VStack(alignment: .leading, spacing: 10) {
                Text("Nereden bağlanacaksınız?")
                    .font(.headline)
                HStack(alignment: .top, spacing: 12) {
                    ChoiceTile(symbol: "wifi", title: "Bu ağdan", text: "Port yalnızca bu yerel ağdaki cihazlara açılır.", selected: access == .lan, compact: true) { access = .lan }
                    ChoiceTile(symbol: "globe", title: "Her yerden", text: "Tailscale de kurulur; evden uzaktayken de bağlanırsınız.", selected: access == .both, compact: true) { access = .both }
                }
            }

            Actions {
                Button("Geri") { go(.choose) }.buttonStyle(QuietStyle())
                Spacer()
                Button("Kurulumu başlat") {
                    permission = .ask
                    go(.permission)
                }
                .buttonStyle(PrimaryStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(host.trimmed.isEmpty || user.trimmed.isEmpty)
            }
        }
    }

    /// macOS asks once whether Kervan may reach machines on this network; the ssh it starts can't without it.
    /// This step says why before the system asks, so the answer is an informed yes.
    private var permissionStep: some View {
        VStack(alignment: .leading, spacing: 28) {
            Heading(
                title: permission == .denied ? "Yerel ağ izni kapalı" : "Yerel ağa erişim izni",
                lead: permission == .denied
                    ? "macOS şu an Kervan'ın ağdaki makinelere ulaşmasına izin vermiyor. Ayarlarda bir kez açmanız yeterli."
                    : "Kervan'ın \(host.trimmed) makinesine bağlanabilmesi için macOS sizden bir kez izin isteyecek."
            )
            VStack(alignment: .leading, spacing: 18) {
                if permission == .denied {
                    Promise(symbol: "gearshape", title: "Sistem Ayarları › Gizlilik ve Güvenlik › Yerel Ağ", text: "Listede Kervan'ı bulun ve anahtarını açın. Sonra buraya dönüp yeniden kontrol edin.")
                } else {
                    Promise(symbol: "network", title: "Neden gerekiyor", text: "Kurulum, Mac'inizden bu makineye SSH ile bağlanır. Sunucunuzla konuşmak için de aynı izin kullanılır.")
                    Promise(symbol: "hand.raised", title: "Ne paylaşılır", text: "Hiçbir şey. İzin yalnızca Kervan'ın ağınızdaki cihazlara bağlanabilmesi içindir.")
                    Promise(symbol: "macwindow", title: "Ne göreceksiniz", text: "\"Kervan yerel ağınızdaki cihazları bulmak ve bunlara bağlanmak istiyor\" penceresinde İzin Ver'i seçin.")
                }
                if permission == .unreachable {
                    Label("\(host.trimmed) yanıt vermedi. Makinenin açık ve bu ağda olduğunu, adresin doğru olduğunu kontrol edin.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.kervanCoral)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
            .softSurface(radius: Radius.panel)

            Actions {
                Button("Geri") { go(.setupForm) }
                    .buttonStyle(QuietStyle())
                    .disabled(permission == .checking)
                Spacer()
                if permission == .denied {
                    Button("Ayarları aç") { NSWorkspace.shared.open(LocalNetwork.settingsURL) }
                        .buttonStyle(QuietStyle())
                }
                Button(permission == .checking ? "Yanıt bekleniyor…" : permission == .ask ? "İzin ver" : "Yeniden kontrol et") {
                    askPermission()
                }
                .buttonStyle(PrimaryStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(permission == .checking)
            }
        }
    }

    private func askPermission() {
        permission = .checking
        Task {
            switch await LocalNetwork.check(host: host.trimmed) {
            case true?:
                install()
                go(.setupProgress)
            case false?:
                withAnimation(Motion.pick(Motion.smooth, reduce: reduceMotion)) { permission = .denied }
            case nil:
                withAnimation(Motion.pick(Motion.smooth, reduce: reduceMotion)) { permission = .unreachable }
            }
        }
    }

    private var setupProgress: some View {
        let steps = HubSetupStep.allCases.filter { $0 != .tailscaleLogin || access == .both }
        let failed = installer.failure != nil
        return VStack(alignment: .leading, spacing: 28) {
            Heading(
                title: failed ? "Kurulum yarıda kaldı" : (installer.step == .ready ? "Sunucu hazır, bağlanılıyor" : "Sunucunuz kuruluyor"),
                lead: failed
                    ? "Sorunu giderdikten sonra yeniden deneyin; kurulum yarım kalan yerleri bozmadan baştan çalışır."
                    : "\(host.trimmed) üzerinde. Genelde 3–5 dakika sürer; bu sırada başka işinize bakabilirsiniz, bitince burada görünür."
            )
            VStack(alignment: .leading, spacing: 16) {
                StepList(
                    steps: steps.map { ($0.title, $0.detail) },
                    reached: steps.firstIndex(of: installer.step) ?? steps.count - 1,
                    running: installer.isRunning || installer.waitingForTerminal,
                    failed: failed,
                    startedAt: installer.startedAt
                )
                if let url = installer.tailscaleURL {
                    Button("Tailscale'e giriş yap") { NSWorkspace.shared.open(url) }
                        .buttonStyle(PrimaryStyle())
                }
                if installer.waitingForTerminal {
                    Guidance(
                        text: "Bu makinede sudo parola istiyor. Terminal'de şunu çalıştırın; parolanız orada sorulur, kurulum bitince bu ekran kendiliğinden bağlanır.",
                        command: HubSetup.terminalCommand(user: user.trimmed, host: host.trimmed, access: access)
                    )
                }
                if let failure = installer.failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.kervanCoral)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if installer.localNetworkBlocked {
                    Button("Ayarları aç") { NSWorkspace.shared.open(LocalNetwork.settingsURL) }
                        .buttonStyle(PrimaryStyle())
                }
                if !installer.output.isEmpty {
                    DisclosureGroup("Ayrıntılı çıktı") {
                        ScrollView {
                            Text(installer.output)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 140)
                        .defaultScrollAnchor(.bottom)
                    }
                    .font(.callout)
                }
            }
            .padding(20)
            .softSurface(radius: Radius.panel)

            Actions {
                if failed {
                    Button("Bilgileri değiştir") {
                        installer.reset()
                        go(.setupForm)
                    }
                    .buttonStyle(QuietStyle())
                    Spacer()
                    Button("Yeniden dene") { install() }
                        .buttonStyle(PrimaryStyle())
                        .keyboardShortcut(.defaultAction)
                } else {
                    Spacer()
                    Button("Kurulumu durdur") {
                        installer.reset()
                        go(.setupForm)
                    }
                    .buttonStyle(QuietStyle())
                }
            }
        }
    }

    private var done: some View {
        let agents = model.store.agents
        return VStack(alignment: .leading, spacing: 28) {
            Heading(
                title: "Hazırsınız",
                lead: "Kervan \(model.address?.host ?? "sunucunuz") üzerinde çalışıyor. Ajanlarınız orada çalışır; Mac'i kapatsanız da işleri sürer."
            )
            VStack(alignment: .leading, spacing: 12) {
                if agents.isEmpty {
                    Promise(
                        symbol: "person.badge.key",
                        title: "Henüz giriş yapmış bir ajan yok",
                        text: "Ayarlar › Ajanlar'dan bir ajanın API anahtarını ekleyince burada görünür."
                    )
                } else {
                    Text(agents.count == 1 ? "Sunucuda bir ajan hazır" : "Sunucuda \(agents.count) ajan hazır")
                        .font(.headline)
                    AgentChips(names: agents.map(\.name))
                }
            }
            Actions {
                Button("Kervan'a geç") { finish(startSession: false) }
                    .buttonStyle(QuietStyle())
                Spacer()
                if !agents.isEmpty {
                    Button("İlk oturumu başlat") { finish(startSession: true) }
                        .buttonStyle(PrimaryStyle())
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

// MARK: - The route

/// The left side: the intro's night sky, with a vertical route and one stop per step. Passed stops and the
/// road behind you are gold; the stop you are on glows; the last stop is the oasis.
private struct RouteRail: View {
    let stops: [String]
    let current: Int
    let travelling: Bool
    let arrived: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let gold = Color(light: 0xE8B65A, dark: 0xE8B65A)
    private static let oasis = Color(light: 0x5DB38C, dark: 0x5DB38C)
    private static let spacing: CGFloat = 84

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(light: 0x2F5D8A, dark: 0x2F5D8A), Color(light: 0x16243A, dark: 0x16243A)], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color.white.opacity(0.10), .clear], center: .init(x: 0.3, y: 0.05), startRadius: 0, endRadius: 320)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 30, height: 30)
                    Text("Kervan")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .padding(.bottom, 56)

                ZStack(alignment: .topLeading) {
                    road
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(stops.indices, id: \.self) { index in
                            stop(index)
                                .frame(height: Self.spacing, alignment: .top)
                        }
                    }
                }
                Spacer()
            }
            .padding(.leading, 32)
            .padding(.top, 64)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Adım \(current + 1) / \(stops.count): \(stops[min(current, stops.count - 1)])")
    }

    /// The line between stops, gold up to where you are, and the caravan travelling on the next leg.
    private var road: some View {
        let length = CGFloat(stops.count - 1) * Self.spacing
        return ZStack(alignment: .top) {
            Capsule().fill(Color.white.opacity(0.16)).frame(width: 3, height: length)
            Capsule().fill(Self.gold).frame(width: 3, height: CGFloat(current) * Self.spacing)
                .frame(height: length, alignment: .top)
                .animation(Motion.pick(Motion.gentle, reduce: reduceMotion), value: current)
            if travelling && current < stops.count - 1 && !reduceMotion {
                RailCaravan(top: CGFloat(current) * Self.spacing, leg: Self.spacing)
                    .frame(height: length, alignment: .top)
            }
        }
        .frame(width: 18, height: length, alignment: .top)
        .padding(.top, 9)
    }

    private func stop(_ index: Int) -> some View {
        let last = index == stops.count - 1
        let passed = index < current || (last && arrived)
        let here = index == current && !(last && arrived)
        let color = last ? Self.oasis : Self.gold
        return HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(color.opacity(here || (last && arrived) ? 0.28 : 0))
                    .frame(width: 30, height: 30)
                Circle()
                    .fill(passed || here ? color : Color(light: 0x24364F, dark: 0x24364F))
                    .overlay(Circle().strokeBorder(passed || here ? .clear : Color.white.opacity(0.28), lineWidth: 1.5))
                    .frame(width: here ? 16 : 13, height: here ? 16 : 13)
                    .shadow(color: color.opacity(here ? 0.8 : 0), radius: 8)
            }
            .frame(width: 18, height: 36)
            .animation(Motion.pick(Motion.gentle, reduce: reduceMotion), value: current)
            .animation(Motion.pick(Motion.gentle, reduce: reduceMotion), value: arrived)

            Text(stops[index])
                .font(.system(.body, design: .rounded).weight(here ? .semibold : .regular))
                .foregroundStyle(.white.opacity(here ? 1 : passed ? 0.75 : 0.45))
                .frame(height: 36)
        }
        .offset(y: -9)
    }
}

/// Three small lights walking down the leg from the current stop to the next, fading in and out at the ends.
private struct RailCaravan: View {
    let top: CGFloat
    let leg: CGFloat

    var body: some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            ZStack(alignment: .top) {
                ForEach(0..<3, id: \.self) { index in
                    light(phase: CGFloat((time / 2.4 + Double(index) * 0.18).truncatingRemainder(dividingBy: 1)))
                }
            }
        }
    }

    private func light(phase: CGFloat) -> some View {
        let y: CGFloat = top + 12 + phase * (leg - 24) - 3.5
        return Circle()
            .fill(Color(light: 0xF5C76A, dark: 0xF5C76A))
            .frame(width: 7, height: 7)
            .shadow(color: Color(light: 0xE8B65A, dark: 0xE8B65A).opacity(0.7), radius: 4)
            .opacity(Double(sin(phase * .pi)))
            .offset(y: y)
    }
}

// MARK: - Pieces

private struct Heading: View {
    let title: String
    let lead: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
            Text(lead)
                .font(.system(.title3, design: .rounded))
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct Promise: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.kervanLapis)
                .frame(width: 36, height: 36)
                .background(Color.kervanLapis.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A large selectable answer; the chosen one is outlined in lapis with a filled check.
private struct ChoiceTile: View {
    let symbol: String
    let title: String
    let text: String
    let selected: Bool
    var compact = false
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            HStack(alignment: .top, spacing: 14) {
                if !compact {
                    Image(systemName: symbol)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(selected ? Color.white : Color.kervanLapis)
                        .frame(width: 42, height: 42)
                        .background(
                            selected ? Color.kervanLapis : Color.kervanLapis.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: Radius.card - 4, style: .continuous)
                        )
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if compact { Image(systemName: symbol).foregroundStyle(Color.kervanLapis) }
                        Text(title).font(.headline)
                    }
                    Text(text)
                        .font(compact ? .callout : .body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(selected ? Color.kervanLapis : Color.secondary.opacity(0.5))
            }
            .padding(compact ? 14 : 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .softSurface(radius: Radius.panel, lift: selected)
            .overlay {
                RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
                    .strokeBorder(selected ? Color.kervanLapis : Color.primary.opacity(0.08), lineWidth: selected ? 1.5 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
            .animation(Motion.fast, value: selected)
        }
        .buttonStyle(SoftPressStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A labelled text field on a soft well, label above, optional hint below.
private struct Field<Input: View>: View {
    let title: String
    let hint: String?
    @ViewBuilder let input: Input

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.weight(.medium))
            input
                .textFieldStyle(.plain)
                .font(.body.monospaced())
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color.kervanWell, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
            if let hint {
                Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Back on the left, the way forward on the right.
private struct Actions<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 12) { content }
            .padding(.top, 4)
    }
}

private struct PrimaryStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .rounded).weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 11)
            .background(Color.kervanLapis.opacity(isEnabled ? 1 : 0.4), in: Capsule())
            .shadow(color: Color.kervanLapis.opacity(isEnabled ? 0.3 : 0), radius: 8, y: 3)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(Motion.fast, value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

private struct QuietStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color.primary.opacity(configuration.isPressed ? 0.08 : 0), in: Capsule())
            .contentShape(Capsule())
    }
}

/// Agent names as small soft chips that wrap.
private struct AgentChips: View {
    let names: [String]

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(names, id: \.self) { name in
                HStack(spacing: 6) {
                    StatusDot(color: .kervanOasis, size: 6)
                    Text(name).font(.callout)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .softSurface(radius: Radius.chip)
            }
        }
    }
}

private struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for (index, point) in rows.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (points: [CGPoint], width: CGFloat, height: CGFloat) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (points, widest, y + rowHeight)
    }
}

/// What the connection is doing, in one calm line.
struct ConnectStatus: View {
    let state: ConnectionState
    let host: String

    var body: some View {
        Group {
            switch state {
            case .disconnected, .connected:
                EmptyView()
            case .connecting(let attempt):
                Label(attempt > 1 ? "\(host) adresine yeniden bağlanılıyor (\(attempt). deneme)…" : "\(host) adresine bağlanılıyor…", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
            case .retrying(let at, _, _):
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let seconds = max(0, Int(at.timeIntervalSince(context.date).rounded(.up)))
                    Label("\(host) şu an yanıt vermiyor. Adresi ve sunucunun açık olduğunu kontrol edin; \(seconds) sn sonra yeniden denenecek.", systemImage: "clock")
                        .foregroundStyle(.secondary)
                }
            case .failed(let failure):
                Label(Self.text(for: failure), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.kervanCoral)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    static func text(for failure: ConnectionFailure) -> String {
        switch failure {
        case .unauthorized:
            "Sunucu bu anahtarı tanımadı. Sunucudaki değerle karşılaştırıp yeniden girin."
        case .unsupportedProtocol:
            "Sunucu ile uygulama farklı protokol sürümleri kullanıyor. İkisini de güncelleyin."
        case .unreachable(let reason):
            "Sunucuya ulaşılamadı: \(reason)"
        }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
