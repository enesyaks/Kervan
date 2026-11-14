import Charts
import KervanKit
import SwiftUI

/// A page's frame: a title, a line under it, then its content, like the overview.
private struct Page<Content: View, Actions: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var actions: Actions
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title).font(.system(size: 32, weight: .bold, design: .rounded))
                        Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    actions
                }
                content
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 36)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity)
        }
        .background(Color.kervanCanvas)
    }
}

// MARK: Projects

/// One project: its folder, its instructions and its sessions.
struct ProjectView: View {
    let projectID: String
    @Environment(AppModel.self) private var model
    @State private var editing = false
    @State private var confirmDelete = false

    var body: some View {
        if let project = model.store.project(projectID) {
            let sessions = model.store.sessions.filter { $0.projectId == projectID && $0.parentId == nil }
            Page(title: project.name, subtitle: project.path) {
                HStack {
                    Button(L("Edit…", "Düzenle…")) { editing = true }
                        .buttonStyle(.kervanQuiet)
                    Button {
                        model.newSession(project: projectID)
                    } label: {
                        Label(L("New session here", "Bu projede oturum"), systemImage: "square.and.pencil")
                    }
                    .buttonStyle(.kervanPrimary)
                    .tint(.kervanLapis)
                    .disabled(!model.canCreateSession)
                }
            } content: {
                ProjectPMSection(project: project)
                if project.pm != nil || !(project.team ?? []).isEmpty {
                    ProjectTeamSection(project: project)
                }
                BoardSection(projectID: projectID)
                ProjectBranchesSection(projectID: projectID)
                ProjectMapSection(project: project)
                SettingsCard(title: L("Instructions", "Talimatlar")) {
                    Text(project.instructions.isEmpty
                        ? L("No instructions. Agents still read CLAUDE.md or AGENTS.md in the folder themselves.", "Talimat yok. Ajanlar klasördeki CLAUDE.md ya da AGENTS.md dosyalarını yine kendileri okur.")
                        : project.instructions)
                        .foregroundStyle(project.instructions.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Sessions", "Oturumlar")).font(.headline)
                    if sessions.isEmpty {
                        Text(L("No sessions in this project yet. Start one above, or drag a board card to Working.", "Bu projede henüz oturum yok. Yukarıdan başlatın ya da panodaki bir kartı Çalışıyor'a sürükleyin."))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // Whoever is waiting for you comes first, then the newest.
                    ForEach(sessions.sorted { ($0.status == .waiting ? 0 : 1, model.store.lastActivity($1.id)) < ($1.status == .waiting ? 0 : 1, model.store.lastActivity($0.id)) }) { session in
                        HomeRow(session: session, emphasis: session.status == .waiting ? .asks : .none)
                    }
                }
                Button(L("Remove project…", "Projeyi kaldır…"), role: .destructive) { confirmDelete = true }
                    .buttonStyle(.link)
                    .foregroundStyle(Color.kervanCoral)
            }
            .sheet(isPresented: $editing) { ProjectSheet(project: project) }
            .confirmationDialog(L("Remove \(project.name)?", "\(project.name) kaldırılsın mı?"), isPresented: $confirmDelete) {
                Button(L("Remove", "Kaldır"), role: .destructive) {
                    Task {
                        await model.store.deleteProject(projectID)
                        model.selectedSessionID = nil
                    }
                }
            } message: {
                Text(L("The folder and its sessions stay on the server; only the project is removed from the list.", "Klasör ve içindeki oturumlar sunucuda kalır; yalnızca proje listeden çıkar."))
            }
        } else {
            Page(title: L("Project not found", "Proje bulunamadı"), subtitle: L("It may have been removed from the server.", "Bu proje sunucudan kaldırılmış olabilir.")) { EmptyView() } content: { EmptyView() }
        }
    }
}

/// The project's PM: the agent that looks at every card first, plans it, hands it to the right agent and follows it up.
private struct ProjectPMSection: View {
    let project: ProjectInfo
    @Environment(AppModel.self) private var model
    @State private var error: String?
    @State private var working = false
    /// The main agent that becomes the PM when Kervan sets the team up for a project with none.
    @State private var mainAgent = ""

    /// Roles whose agent can hand out work: a terminal agent can't.
    private var candidates: [Role] {
        model.store.roles.filter { role in model.store.agents.first { $0.id == role.agent }.map { !$0.terminal } ?? false }
    }

    private var role: Role? { project.pm.flatMap { pm in model.store.roles.first { $0.id == pm.roleId } } }

    var body: some View {
        SettingsCard(
            title: L("PM", "PM"),
            footer: L(
                "The PM looks at every new card first: it plans it with its skills, hands it to the right agent and follows it until it's done. The PM is a role, so its agent, instructions, skills and budget are set in Settings › Roles.",
                "PM her yeni karta önce bakar: skill'leriyle planlar, doğru ajana verir ve bitene kadar takip eder. PM bir roldür; ajanı, talimatı, skill'leri ve bütçesi Ayarlar › Roller'den ayarlanır."
            )
        ) {
            if let warning = project.pmWarning(roles: model.store.roles) {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.kervanSaffron)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let setup = project.setupCard(in: model.store.boards[project.id] ?? []) {
                setupStatus(setup)
            } else if role == nil {
                setupOffer
            }
            if let failure = model.store.onboardingErrors[project.id] {
                Label(failure, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Color.kervanCoral)
            }
            if role == nil {
                Text(L("Or make one of your roles the PM:", "Ya da rollerinizden birini PM yapın:"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Picker(L("PM", "PM"), selection: Binding(get: { role?.id }, set: { choose($0) })) {
                    Text(L("None", "Yok")).tag(String?.none)
                    ForEach(candidates) { role in
                        Text("\(role.name) · \(model.store.agentName(role.agent))").tag(Optional(role.id))
                    }
                }
                .disabled(working)
            }
            if let role, let pm = project.pm {
                let own = pm.skills ?? []
                Text(role.skills.isEmpty && own.isEmpty
                    ? L("No skills: the PM plans from the project's instructions, its map and the repository's own documents, and suggests skills for you to accept in Settings › Skills when the same kind of work keeps coming.", "Skill yok: PM projenin talimatları, haritası ve deponun kendi belgeleriyle planlar; aynı tür iş tekrar ettiğinde Ayarlar › Skill'ler'de kabul etmeniz için skill önerir.")
                    : L("Skills: \((role.skills + own.filter { !role.skills.contains($0) }).joined(separator: ", "))", "Skill'ler: \((role.skills + own.filter { !role.skills.contains($0) }).joined(separator: ", "))"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help(own.isEmpty ? "" : L("Picked by the PM for this project: \(own.joined(separator: ", "))", "PM'in bu proje için seçtikleri: \(own.joined(separator: ", "))"))
                Toggle(isOn: Binding(get: { pm.autoPickup }, set: { on in update { $0.autoPickup = on } })) {
                    Text(L("Pick up new cards by itself", "Yeni kartları kendiliğinden alsın"))
                    Text(L("A new card starts its PM at once, a couple at a time; the rest wait in To do. Off: a card starts when you move it to Working.", "Yeni kart PM'ini hemen başlatır, aynı anda birkaç tane; diğerleri Yapılacak'ta bekler. Kapalıyken kart, Çalışıyor'a taşıyınca başlar."))
                }
                .disabled(working)
                Toggle(isOn: Binding(get: { pm.startOwnCases }, set: { on in update { $0.startOwnCases = on } })) {
                    Text(L("Start the cards the PM opens by itself", "PM'in kendi açtığı kartlar da kendiliğinden başlasın"))
                    Text(L("The PM opens cards for improvements, security problems and fixes it finds. Off: they wait in To do until you start them.", "PM bulduğu geliştirmeler, güvenlik sorunları ve hatalar için kart açar. Kapalıyken bu kartlar siz başlatana kadar Yapılacak'ta bekler."))
                }
                .disabled(working)
                Button(L("Ask the PM to review the project", "PM projeyi gözden geçirsin")) {
                    Task {
                        working = true
                        defer { working = false }
                        error = await model.store.saveCard(CardInput(projectId: project.id, title: ProjectPM.reviewTitle, prompt: ProjectPM.reviewPrompt, agent: role.agent))
                    }
                }
                .buttonStyle(.kervanQuiet)
                .disabled(working || !model.connection.state.isConnected)
                .help(L("Adds a card for the PM: it looks the project over and opens a card for each thing worth doing.", "PM için bir kart ekler: PM projeyi gözden geçirir ve yapılmaya değer her şey için bir kart açar."))
                if project.setupCard(in: model.store.boards[project.id] ?? []) == nil {
                    Button((project.team ?? []).isEmpty ? L("Set the team up", "Ekibi kur") : L("Set the team up again", "Ekibi yeniden kur")) {
                        onboard(agent: nil)
                    }
                    .buttonStyle(.kervanQuiet)
                    .disabled(working || !model.connection.state.isConnected)
                    .help(L("The PM reads the project and the skill library, defines the roles the project needs and builds the team with the skills that fit each.", "PM projeyi ve skill kütüphanesini okur, projenin ihtiyaç duyduğu rolleri tanımlar ve her birine uyan skill'lerle ekibi kurar."))
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Color.kervanCoral)
            }
        }
    }

    /// For a project with no PM: one main agent, and Kervan does the rest.
    @ViewBuilder
    private var setupOffer: some View {
        let agents = ProjectMapSection.agents(model.store)
        VStack(alignment: .leading, spacing: 8) {
            Text(L(
                "Let Kervan set the team up: the main agent becomes the PM, reads the project and the skill library, defines the roles the project needs and builds the team, giving each the skills that fit it.",
                "Ekibi Kervan kursun: ana ajan PM olur, projeyi ve skill kütüphanesini okur, projenin ihtiyaç duyduğu rolleri tanımlar ve her birine uyan skill'leri vererek ekibi kurar."
            ))
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Picker(L("Main agent", "Ana ajan"), selection: $mainAgent) {
                    ForEach(agents) { Text($0.name).tag($0.id) }
                }
                .fixedSize()
                Button(L("Set the team up", "Ekibi kur")) { onboard(agent: mainAgent.isEmpty ? nil : mainAgent) }
                    .buttonStyle(.kervanPrimary)
                    .tint(.kervanLapis)
                    .disabled(working || agents.isEmpty || !model.connection.state.isConnected)
            }
        }
        .onAppear {
            if mainAgent.isEmpty || !agents.contains(where: { $0.id == mainAgent }) {
                mainAgent = (agents.first { $0.id == model.defaultAgent?.id } ?? agents.first)?.id ?? ""
            }
        }
    }

    /// How the team setup goes: starting, at work, asking, or done and waiting to be looked at.
    @ViewBuilder
    private func setupStatus(_ card: CardInfo) -> some View {
        let session = card.sessionId.flatMap { id in model.store.sessions.first { $0.id == id } }
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let failure = card.error {
                Label(L("The team setup didn't start: \(failure)", "Ekip kurulumu başlamadı: \(failure)"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Color.kervanCoral)
                Spacer()
                Button(L("Try again", "Yeniden dene")) { onboard(agent: nil) }
                    .buttonStyle(.kervanQuiet)
                    .disabled(working || !model.connection.state.isConnected)
            } else {
                if card.column == .needs {
                    Label(L("The PM is asking you something about the team.", "PM ekip hakkında size bir şey soruyor."), systemImage: "questionmark.bubble")
                        .foregroundStyle(Color.kervanSaffron)
                } else if card.column == .review || card.column == .done {
                    Label(L("The team is set up. The PM's summary says who does what and why.", "Ekip kuruldu. PM'in özeti kimin ne yaptığını ve nedenini anlatıyor."), systemImage: "checkmark.circle")
                        .foregroundStyle(Color.kervanOasis)
                } else {
                    ProgressView().controlSize(.small)
                    Text(L("Setting the team up: the PM is reading the project and the skill library and defining the roles.", "Ekip kuruluyor: PM projeyi ve skill kütüphanesini okuyup rolleri tanımlıyor."))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let session {
                    Button(L("Open", "Aç")) { model.selectedSessionID = session.id }
                        .buttonStyle(.kervanQuiet)
                }
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func onboard(agent: String?) {
        Task {
            working = true
            defer { working = false }
            await model.store.onboardProject(project.id, agent: agent)
        }
    }

    private func choose(_ roleID: String?) {
        let pm = roleID.map { ProjectPM(roleId: $0, autoPickup: project.pm?.autoPickup ?? true, startOwnCases: project.pm?.startOwnCases ?? false) }
        Task {
            working = true
            defer { working = false }
            error = await model.store.setProjectPM(project.id, pm: pm)
        }
    }

    private func update(_ change: (inout ProjectPM) -> Void) {
        guard var pm = project.pm else { return }
        change(&pm)
        Task {
            working = true
            defer { working = false }
            error = await model.store.setProjectPM(project.id, pm: pm)
        }
    }
}

/// The project's team: who the PM hands work to. The PM puts it together; the user sees it and can take members off.
private struct ProjectTeamSection: View {
    let project: ProjectInfo
    @Environment(AppModel.self) private var model
    @State private var error: String?

    var body: some View {
        SettingsCard(
            title: L("Team", "Ekip"),
            footer: L(
                "The PM puts the team together as the work needs: for each member a role definition, an agent and the skills from the library that fit its job. It can't give members MCP servers, and skills only come from the library you approved.",
                "PM ekibi işin gerektirdiği gibi kurar: her üyeye bir rol tanımı, bir ajan ve kütüphaneden işine uyan skill'ler. Üyelere MCP sunucusu veremez; skill'ler yalnızca sizin onayladığınız kütüphaneden gelir."
            )
        ) {
            let team = project.team ?? []
            if team.isEmpty {
                Text(L("No members yet. Set the team up above, or the PM adds them when a card needs them.", "Henüz üye yok. Yukarıdan ekibi kurun ya da PM bir kart gerektirdiğinde ekler."))
                    .foregroundStyle(.secondary)
            }
            ForEach(team) { member in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(member.name) · \(model.store.agentName(member.agent))").font(.callout.weight(.medium))
                        Text(member.skills.isEmpty ? L("No skills", "Skill yok") : member.skills.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !member.instructions.isEmpty {
                            DisclosureGroup {
                                Text(member.instructions)
                                    .font(.caption)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } label: {
                                Text(L("Role definition", "Rol tanımı")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer()
                    Button(L("Remove", "Çıkar"), role: .destructive) {
                        Task { error = await model.store.removeTeamMember(member.id, from: project.id) }
                    }
                    .buttonStyle(.link)
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Color.kervanCoral)
            }
        }
    }
}

/// The project map: an agent scans the repository once, and every later session in the project gets what it wrote,
/// so it goes straight to the files its task is about instead of reading the whole repository again.
private struct ProjectMapSection: View {
    let project: ProjectInfo
    @Environment(AppModel.self) private var model
    @State private var agent = ""
    @State private var showing = false
    @State private var error: String?

    /// Mapping runs in the project folder, so only agents on the server itself that answer over ACP can do it.
    static func agents(_ store: SessionStore) -> [AgentInfo] {
        store.agents.filter { $0.node == nil && !$0.terminal }
    }

    var body: some View {
        let map = project.map
        let building = map?.status == .building
        SettingsCard(
            title: L("Project map", "Proje haritası"),
            footer: L(
                "An agent reads the repository once and writes down what is where. Every session and card in this project gets the map first, so agents go straight to the right files instead of reading everything again.",
                "Bir ajan depoyu bir kez okur ve neyin nerede olduğunu yazar. Bu projedeki her oturum ve kart önce haritayı alır; böylece ajanlar her şeyi yeniden okumak yerine doğrudan ilgili dosyalara gider."
            )
        ) {
            HStack(spacing: 8) {
                if building { ProgressView().controlSize(.small) }
                Text(status(map))
                    .foregroundStyle(map?.status == .failed ? Color.kervanCoral : Color.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            HStack {
                Picker(L("Agent", "Ajan"), selection: $agent) {
                    ForEach(Self.agents(model.store)) { Text($0.displayName).tag($0.id) }
                }
                .fixedSize()
                .disabled(building)
                Button(map == nil ? L("Build map", "Haritayı çıkar") : L("Rebuild map", "Haritayı yenile")) {
                    Task { error = await model.store.buildProjectMap(project.id, agent: agent) }
                }
                .disabled(building || agent.isEmpty || !model.connection.state.isConnected)
                if building, let sessionID = map?.sessionId {
                    Button(L("Watch", "İzle")) { model.selectedSessionID = sessionID }
                }
                Spacer()
                // A failed rebuild keeps the last good map, and sessions still get it.
                if map?.status == .ready || map?.status == .failed {
                    Button(L("Show map", "Haritayı göster")) { showing = true }
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.kervanCoral)
            }
        }
        .onAppear(perform: pickAgent)
        .onChange(of: model.store.agents) { pickAgent() }
        .sheet(isPresented: $showing) { ProjectMapSheet(project: project) }
    }

    private func status(_ map: ProjectMapInfo?) -> String {
        guard let map else { return L("No map yet.", "Henüz harita yok.") }
        switch map.status {
        case .building:
            return L("\(model.store.agentName(map.agent)) is reading the repository…", "\(model.store.agentName(map.agent)) depoyu okuyor…")
        case .failed:
            return L("The last try failed: \(map.error ?? "unknown error")", "Son deneme olmadı: \(map.error ?? "bilinmeyen hata")")
        case .ready:
            let when = SchedulesView.date(map.updatedAt)?.formatted(.relative(presentation: .named).locale(Language.shared.locale)) ?? map.updatedAt
            if let commit = map.commit {
                return L("Built at \(commit.prefix(7)) · \(when)", "\(commit.prefix(7)) commit'inde çıkarıldı · \(when)")
            }
            return L("Built \(when)", "Çıkarıldı · \(when)")
        }
    }

    private func pickAgent() {
        let offered = Self.agents(model.store)
        guard !offered.contains(where: { $0.id == agent }) else { return }
        let preferred = [project.map?.agent, model.defaultAgent?.id].compactMap { $0 }
        agent = preferred.first { id in offered.contains { $0.id == id } } ?? offered.first?.id ?? ""
    }
}

/// The map's text, as the agents in the project get it.
private struct ProjectMapSheet: View {
    let project: ProjectInfo
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.kervanCoral).padding(16)
                } else if let text = model.store.projectMaps[project.id] {
                    ScrollView {
                        Text(text.isEmpty ? L("No map yet.", "Henüz harita yok.") : text)
                            .font(.body.monospaced())
                            .foregroundStyle(text.isEmpty ? Color.secondary : Color.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                Text(L("Map of \(project.name)", "\(project.name) haritası")).foregroundStyle(.secondary)
                Spacer()
                Button(L("Done", "Tamam")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 620, height: 520)
        .background(Color.kervanCanvas)
        .task { error = await model.store.loadProjectMap(project.id) }
    }
}

/// Makes a project (from a repository to clone, a folder on the server, or an empty folder) or edits one.
struct ProjectSheet: View {
    enum Source: String, CaseIterable, Identifiable {
        case clone, folder, empty
        var id: String { rawValue }
        var title: String {
            switch self {
            case .clone: L("Clone a git repository", "Git deposu klonla")
            case .folder: L("Folder on the server", "Sunucudaki klasör")
            case .empty: L("Empty folder", "Boş klasör")
            }
        }
    }

    var project: ProjectInfo?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var instructions = ""
    @State private var buildImage = ""
    @State private var settingUpPodman = false
    @State private var source = Source.clone
    @State private var location = ""
    @State private var mapAfterAdding = true
    @State private var teamAfterAdding = true
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField(L("Name", "Ad"), text: $name, prompt: Text(L("e.g. Website", "ör. Web sitesi")))
                if project == nil {
                    Picker(L("Source", "Kaynak"), selection: $source) {
                        ForEach(Source.allCases) { Text($0.title).tag($0) }
                    }
                    switch source {
                    case .clone:
                        TextField(L("Repository URL", "Depo adresi"), text: $location, prompt: Text(L("https://github.com/user/repo.git", "https://github.com/kullanici/depo.git")))
                            .font(.body.monospaced())
                        Text(L("The server clones with its own git access; private repositories need an SSH key or credentials on the server.", "Sunucu kendi git erişimiyle klonlar; özel depolar için sunucuda SSH anahtarı ya da kimlik bilgisi gerekir."))
                            .font(.caption).foregroundStyle(.secondary)
                    case .folder:
                        TextField(L("Folder path", "Klasör yolu"), text: $location, prompt: Text(L("/home/ubuntu/projects/site", "/home/ubuntu/projelerim/site")))
                            .font(.body.monospaced())
                    case .empty:
                        Text(L("A new empty folder is made in Kervan's projects folder.", "Kervan'ın proje klasöründe yeni, boş bir klasör açılır.")).font(.caption).foregroundStyle(.secondary)
                    }
                    if source != .empty, let mapper = mapAgent {
                        Toggle(L("Map the project after adding it", "Ekledikten sonra projenin haritasını çıkar"), isOn: $mapAfterAdding)
                        Text(L(
                            "\(mapper.name) reads the repository once, so agents here don't have to read all of it for every task.",
                            "\(mapper.name) depoyu bir kez okur; böylece buradaki ajanlar her görevde hepsini okumak zorunda kalmaz."
                        ))
                        .font(.caption).foregroundStyle(.secondary)
                        Toggle(L("Let Kervan set the team up", "Ekibi Kervan kursun"), isOn: $teamAfterAdding)
                        Text(L(
                            "\(mapper.name) becomes the project's PM, reads the skill library, defines the roles the project needs and builds the team.",
                            "\(mapper.name) projenin PM'i olur, skill kütüphanesine bakar, projenin ihtiyaç duyduğu rolleri tanımlar ve ekibi kurar."
                        ))
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    TextEditor(text: $instructions)
                        .frame(minHeight: 120)
                } header: {
                    Text(L("Instructions", "Talimatlar"))
                } footer: {
                    Text(L("Told to every agent in this project before its first message: code style, test command, things to watch out for.", "Bu projedeki her ajana ilk mesajdan önce söylenir: kod stili, test komutu, dikkat edilecekler."))
                }
                Section {
                    TextField(L("Build image", "Derleme imajı"), text: $buildImage, prompt: Text(verbatim: "mcr.microsoft.com/dotnet/sdk:9.0"))
                        .font(.body.monospaced())
                    // Only where the server says it can't; one too old to say gets the server update first anyway.
                    if model.serverBuildsInContainers == false {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Label(
                                L("Building and packaging on the server needs Podman, which isn't installed there yet.", "Sunucuda derlemek ve paketlemek için Podman gerekiyor; sunucuda henüz kurulu değil."),
                                systemImage: "shippingbox"
                            )
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Button(L("Set up", "Kur")) { settingUpPodman = true }
                        }
                    }
                } footer: {
                    Text(L(
                        "Agents build and test in a throwaway container made from this image, removed when each command ends; they can name another for one command, a Windows cross-compiler say. Empty uses the project's devcontainer.json, if it has one. Needs podman or docker on the server.",
                        "Ajanlar bu imajdan açılan, her komut bitince kaldırılan bir konteynerde derler ve test eder; tek bir komut için başkasını da seçebilirler, örneğin Windows için çapraz derleyici. Boş bırakılırsa projedeki devcontainer.json kullanılır. Sunucuda podman ya da docker gerekir."
                    ))
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.kervanCoral)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            HStack {
                if saving {
                    ProgressView().controlSize(.small)
                    Text(source == .clone && project == nil ? L("Cloning…", "Klonlanıyor…") : L("Saving…", "Kaydediliyor…")).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("Cancel", "Vazgeç"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(project == nil ? L("Create project", "Projeyi oluştur") : L("Save", "Kaydet")) { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.kervanPrimary)
                    .disabled(!canSave || saving)
            }
            .padding(16)
        }
        .frame(width: 500, height: 540) // fits a window at its smallest; the form scrolls
        .sheet(isPresented: $settingUpPodman) { ServerUpdateSheet(access: .podman).environment(model) }
        .background(Color.kervanCanvas)
        .onAppear {
            name = project?.name ?? ""
            instructions = project?.instructions ?? ""
            buildImage = project?.buildImage ?? ""
        }
    }

    /// Who maps a new project: the default agent if it can, else the first one on the server that can.
    private var mapAgent: AgentInfo? {
        let offered = ProjectMapSection.agents(model.store)
        return offered.first { $0.id == model.defaultAgent?.id } ?? offered.first
    }

    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return project != nil || source == .empty || !location.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let place = location.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = ProjectInput(
            id: project?.id,
            name: name.trimmingCharacters(in: .whitespaces),
            instructions: instructions,
            // Sent always, so emptying the field clears it.
            buildImage: buildImage.trimmingCharacters(in: .whitespacesAndNewlines),
            path: project == nil && source == .folder ? place : nil,
            gitUrl: project == nil && source == .clone ? place : nil,
            mapAgent: project == nil && source != .empty && mapAfterAdding ? mapAgent?.id : nil
        )
        let before = Set(model.store.projects.map(\.id))
        if let failure = await model.store.saveProject(input) {
            error = failure
            return
        }
        if project == nil, let made = model.store.projects.first(where: { !before.contains($0.id) }) {
            model.selectedSessionID = AppModel.projectPage(made.id)
            // Its outcome shows on the project's PM section, failure included.
            if source != .empty, teamAfterAdding, let mapper = mapAgent {
                let store = model.store
                Task { await store.onboardProject(made.id, agent: mapper.id) }
            }
        }
        dismiss()
    }
}

// MARK: Scheduled tasks

/// A schedule being edited in the sheet; a new one has no id yet.
private struct ScheduleDraft: Identifiable {
    let id = UUID()
    var input: ScheduleInput
}

struct SchedulesView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: ScheduleDraft?
    @State private var error: String?

    var body: some View {
        let store = model.store
        Page(
            title: L("Scheduled tasks", "Zamanlanmış görevler"),
            subtitle: L("The server is always on: when a task is due it opens its own session and writes to the agent. You get a notification when it's done.", "Sunucu hep açık: görev vakti gelince kendi oturumunu açar ve ajana yazar. Bittiğinde bildirim gelir.")
        ) {
            Button {
                editing = ScheduleDraft(input: ScheduleInput(
                    title: "", agent: model.defaultAgent?.id ?? "", prompt: "", when: .daily(time: "09:00", weekdays: Array(1...5))
                ))
            } label: {
                Label(L("New task", "Yeni görev"), systemImage: "plus")
            }
            .buttonStyle(.kervanPrimary)
            .tint(.kervanLapis)
            .disabled(store.agents.isEmpty)
        } content: {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.kervanCoral)
            }
            if store.schedules.isEmpty {
                EmptyCard(
                    symbol: "calendar.badge.clock",
                    title: L("No tasks yet", "Henüz görev yok"),
                    text: L("For example \"run the tests and fix what breaks\" every morning at 09:00, or \"summarize new issues\" every hour.", "Ör. her sabah 09:00'da \"testleri çalıştır, kırılanı düzelt\" ya da her saat \"yeni issue'ları özetle\".")
                )
                .frame(maxWidth: .infinity)
            }
            ForEach(store.schedules) { schedule in
                row(schedule)
            }
        }
        .sheet(item: $editing) { draft in ScheduleSheet(input: draft.input) }
        .task { await store.loadSchedules() }
    }

    private func row(_ schedule: ScheduleInfo) -> some View {
        let project = model.store.project(schedule.projectId).map { ", \($0.name)" } ?? ""
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: schedule.enabled ? "clock.fill" : "clock")
                .foregroundStyle(schedule.enabled ? Color.kervanSaffron : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(schedule.title).font(.headline)
                Text("\(schedule.when.label), \(model.store.agentName(schedule.agent))\(project)")
                    .font(.callout).foregroundStyle(.secondary)
                Text(schedule.prompt).font(.callout).lineLimit(2).foregroundStyle(.secondary)
                if let lastError = schedule.lastError {
                    Label(L("Last run failed: \(lastError)", "Son çalıştırma başarısız: \(lastError)"), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.kervanCoral)
                } else if let last = schedule.lastRunAt.flatMap(Self.date) {
                    HStack(spacing: 6) {
                        let when = last.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Language.shared.locale))
                        Text(L("Last ran: \(when)", "Son çalıştı: \(when)"))
                        if let sessionID = schedule.lastSessionId, model.store.session(sessionID) != nil {
                            Button(L("Open session", "Oturumu aç")) { model.selectedSessionID = sessionID }.buttonStyle(.link)
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Toggle(L("On", "Açık"), isOn: Binding(get: { schedule.enabled }, set: { on in
                    var input = ScheduleInput(schedule)
                    input.enabled = on
                    Task { error = await model.store.saveSchedule(input) }
                }))
                .toggleStyle(.switch)
                .labelsHidden()
                .help(schedule.enabled ? L("Pause task", "Görevi duraklat") : L("Turn task on", "Görevi aç"))
                Menu {
                    Button(L("Run now", "Şimdi çalıştır")) { Task { error = await model.store.runSchedule(schedule.id) } }
                    Button(L("Edit…", "Düzenle…")) { editing = ScheduleDraft(input: ScheduleInput(schedule)) }
                    Divider()
                    Button(L("Delete", "Sil"), role: .destructive) { Task { error = await model.store.deleteSchedule(schedule.id) } }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel(L("\(schedule.title) options", "\(schedule.title) seçenekleri"))
            }
        }
        .padding(16)
        .softSurface()
    }

    static func date(_ iso: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    }
}

private struct ScheduleSheet: View {
    @State var input: ScheduleInput
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var daily = true
    @State private var time = Date()
    @State private var weekdays: Set<Int> = Set(1...5)
    @State private var minutes = 60
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField(L("Name", "Ad"), text: $input.title, prompt: Text(L("e.g. Morning test run", "ör. Sabah test turu")))
                AgentPicker(agent: $input.agent)
                // Projects are on this server; a node can work on one only through a copy, which needs an up-to-date Kervan there.
                if !projectsHere {
                    Text(L("On another machine the agent works in a folder of its own there. To work on a project there, update Kervan on that machine.", "Başka bir makinede ajan oradaki kendi klasöründe çalışır. Orada bir proje üzerinde çalışmak için o makinedeki Kervan'ı güncelleyin."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker(L("Project", "Proje"), selection: $input.projectId) {
                        Text(L("None (its own folder)", "Yok (kendi klasörü)")).tag(String?.none)
                        ForEach(model.store.projects) { Text($0.name).tag(Optional($0.id)) }
                    }
                    if input.projectId != nil, let node = model.store.agents.first(where: { $0.id == input.agent })?.node,
                       let note = AgentPlace(node: node, online: true, agents: []).projectCopyNote {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section(L("When", "Ne zaman")) {
                    Picker(L("Repeat", "Tekrar"), selection: $daily) {
                        Text(L("Daily at a set time", "Her gün belirli saatte")).tag(true)
                        Text(L("At an interval", "Belirli aralıklarla")).tag(false)
                    }
                    .pickerStyle(.radioGroup)
                    if daily {
                        DatePicker(L("Time", "Saat"), selection: $time, displayedComponents: .hourAndMinute)
                        HStack(spacing: 4) {
                            ForEach(1...7, id: \.self) { day in
                                Toggle(ScheduleWhen.dayNames[day - 1], isOn: Binding(
                                    get: { weekdays.contains(day) },
                                    set: { on in if on { weekdays.insert(day) } else { weekdays.remove(day) } }
                                ))
                                .toggleStyle(.button)
                            }
                        }
                    } else {
                        Picker(L("Interval", "Aralık"), selection: $minutes) {
                            ForEach([15, 30, 60, 120, 240, 720], id: \.self) { value in
                                Text(ScheduleWhen.interval(minutes: value).label).tag(value)
                            }
                        }
                    }
                    Text(L("Time zone: \(input.timeZone)", "Saat dilimi: \(input.timeZone)")).font(.caption).foregroundStyle(.secondary)
                }
                Section(L("What to tell the agent", "Ajana ne yazılsın")) {
                    TextEditor(text: $input.prompt).frame(minHeight: 110)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.kervanCoral)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            HStack {
                Spacer()
                Button(L("Cancel", "Vazgeç"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Save", "Kaydet")) { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.kervanPrimary)
                    .disabled(!canSave)
            }
            .padding(16)
        }
        .frame(width: 500, height: 540) // fits a window at its smallest; the form scrolls
        .background(Color.kervanCanvas)
        .onAppear(perform: load)
    }

    private var projectsHere: Bool {
        AgentPlace.canWorkOnProjects(agent: input.agent, agents: model.store.agents, nodes: model.store.nodeInfos)
    }

    private var canSave: Bool {
        !saving && !input.agent.isEmpty && !input.title.trimmingCharacters(in: .whitespaces).isEmpty
            && !input.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (!daily || !weekdays.isEmpty)
    }

    private func load() {
        switch input.when {
        case .daily(let hhmm, let days):
            daily = true
            weekdays = Set(days)
            let parts = hhmm.split(separator: ":").compactMap { Int($0) }
            time = Calendar.current.date(bySettingHour: parts.first ?? 9, minute: parts.last ?? 0, second: 0, of: .now) ?? .now
        case .interval(let value):
            daily = false
            minutes = value
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        if !projectsHere { input.projectId = nil }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        input.when = daily
            ? .daily(time: String(format: "%02d:%02d", parts.hour ?? 9, parts.minute ?? 0), weekdays: weekdays.sorted())
            : .interval(minutes: minutes)
        if let failure = await model.store.saveSchedule(input) {
            error = failure
        } else {
            dismiss()
        }
    }
}

// MARK: Usage

struct UsageView: View {
    @Environment(AppModel.self) private var model
    @State private var days = 30

    var body: some View {
        let report = model.store.usage
        Page(
            title: L("Usage", "Kullanım"),
            subtitle: L("Spending as the agents report it. Only agents that report cost (Claude API) count for now; agents used through a subscription don't show up.", "Ajanların bildirdiği harcama. Şimdilik yalnızca maliyet bildiren ajanlar (Claude API) sayılır; abonelikle çalışan ajanlar görünmez.")
        ) {
            Picker(L("Period", "Dönem"), selection: $days) {
                Text(L("7 days", "7 gün")).tag(7)
                Text(L("30 days", "30 gün")).tag(30)
                Text(L("90 days", "90 gün")).tag(90)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
        } content: {
            if let report {
                totals(report)
                if report.days.isEmpty {
                    EmptyCard(symbol: "chart.bar", title: L("No spending in this period", "Bu dönemde harcama yok"), text: L("Daily totals build up here as agents report their cost.", "Ajanlar maliyet bildirdikçe günlük toplamlar burada birikir."))
                        .frame(maxWidth: .infinity)
                } else {
                    SettingsCard(title: L("Daily", "Günlük")) { chart(report) }
                    SettingsCard(title: L("By agent", "Ajanlara göre")) {
                        ForEach(report.byAgent, id: \.agent) { entry in
                            HStack {
                                Text(model.store.agentName(entry.agent))
                                Spacer()
                                Text(usd(entry.costUsd)).monospacedDigit()
                            }
                        }
                    }
                    SettingsCard(title: L("Top sessions", "En çok harcayan oturumlar")) {
                        ForEach(report.sessions, id: \.sessionId) { entry in
                            Button {
                                if model.store.session(entry.sessionId) != nil { model.selectedSessionID = entry.sessionId }
                            } label: {
                                // The bar is the session's share of the biggest spender, so the list reads at a glance.
                                let top = report.sessions.map(\.costUsd).max() ?? 0
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(model.store.session(entry.sessionId)?.title ?? L("Deleted session", "Silinmiş oturum")).lineLimit(1)
                                        Spacer()
                                        Text(usd(entry.costUsd)).monospacedDigit().foregroundStyle(.secondary)
                                    }
                                    GeometryReader { geometry in
                                        Capsule().fill(Color.kervanLapis.opacity(0.55))
                                            .frame(width: max(3, geometry.size.width * (top > 0 ? entry.costUsd / top : 0)))
                                    }
                                    .frame(height: 3)
                                    .accessibilityHidden(true)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .task(id: days) { await model.store.loadUsage(days: days) }
    }

    private func chart(_ report: UsageReport) -> some View {
        Chart(Array(report.days.enumerated()), id: \.offset) { _, day in
            BarMark(
                x: .value(L("Day", "Gün"), Self.day(day.date) ?? .now, unit: .day),
                y: .value("USD", day.costUsd)
            )
            .foregroundStyle(by: .value(L("Agent", "Ajan"), model.store.agentName(day.agent)))
            .cornerRadius(3)
        }
        .chartForegroundStyleScale(range: [Color.kervanLapis, .kervanSaffron, .kervanOasis, .kervanCoral])
        // The whole period, so a single day is one narrow bar among empty days, not a bar across the chart.
        .chartXScale(domain: periodStart...Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now))!)
        .frame(height: 200)
        .accessibilityLabel(L("Daily spending chart", "Günlük harcama grafiği"))
    }

    private var periodStart: Date {
        Calendar.current.date(byAdding: .day, value: -(days - 1), to: Calendar.current.startOfDay(for: .now)) ?? .now
    }

    private func totals(_ report: UsageReport) -> some View {
        let today = Self.key(.now)
        let week = Self.key(Calendar.current.date(byAdding: .day, value: -6, to: .now) ?? .now)
        return HStack(spacing: 12) {
            tile(L("Today", "Bugün"), report.total(since: today))
            tile(L("Last 7 days", "Son 7 gün"), report.total(since: week))
            tile(L("Last \(days) days", "Son \(days) gün"), report.total)
        }
    }

    private func tile(_ label: String, _ amount: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(usd(amount)).font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit()
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .softSurface()
        .accessibilityElement(children: .combine)
    }

    private static let dayFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func key(_ date: Date) -> String { dayFormat.string(from: date) }
    private static func day(_ key: String) -> Date? { dayFormat.date(from: key) }
}
