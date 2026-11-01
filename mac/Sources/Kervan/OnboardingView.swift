import AppKit
import KervanKit
import SwiftUI

/// The first run, over the whole window. On the left the intro's night sky goes on as a route with one stop
/// per step, and the caravan waits at the stop you are on (it travels while something is happening). On the
/// right, one question at a time: hello, which way, then connect to a server or set one up, then ready.
struct OnboardingView: View {
    enum Stage: Hashable {
        case welcome, choose, connect, setupForm, permission, setupProgress, agents, done

        /// Which stop on the route this stage belongs to.
        var stop: Int {
            switch self {
            case .welcome: 0
            case .choose: 1
            case .connect, .setupForm, .permission, .setupProgress: 2
            case .agents: 3
            case .done: 4
            }
        }
    }

    enum Path: Hashable { case connect, setup }

    /// The local network question: not asked yet, waiting for the answer, refused, or the machine didn't answer.
    enum Permission: Hashable { case ask, checking, denied, unreachable }

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// KERVAN_ONBOARDING=agents opens on the agents step, for checking it against a running server. Any step
    /// can be named the same way (welcome, choose, connect, setup, permission, progress, agents, done).
    @State private var stage: Stage = Self.startStage
    @State private var path: Path = .connect
    @State private var host = ""
    @State private var user = "ubuntu"
    @State private var access: HubSetup.Access = .lan
    @State private var installer = HubInstaller()
    @State private var permission: Permission = .ask
    /// Keys typed on the agents step, by agent id; they go to the server and are cleared once saved.
    @State private var keys: [String: String] = [:]
    @State private var changing: Set<String> = []
    @State private var keyErrors: [String: String] = [:]
    @State private var savingKeys = false
    /// The first field of a form step gets the cursor, so you can type right away and press Return.
    @FocusState private var focusedField: FieldID?
    /// VoiceOver moves to the new step's heading instead of staying on the button that was pressed.
    @AccessibilityFocusState private var headingFocused: Bool

    enum FieldID: Hashable { case server, token, host, user }

    private static var startStage: Stage {
        switch ProcessInfo.processInfo.environment["KERVAN_ONBOARDING"] {
        case "choose": .choose
        case "connect": .connect
        case "setup": .setupForm
        case "permission": .permission
        case "progress": .setupProgress
        case "agents": .agents
        case "done": .done
        default: .welcome
        }
    }

    init(stage: Stage? = nil) {
        if let stage {
            _stage = State(initialValue: stage)
        }
    }

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
                .padding(.top, 60)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.kervanCanvas)
            .overlay(alignment: .topTrailing) {
                // It can be opened again from Help, so there has to be a way back. Not while a setup is
                // running: leaving stops the installer.
                if stage != .setupProgress {
                    Button(L("Close", "Kapat")) {
                        withAnimation(Motion.pick(Motion.smooth, reduce: reduceMotion)) { model.showOnboarding = false }
                    }
                    .buttonStyle(QuietPillStyle())
                    .padding(.top, 18)
                    .padding(.trailing, 20)
                }
            }
        }
        .ignoresSafeArea()
        .onChange(of: isConnected, initial: true) { _, connected in
            guard connected else { return }
            // The agents step needs the server's list, which can only be asked for once connected.
            if stage == .connect || stage == .setupProgress || stage == .agents {
                Task { await model.store.loadAgentConfigs() }
                if stage != .agents { go(.agents) }
            }
        }
        .onChange(of: stage, initial: true) { _, stage in
            headingFocused = false
            Task { @MainActor in
                // After the new step has arrived, so the field and heading exist.
                try? await Task.sleep(for: .milliseconds(120))
                headingFocused = true
                switch stage {
                case .connect: focusedField = model.serverInput.trimmed.isEmpty ? .server : .token
                case .setupForm: focusedField = .host
                default: focusedField = nil
                }
            }
        }
        .onAppear {
            SnapshotRunner.checkAndRun(model: model)
        }
        .onDisappear { installer.stop() }
    }

    private var stops: [String] {
        [L("Welcome", "Hoş geldiniz"), L("Choose your path", "Yolunuzu seçin"), path == .setup ? L("Set up the server", "Sunucuyu kurun") : L("Connect to the server", "Sunucuya bağlanın"), L("Agents", "Ajanlar"), L("Ready", "Hazır")]
    }

    private var isConnected: Bool {
        if case .connected = model.connection.state { return true }
        return false
    }

    private var travelling: Bool {
        switch stage {
        case .connect: model.connection.state.isBusy
        case .permission: permission == .checking
        case .agents: savingKeys
        case .setupProgress: installer.isRunning || installer.waitingForTerminal
        default: false
        }
    }

    private func go(_ next: Stage) {
        withAnimation(Motion.pick(Motion.smooth, reduce: reduceMotion)) { stage = next }
    }

    /// Hands over to the app: the first-use tour comes next (once), and the first session opens after it,
    /// so the new-session sheet and the tour never stack.
    private func finish(startSession: Bool) {
        let agent = startSession ? readyAgents.first?.id : nil
        let model = model
        withAnimation(Motion.pick(Motion.smooth, reduce: reduceMotion)) { model.showOnboarding = false }
        WelcomeTour.showIfNew(after: reduceMotion ? 0.2 : 0.45) {
            if let agent { model.newSession(agent: agent) }
        }
    }

    /// Heading of every step: one VoiceOver element, marked as a header, and where VoiceOver lands on arrival.
    private func heading(_ title: String, _ lead: String) -> some View {
        Heading(title: title, lead: lead)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityFocused($headingFocused)
    }

    /// Agents that can work now: signed in, or ones the server can't check (added by hand).
    private var readyAgents: [AgentConfig] {
        model.store.agentConfigs.filter { $0.available && $0.signedIn != false }
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
        case .agents: agentsStep
        case .done: done
        }
    }

    // MARK: Stages

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 28) {
            heading(
                L("Run your agents on your own server", "Ajanlarınız kendi sunucunuzda çalışsın"),
                L("Kervan runs agents like Claude, Codex and Gemini on your own machine, and you manage them all from this Mac.", "Kervan; Claude, Codex ve Gemini gibi ajanları sizin makinenizde çalıştırır, siz de hepsini bu Mac'ten yönetirsiniz.")
            )
            VStack(alignment: .leading, spacing: 18) {
                Promise(symbol: "moon.stars", title: L("Work goes on when the Mac sleeps", "Mac uyusa da iş sürer"), text: L("Agents run on the server, so when you come back you see how far they got.", "Ajanlar sunucuda çalışır; döndüğünüzde ne kadar ilerlediklerini görürsünüz."))
                Promise(symbol: "lock", title: L("Everything stays with you", "Her şey sizde kalır"), text: L("Your code and API keys stay on your own server and go nowhere else.", "Kodunuz ve API anahtarlarınız kendi sunucunuzda durur, başka bir yere gitmez."))
                Promise(symbol: "clock", title: L("Ready in minutes", "Birkaç dakikada hazır"), text: L("A minute if you have a server; setting one up together takes 3–5 minutes.", "Sunucunuz varsa bir dakika, yoksa birlikte kurmak 3–5 dakika."))
            }
            Actions {
                Spacer()
                Button(L("Get started", "Başlayalım")) { go(.choose) }
                    .buttonStyle(PrimaryPillStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var choose: some View {
        VStack(alignment: .leading, spacing: 28) {
            heading(L("Do you have a server?", "Sunucunuz hazır mı?"), L("Kervan needs a machine to run on: a home server, a virtual machine or a server in the cloud.", "Kervan'ın çalışacağı bir makine gerekiyor: ev sunucusu, bir sanal makine ya da buluttaki bir sunucu olabilir."))
            VStack(spacing: 12) {
                ChoiceTile(
                    symbol: "server.rack",
                    title: L("I have a Kervan server", "Kervan kurulu bir sunucum var"),
                    text: L("Enter its address and access key to connect.", "Adresini ve erişim anahtarını girip bağlanırsınız."),
                    selected: path == .connect
                ) { path = .connect }
                ChoiceTile(
                    symbol: "shippingbox",
                    title: L("Set one up together", "Bir makineye birlikte kuralım"),
                    text: L("Installed on an Ubuntu or Debian machine from your Mac over SSH. Your password never goes into the app.", "Ubuntu ya da Debian bir makineye Mac'inizden SSH ile kurulur. Parolanız uygulamaya girilmez."),
                    selected: path == .setup
                ) { path = .setup }
            }
            Actions {
                Button(L("Back", "Geri")) { go(.welcome) }
                    .buttonStyle(QuietPillStyle())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(L("Continue", "Devam")) { go(path == .setup ? .setupForm : .connect) }
                    .buttonStyle(PrimaryPillStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var connect: some View {
        @Bindable var model = model
        let state = model.connection.state
        return VStack(alignment: .leading, spacing: 28) {
            heading(L("Connect to your server", "Sunucunuza bağlanalım"), L("You only need to enter these once. The access key stays on this Mac, where only you can read it.", "Bunları yalnızca bir kez girmeniz yeterli. Erişim anahtarı bu Mac'te, yalnızca sizin okuyabileceğiniz şekilde saklanır."))
            VStack(alignment: .leading, spacing: 18) {
                Field(title: L("Server address", "Sunucu adresi"), hint: L("IP address, Tailscale name or network name. Port 7420 is used if you leave it out.", "IP adresi, Tailscale adı ya da ağdaki adı. Port yazmazsanız 7420 kullanılır.")) {
                    TextField(L("Server address", "Sunucu adresi"), text: $model.serverInput, prompt: Text(L("e.g. 192.168.1.21", "ör. 192.168.1.21")))
                        .textContentType(.URL)
                        .focused($focusedField, equals: .server)
                }
                Field(title: L("Access key", "Erişim anahtarı"), hint: nil) {
                    SecureField(L("Access key", "Erişim anahtarı"), text: $model.tokenInput, prompt: Text(L("The KERVAN_TOKEN value on the server", "Sunucudaki KERVAN_TOKEN değeri")))
                        .focused($focusedField, equals: .token)
                }
                Guidance(text: L("To see the key on the server, run:", "Anahtarı sunucuda şu komutla görebilirsiniz:"), command: "sudo grep KERVAN_TOKEN /etc/kervan/env")
            }
            .padding(20)
            .softSurface(radius: Radius.panel)
            .disabled(state.isBusy)

            ConnectStatus(state: state, host: model.address?.host ?? L("the server", "sunucu"))

            Actions {
                // While connecting, Escape cancels the attempt (below); otherwise it goes back.
                if state.isBusy {
                    Button(L("Back", "Geri")) {
                        model.disconnect()
                        go(.choose)
                    }
                    .buttonStyle(QuietPillStyle())
                } else {
                    Button(L("Back", "Geri")) { go(.choose) }
                        .buttonStyle(QuietPillStyle())
                        .keyboardShortcut(.cancelAction)
                }
                Spacer()
                if state.isBusy {
                    Button(L("Cancel", "Vazgeç")) { model.disconnect() }
                        .buttonStyle(QuietPillStyle())
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button(L("Connect", "Bağlan")) { model.connect() }
                        .buttonStyle(PrimaryPillStyle())
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canConnect)
                }
            }
        }
    }

    private var setupForm: some View {
        VStack(alignment: .leading, spacing: 28) {
            heading(L("Which machine should we set up?", "Hangi makineye kuralım?"), L("Any Ubuntu or Debian machine your Mac can reach over SSH will do.", "Ubuntu ya da Debian çalışan, Mac'inizin SSH ile girebildiği bir makine yeterli."))
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    Field(title: L("Machine address", "Makinenin adresi"), hint: nil) {
                        TextField(L("Machine address", "Makinenin adresi"), text: $host, prompt: Text(L("e.g. 192.168.1.30", "ör. 192.168.1.30")))
                            .focused($focusedField, equals: .host)
                    }
                    Field(title: L("User", "Kullanıcı"), hint: nil) {
                        TextField(L("User", "Kullanıcı"), text: $user)
                            .focused($focusedField, equals: .user)
                    }
                    .frame(width: 150)
                }
                Guidance(
                    text: L("If your Mac can't log in to this machine without a password, run this once in Terminal first:", "Mac'iniz bu makineye parolasız giremiyorsa önce Terminal'de bir kez şunu çalıştırın:"),
                    command: L("ssh-copy-id \(user.trimmed.isEmpty ? "ubuntu" : user.trimmed)@\(host.trimmed.isEmpty ? "ADDRESS" : host.trimmed)", "ssh-copy-id \(user.trimmed.isEmpty ? "ubuntu" : user.trimmed)@\(host.trimmed.isEmpty ? "ADRES" : host.trimmed)")
                )
            }
            .padding(20)
            .softSurface(radius: Radius.panel)

            VStack(alignment: .leading, spacing: 10) {
                Text(L("Where will you connect from?", "Nereden bağlanacaksınız?"))
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                HStack(alignment: .top, spacing: 12) {
                    ChoiceTile(symbol: "wifi", title: L("This network", "Bu ağdan"), text: L("The port is open only to devices on this local network.", "Port yalnızca bu yerel ağdaki cihazlara açılır."), selected: access == .lan, compact: true) { access = .lan }
                    ChoiceTile(symbol: "globe", title: L("Anywhere", "Her yerden"), text: L("Tailscale is installed too, so you can connect when you're away.", "Tailscale de kurulur; evden uzaktayken de bağlanırsınız."), selected: access == .both, compact: true) { access = .both }
                }
            }

            Actions {
                Button(L("Back", "Geri")) { go(.choose) }
                    .buttonStyle(QuietPillStyle())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(L("Start setup", "Kurulumu başlat")) {
                    permission = .ask
                    go(.permission)
                }
                .buttonStyle(PrimaryPillStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(host.trimmed.isEmpty || user.trimmed.isEmpty)
            }
        }
    }

    /// macOS asks once whether Kervan may reach machines on this network; the ssh it starts can't without it.
    /// This step says why before the system asks, so the answer is an informed yes.
    private var permissionStep: some View {
        VStack(alignment: .leading, spacing: 28) {
            heading(
                permission == .denied ? L("Local network access is off", "Yerel ağ izni kapalı") : L("Local network access", "Yerel ağa erişim izni"),
                permission == .denied
                    ? L("macOS isn't letting Kervan reach machines on your network. Turning it on once in Settings is enough.", "macOS şu an Kervan'ın ağdaki makinelere ulaşmasına izin vermiyor. Ayarlarda bir kez açmanız yeterli.")
                    : L("macOS will ask you once to let Kervan connect to \(host.trimmed.isEmpty ? L("the machine", "makineye") : host.trimmed).", "Kervan'ın \(host.trimmed.isEmpty ? L("makineye", "makineye") : host.trimmed) bağlanabilmesi için macOS sizden bir kez izin isteyecek.")
            )
            VStack(alignment: .leading, spacing: 18) {
                if permission == .denied {
                    Promise(symbol: "gearshape", title: L("System Settings › Privacy & Security › Local Network", "Sistem Ayarları › Gizlilik ve Güvenlik › Yerel Ağ"), text: L("Find Kervan in the list and turn it on. Then come back here and check again.", "Listede Kervan'ı bulun ve anahtarını açın. Sonra buraya dönüp yeniden kontrol edin."))
                } else {
                    Promise(symbol: "network", title: L("Why it's needed", "Neden gerekiyor"), text: L("Setup connects from your Mac to this machine over SSH. The same permission is used to talk to your server.", "Kurulum, Mac'inizden bu makineye SSH ile bağlanır. Sunucunuzla konuşmak için de aynı izin kullanılır."))
                    Promise(symbol: "hand.raised", title: L("What's shared", "Ne paylaşılır"), text: L("Nothing. The permission only lets Kervan connect to devices on your network.", "Hiçbir şey. İzin yalnızca Kervan'ın ağınızdaki cihazlara bağlanabilmesi içindir."))
                    Promise(symbol: "macwindow", title: L("What you'll see", "Ne göreceksiniz"), text: L("Choose Allow when macOS says \"Kervan would like to find and connect to devices on your local network\".", "\"Kervan yerel ağınızdaki cihazları bulmak ve bunlara bağlanmak istiyor\" penceresinde İzin Ver'i seçin."))
                }
                if permission == .unreachable {
                    Label(unreachableText, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.kervanCoral)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
            .softSurface(radius: Radius.panel)

            Actions {
                Button(L("Back", "Geri")) { go(.setupForm) }
                    .buttonStyle(QuietPillStyle())
                    .keyboardShortcut(.cancelAction)
                    .disabled(permission == .checking)
                Spacer()
                if permission == .denied {
                    Button(L("Open Settings", "Ayarları aç")) { NSWorkspace.shared.open(LocalNetwork.settingsURL) }
                        .buttonStyle(QuietPillStyle())
                }
                Button(permission == .checking ? L("Waiting for an answer…", "Yanıt bekleniyor…") : permission == .ask ? L("Allow", "İzin ver") : L("Check again", "Yeniden kontrol et")) {
                    askPermission()
                }
                .buttonStyle(PrimaryPillStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(permission == .checking)
            }
        }
    }

    private var unreachableText: String {
        let name = host.trimmed.isEmpty ? L("The machine", "Makine") : host.trimmed
        return L("\(name) didn't answer. Check that the machine is on, on this network, and that the address is right.", "\(name) yanıt vermedi. Makinenin açık ve bu ağda olduğunu, adresin doğru olduğunu kontrol edin.")
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
                AccessibilityNotification.Announcement(L("Local network access is off", "Yerel ağ izni kapalı")).post()
            case nil:
                withAnimation(Motion.pick(Motion.smooth, reduce: reduceMotion)) { permission = .unreachable }
                AccessibilityNotification.Announcement(unreachableText).post()
            }
        }
    }

    private var setupProgress: some View {
        let steps = HubSetupStep.allCases.filter { $0 != .tailscaleLogin || access == .both }
        let failed = installer.failure != nil
        let target = host.trimmed.isEmpty ? L("your server", "sunucunuz") : host.trimmed
        return VStack(alignment: .leading, spacing: 28) {
            heading(
                failed ? L("Setup stopped", "Kurulum yarıda kaldı") : (installer.step == .ready ? L("Server ready, connecting", "Sunucu hazır, bağlanılıyor") : L("Setting up your server", "Sunucunuz kuruluyor")),
                failed
                    ? L("Fix the problem and try again; setup runs from the start without breaking what's already done.", "Sorunu giderdikten sonra yeniden deneyin; kurulum yarım kalan yerleri bozmadan baştan çalışır.")
                    : L("Setting up \(target) usually takes 3–5 minutes. You can do something else meanwhile; this screen moves on by itself when it's done.", "\(target) kurulumu genelde 3–5 dakika sürer. Bu sırada başka işinize bakabilirsiniz; bitince bu ekran kendiliğinden ilerler.")
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
                    Button(L("Sign in to Tailscale", "Tailscale'e giriş yap")) { NSWorkspace.shared.open(url) }
                        .buttonStyle(PrimaryPillStyle())
                }
                if installer.waitingForTerminal {
                    Guidance(
                        text: L("sudo needs a password on this machine. Run this in Terminal; it asks for your password there, and this screen connects by itself when setup is done.", "Bu makinede sudo parola istiyor. Terminal'de şunu çalıştırın; parolanız orada sorulur, kurulum bitince bu ekran kendiliğinden bağlanır."),
                        command: HubSetup.terminalCommand(user: user.trimmed, host: host.trimmed, access: access)
                    )
                }
                if let failure = installer.failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.kervanCoral)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if installer.localNetworkBlocked {
                    Button(L("Open Settings", "Ayarları aç")) { NSWorkspace.shared.open(LocalNetwork.settingsURL) }
                        .buttonStyle(PrimaryPillStyle())
                }
                if !installer.output.isEmpty {
                    DisclosureGroup(L("Detailed output", "Ayrıntılı çıktı")) {
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
            .onChange(of: installer.failure) { _, failure in
                if let failure { AccessibilityNotification.Announcement(failure).post() }
            }

            Actions {
                if failed {
                    Button(L("Change details", "Bilgileri değiştir")) {
                        installer.reset()
                        go(.setupForm)
                    }
                    .buttonStyle(QuietPillStyle())
                    .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(L("Try again", "Yeniden dene")) { install() }
                        .buttonStyle(PrimaryPillStyle())
                        .keyboardShortcut(.defaultAction)
                } else {
                    Spacer()
                    Button(L("Stop setup", "Kurulumu durdur")) {
                        installer.reset()
                        go(.setupForm)
                    }
                    .buttonStyle(QuietPillStyle())
                }
            }
        }
    }

    /// The adapters came with the server; what each still needs is a key. They are saved on the server
    /// as the agent's own environment, one at a time, and the server tries each agent before keeping it.
    private var agentsStep: some View {
        let configs = model.store.agentConfigs
        let offered = AgentSignIn.all.filter { sign in configs.contains { $0.id == sign.id } }
        let typed = offered.contains { !(keys[$0.id] ?? "").trimmed.isEmpty }
        return VStack(alignment: .leading, spacing: 28) {
            heading(
                L("Let's get your agents ready", "Ajanlarınızı hazırlayalım"),
                L("Claude Code, Codex and Gemini are installed on your server. Give a key to the ones you want to use; keys are stored only on your server.", "Claude Code, Codex ve Gemini sunucunuza kuruldu. Kullanmak istediklerinize anahtarını verin; anahtarlar yalnızca sunucunuzda saklanır.")
            )
            if configs.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(L("Looking at the agents on the server…", "Sunucudaki ajanlara bakılıyor…")).foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 12) {
                    ForEach(offered) { sign in
                        let config = configs.first { $0.id == sign.id }
                        AgentKeyCard(
                            sign: sign,
                            ready: config?.signedIn == true,
                            changing: changing.contains(sign.id),
                            key: Binding(get: { keys[sign.id] ?? "" }, set: { keys[sign.id] = $0 }),
                            error: keyErrors[sign.id],
                            change: { changing.insert(sign.id) }
                        )
                        .disabled(savingKeys)
                    }
                }
                Text(L("You can add or change them later in Settings › Agents.", "Sonra da ekleyebilir ya da değiştirebilirsiniz: Ayarlar › Ajanlar."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Actions {
                Button(L("Skip for now", "Şimdilik geç")) { go(.done) }
                    .buttonStyle(QuietPillStyle())
                    .keyboardShortcut(.cancelAction)
                    .disabled(savingKeys)
                Spacer()
                if typed || savingKeys {
                    Button(savingKeys ? L("Trying the agents…", "Ajanlar deneniyor…") : L("Save and continue", "Kaydet ve devam")) { saveKeys(offered) }
                        .buttonStyle(PrimaryPillStyle())
                        .keyboardShortcut(.defaultAction)
                        .disabled(savingKeys)
                } else if !readyAgents.isEmpty {
                    Button(L("Continue", "Devam")) { go(.done) }
                        .buttonStyle(PrimaryPillStyle())
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func saveKeys(_ offered: [AgentSignIn]) {
        savingKeys = true
        keyErrors = [:]
        Task {
            for sign in offered {
                guard let input = sign.input(key: keys[sign.id] ?? "") else { continue }
                await model.store.saveAgent(input)
                if let error = model.store.agentSaveError {
                    keyErrors[sign.id] = error
                } else {
                    keys[sign.id] = nil
                    changing.remove(sign.id)
                }
            }
            savingKeys = false
            if keyErrors.isEmpty { go(.done) }
        }
    }

    private var done: some View {
        let agents = readyAgents
        return VStack(alignment: .leading, spacing: 28) {
            heading(
                L("You're all set", "Hazırsınız"),
                L("Kervan is running on \(model.address?.host ?? "your server"). Your agents work there, and keep working when you close the Mac.", "Kervan \(model.address?.host ?? "sunucunuz") üzerinde çalışıyor. Ajanlarınız orada çalışır; Mac'i kapatsanız da işleri sürer.")
            )
            VStack(alignment: .leading, spacing: 12) {
                if agents.isEmpty {
                    Promise(
                        symbol: "person.badge.key",
                        title: L("No agent has a key yet", "Henüz anahtarı olan bir ajan yok"),
                        text: L("Give an agent its key in Settings › Agents to start your first session.", "Ayarlar › Ajanlar'dan bir ajana anahtarını verdiğinizde ilk oturumu başlatabilirsiniz.")
                    )
                } else {
                    Text(agents.count == 1 ? L("One agent is ready on the server", "Sunucuda bir ajan hazır") : L("\(agents.count) agents are ready on the server", "Sunucuda \(agents.count) ajan hazır"))
                        .font(.headline)
                    AgentChips(names: agents.map(\.name))
                }
            }
            Actions {
                Button(L("Go to Kervan", "Kervan'a geç")) { finish(startSession: false) }
                    .buttonStyle(QuietPillStyle())
                    .keyboardShortcut(agents.isEmpty ? .defaultAction : .cancelAction)
                Spacer()
                if !agents.isEmpty {
                    Button(L("Start the first session", "İlk oturumu başlat")) { finish(startSession: true) }
                        .buttonStyle(PrimaryPillStyle())
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

/// One builtin agent on the agents step: what it is, whether it is ready, and a field for its key.
private struct AgentKeyCard: View {
    let sign: AgentSignIn
    let ready: Bool
    let changing: Bool
    @Binding var key: String
    let error: String?
    let change: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(sign.name).font(.headline)
                    Text(sign.blurb).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if ready {
                    HStack(spacing: 6) {
                        StatusDot(color: .kervanOasis, size: 6)
                        Text(L("Ready", "Hazır")).font(.callout.weight(.medium))
                    }
                    .foregroundStyle(Color.kervanOasis)
                }
            }
            if ready && !changing {
                Button(L("Change key", "Anahtarı değiştir"), action: change)
                    .buttonStyle(.link)
                    .font(.callout)
            } else {
                HStack(spacing: 10) {
                    SecureField(sign.keyName, text: $key, prompt: Text(sign.placeholder))
                        .textFieldStyle(.plain)
                        .font(.body.monospaced())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(Color.kervanWell, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
                    Link(L("Get a key", "Anahtar al"), destination: sign.keyURL)
                        .font(.callout)
                }
                if let alternative = sign.alternative {
                    Text(alternative).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.kervanCoral)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .softSurface(radius: Radius.panel)
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
        .accessibilityLabel(L("Step \(current + 1) of \(stops.count): \(stops[min(current, stops.count - 1)])", "Adım \(current + 1) / \(stops.count): \(stops[min(current, stops.count - 1)])"))
    }

    /// The line between stops, gold up to where you are, and the caravan travelling on the next leg.
    private var road: some View {
        let length = CGFloat(stops.count - 1) * Self.spacing
        return ZStack(alignment: .top) {
            Capsule().fill(Color.white.opacity(0.16)).frame(width: 3, height: length)
            Capsule().fill(Self.gold).frame(width: 3, height: CGFloat(current) * Self.spacing)
                .frame(height: length, alignment: .top)
                .animation(Motion.pick(Motion.gentle, reduce: reduceMotion), value: current)
            if travelling && current < stops.count - 1 {
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
/// When Reduce Motion is enabled, they sit calmly midway along the leg without motion.
private struct RailCaravan: View {
    let top: CGFloat
    let leg: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            ZStack(alignment: .top) {
                ForEach(0..<3, id: \.self) { index in
                    if reduceMotion {
                        let y: CGFloat = top + 12 + (0.32 + CGFloat(index) * 0.18) * (leg - 24) - 3.5
                        Circle()
                            .fill(Color(light: 0xF5C76A, dark: 0xF5C76A))
                            .frame(width: 7, height: 7)
                            .shadow(color: Color(light: 0xE8B65A, dark: 0xE8B65A).opacity(0.7), radius: 4)
                            .opacity(0.8)
                            .offset(y: y)
                    } else {
                        light(phase: CGFloat((time / 2.4 + Double(index) * 0.18).truncatingRemainder(dividingBy: 1)))
                    }
                }
            }
        }
        .accessibilityHidden(true)
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

struct PrimaryPillStyle: ButtonStyle {
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

typealias PrimaryStyle = PrimaryPillStyle

struct QuietPillStyle: ButtonStyle {
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

typealias QuietStyle = QuietPillStyle

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
                Label(attempt > 1 ? L("Reconnecting to \(host) (attempt \(attempt))…", "\(host) adresine yeniden bağlanılıyor (\(attempt). deneme)…") : L("Connecting to \(host)…", "\(host) adresine bağlanılıyor…"), systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
            case .retrying(let at, _, _):
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let seconds = max(0, Int(at.timeIntervalSince(context.date).rounded(.up)))
                    Label(L("\(host) isn't answering. Check the address and that the server is on; trying again in \(seconds) s.", "\(host) şu an yanıt vermiyor. Adresi ve sunucunun açık olduğunu kontrol edin; \(seconds) sn sonra yeniden denenecek."), systemImage: "clock")
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
            L("The server didn't accept this key. Compare it with the value on the server and enter it again.", "Sunucu bu anahtarı tanımadı. Sunucudaki değerle karşılaştırıp yeniden girin.")
        case .unsupportedProtocol:
            L("The server and the app speak different protocol versions. Update both.", "Sunucu ile uygulama farklı protokol sürümleri kullanıyor. İkisini de güncelleyin.")
        case .unreachable(let reason):
            L("Couldn't reach the server: \(reason)", "Sunucuya ulaşılamadı: \(reason)")
        }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
