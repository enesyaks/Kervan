import AppKit
import KervanKit
import SwiftUI

/// ⌘, — the server's skill library and MCP servers. Changes go straight to the server.
/// Settings tabs by name, remembered, so a step elsewhere can open the right one.
enum SettingsTab {
    static let key = "settingsTab"
    static let general = "general", skills = "skills", mcp = "mcp", agents = "agents", roles = "roles", nodes = "nodes", web = "web", alerts = "alerts"
}

/// Settings as a route: the sections are stops on one line down the left, and the caravan's saffron dot
/// travels to the stop you pick. The line is solid as far as you have come and dotted beyond, the same
/// vocabulary as the connection line on the home page.
struct SettingsView: View {
    @AppStorage(SettingsTab.key) private var tab = SettingsTab.general
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            SettingsRoute(selection: $tab, state: model.connection.state, host: model.activeAddress?.host ?? model.serverInput)
                .frame(width: 212)
            VStack(alignment: .leading, spacing: 0) {
                Text(SettingsStop.named(tab).title)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .padding(.horizontal, 20)
                    .padding(.top, 22)
                    .padding(.bottom, 2)
                    .accessibilityAddTraits(.isHeader)
                page
                    .id(tab)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.kervanCanvas)
        }
        .frame(width: 860, height: 600)
        .fontDesign(.rounded)
    }

    @ViewBuilder
    private var page: some View {
        switch tab {
        case SettingsTab.skills: SkillsSettings()
        case SettingsTab.mcp: McpSettings()
        case SettingsTab.agents: AgentsSettings()
        case SettingsTab.roles: RolesSettings()
        case SettingsTab.nodes: ScrollView { NodesSection().padding(20) }.settingsPage()
        case SettingsTab.web: ScrollView { WebAccessSection().padding(20) }.settingsPage()
        case SettingsTab.alerts: ScrollView { AlertsSection().padding(20) }.settingsPage()
        default: GeneralSettings()
        }
    }
}

/// One stop on the settings route. A new `leg` starts a little further down the line: this Mac,
/// what agents carry with them, and how the caravan reaches other machines and you.
struct SettingsStop: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let leg: Int

    static var all: [SettingsStop] {
        [
            SettingsStop(id: SettingsTab.general, title: L("General", "Genel"), symbol: "gearshape", leg: 0),
            SettingsStop(id: SettingsTab.skills, title: L("Skills", "Skill'ler"), symbol: "book.closed", leg: 1),
            SettingsStop(id: SettingsTab.mcp, title: L("MCP servers", "MCP sunucuları"), symbol: "point.3.connected.trianglepath.dotted", leg: 1),
            SettingsStop(id: SettingsTab.agents, title: L("Agents", "Ajanlar"), symbol: "person.2", leg: 1),
            SettingsStop(id: SettingsTab.roles, title: L("Roles", "Roller"), symbol: "theatermasks", leg: 1),
            SettingsStop(id: SettingsTab.nodes, title: L("Nodes", "Node'lar"), symbol: "server.rack", leg: 2),
            SettingsStop(id: SettingsTab.web, title: L("Web access", "Web erişimi"), symbol: "globe", leg: 2),
            SettingsStop(id: SettingsTab.alerts, title: L("Alerts", "Bildirimler"), symbol: "bell.badge", leg: 2),
        ]
    }

    static func named(_ id: String) -> SettingsStop { all.first { $0.id == id } ?? all[0] }
}

struct SettingsRoute: View {
    @Binding var selection: String
    let state: ConnectionState
    let host: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var caravan

    private static let rowHeight: CGFloat = 38
    private static let legGap: CGFloat = 18
    private static let track: CGFloat = 28

    var body: some View {
        let stops = SettingsStop.all
        let at = stops.firstIndex { $0.id == selection } ?? 0
        VStack(alignment: .leading, spacing: 0) {
            Text(L("Settings", "Ayarlar"))
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.leading, 20)
                .padding(.top, 24)
                .padding(.bottom, 14)

            ForEach(Array(stops.enumerated()), id: \.element.id) { index, stop in
                if index > 0, stops[index - 1].leg != stop.leg {
                    // Between legs the road just carries on.
                    RouteSegment(travelled: index <= at)
                        .frame(width: Self.track, height: Self.legGap)
                        .padding(.leading, 10)
                }
                row(stop, index: index, at: at, last: index == stops.count - 1)
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                StatusDot(color: state.tint, size: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.shortLabel).font(.callout)
                    if !host.isEmpty {
                        Text(host).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .accessibilityElement(children: .combine)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.kervanSidebar)
    }

    private func row(_ stop: SettingsStop, index: Int, at: Int, last: Bool) -> some View {
        let selected = index == at
        return Button {
            withAnimation(Motion.pick(Motion.gentle, reduce: reduceMotion)) { selection = stop.id }
        } label: {
            HStack(spacing: 6) {
                ZStack {
                    VStack(spacing: 0) {
                        RouteSegment(travelled: index <= at).opacity(index == 0 ? 0 : 1)
                        RouteSegment(travelled: index < at).opacity(last ? 0 : 1)
                    }
                    Circle()
                        .fill(Color.kervanSidebar)
                        .frame(width: 11, height: 11)
                    Circle()
                        .strokeBorder(index < at ? Color.kervanLapis : Color.secondary.opacity(0.45), lineWidth: 1.5)
                        .frame(width: 9, height: 9)
                    if selected {
                        // The caravan itself: one dot that walks to whichever stop is open.
                        Circle()
                            .fill(Color.kervanSaffron)
                            .frame(width: 11, height: 11)
                            .background(Circle().fill(Color.kervanSaffron.opacity(0.25)).frame(width: 21, height: 21))
                            .matchedGeometryEffect(id: "caravan", in: caravan)
                    }
                }
                .frame(width: Self.track, height: Self.rowHeight)

                HStack(spacing: 8) {
                    Image(systemName: stop.symbol)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(selected ? Color.kervanLapis : Color.secondary)
                        .frame(width: 18)
                    Text(stop.title)
                        .fontWeight(selected ? .semibold : .regular)
                        .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.78))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(height: Self.rowHeight - 6)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                            .fill(Color.kervanSurface)
                            .shadow(color: .black.opacity(0.07), radius: 5, y: 2)
                            .overlay(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous).strokeBorder(Color.kervanHairline, lineWidth: 1))
                            .matchedGeometryEffect(id: "plate", in: caravan)
                    }
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
        .help("⌘\(index + 1)")
        .accessibilityLabel(stop.title)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

/// A stretch of the route: solid lapis where the caravan has been, dotted where it hasn't.
struct RouteSegment: View {
    let travelled: Bool

    var body: some View {
        Line()
            .stroke(
                travelled ? Color.kervanLapis : Color.secondary.opacity(0.45),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: travelled ? [] : [1.5, 5])
            )
            .accessibilityHidden(true)
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: rect.midX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            }
        }
    }
}

/// Light, dark or system as three small windows you can see, rather than three words.
private struct AppearanceSwatches: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Appearance.allCases) { appearance in
                let selected = selection == appearance.rawValue
                Button {
                    selection = appearance.rawValue
                } label: {
                    VStack(spacing: 7) {
                        preview(appearance)
                            .frame(height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                                    .strokeBorder(selected ? Color.kervanLapis : Color.secondary.opacity(0.25), lineWidth: selected ? 2 : 1)
                            )
                        HStack(spacing: 5) {
                            if selected {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.kervanLapis).font(.caption)
                            }
                            Text(appearance.label)
                                .font(.callout.weight(selected ? .semibold : .regular))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(SoftPressStyle())
                .accessibilityLabel(appearance.label)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    @ViewBuilder
    private func preview(_ appearance: Appearance) -> some View {
        switch appearance {
        case .light: MiniWindow(dark: false)
        case .dark: MiniWindow(dark: true)
        case .system:
            // Half and half: it follows whichever macOS is showing.
            MiniWindow(dark: false)
                .overlay {
                    MiniWindow(dark: true).mask(alignment: .trailing) {
                        GeometryReader { geometry in
                            Path { path in
                                path.move(to: CGPoint(x: geometry.size.width * 0.62, y: 0))
                                path.addLine(to: CGPoint(x: geometry.size.width, y: 0))
                                path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height))
                                path.addLine(to: CGPoint(x: geometry.size.width * 0.38, y: geometry.size.height))
                                path.closeSubpath()
                            }
                        }
                    }
                }
        }
    }
}

/// Kervan's own window in a thumbnail: sidebar, a message, the composer and a saffron status light.
private struct MiniWindow: View {
    let dark: Bool

    private func tone(_ light: UInt32, _ night: UInt32) -> Color { Color(light: dark ? night : light, dark: dark ? night : light) }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Circle().fill(tone(0xC9953A, 0xE6BE6E)).frame(width: 5, height: 5)
                ForEach(0..<3, id: \.self) { _ in
                    Capsule().fill(tone(0x1B2433, 0xE7ECF3).opacity(0.22)).frame(height: 4)
                }
                Spacer(minLength: 0)
            }
            .padding(7)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(tone(0xECF0F5, 0x0F1620))
            .frame(width: 44)

            VStack(alignment: .trailing, spacing: 5) {
                Capsule().fill(tone(0x4A6FA5, 0x8AAEDB).opacity(0.35)).frame(width: 44, height: 8)
                Capsule().fill(tone(0x1B2433, 0xE7ECF3).opacity(0.22)).frame(height: 4).frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 18)
                Spacer(minLength: 0)
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(tone(0xFFFFFF, 0x1A2433)).frame(height: 12)
            }
            .padding(7)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(tone(0xF4F6F9, 0x131B27))
        }
        .accessibilityHidden(true)
    }
}

/// Settings › Genel: how the app looks and opens, and which server it is on.
private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Appearance.key) private var appearance = Appearance.light.rawValue
    @AppStorage(AppModel.introKey) private var showIntro = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsCard(
                    title: L("Language", "Dil"),
                    footer: L(
                        "System uses Turkish when macOS prefers it, English otherwise. Menus follow after a restart.",
                        "Sistem, macOS Türkçe'yi tercih ediyorsa Türkçe, değilse İngilizce kullanır. Menüler yeniden açılınca değişir."
                    )
                ) {
                    Picker(L("Language", "Dil"), selection: Bindable(Language.shared).choice) {
                        Text(L("System", "Sistem")).tag(Language.Choice.system)
                        Text(verbatim: "English").tag(Language.Choice.english)
                        Text(verbatim: "Türkçe").tag(Language.Choice.turkish)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                SettingsCard(title: L("Appearance", "Görünüm"), footer: L("Light is the default. System follows macOS.", "Açık görünüm varsayılandır. Sistem, macOS'un ayarını izler.")) {
                    AppearanceSwatches(selection: $appearance)
                }

                SettingsCard(title: L("Launch", "Açılış"), footer: L("The short animation of the caravan walking to the oasis when the app opens. A click skips it.", "Uygulama açılırken kervanın vahaya yürüdüğü kısa animasyon. Tıklayınca geçilir.")) {
                    Toggle(L("Show the intro at launch", "Açılışta introyu göster"), isOn: $showIntro)
                    Button(L("Play the intro now", "Introyu şimdi oynat")) { model.showIntro = true }
                        .buttonStyle(.link)
                }

                UpdatesCard()

                SettingsCard(
                    title: L("Help", "Yardım"),
                    footer: L("Opens a GitHub issue with versions and recent errors filled in; you read and edit it first.", "Sürümler ve son hatalarla doldurulmuş bir GitHub issue'su açar; önce okuyup düzenlersiniz.")
                ) {
                    Button(L("Report a problem…", "Sorun bildir…")) {
                        // The report opens over the main window; this one would hide it.
                        dismiss()
                        model.showReportProblem = true
                    }
                }

                SettingsCard(title: L("Server", "Sunucu")) {
                    LabeledContent(L("Address", "Adres")) {
                        Text(model.activeAddress?.host ?? model.serverInput)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                    }
                    LabeledContent(L("Status", "Durum")) {
                        HStack(spacing: 6) {
                            StatusDot(color: model.connection.state.tint, size: 7)
                            Text(model.connection.state.shortLabel)
                        }
                    }
                }

                SettingsCard(
                    title: "GitHub",
                    footer: L(
                        "Lets the server push a session's work and open pull requests from the Changes panel. You approve it in your browser; the sign-in stays on the server.",
                        "Sunucunun bir oturumun işini push etmesini ve Değişiklikler panelinden pull request açmasını sağlar. Tarayıcınızda onaylarsınız; giriş sunucuda kalır."
                    )
                ) {
                    GitHubConnection()
                }
            }
            .padding(20)
        }
        .settingsPage()
    }
}

/// A titled group of settings on a soft card, with an optional note under it.
struct SettingsCard<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .softSurface()
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SkillsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var skills: [SkillInfo] = []
    @State private var busy = false
    @State private var error: String?
    @State private var removing: SkillInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Skills are folders (with a SKILL.md) that tell an agent how to do a particular job. You pick which ones to use when you start a session.", "Skill'ler, ajanın belirli bir işi nasıl yapacağını anlatan klasörlerdir (içinde SKILL.md). Yeni oturum açarken hangilerinin kullanılacağını seçersiniz."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List {
                ForEach(skills) { skill in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(skill.name).font(.body.monospaced())
                            Text(skill.description.isEmpty ? L("No description", "Açıklama yok") : skill.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(fileCount(skill.files)).font(.caption).foregroundStyle(.secondary)
                        Button(L("Delete", "Sil"), role: .destructive) { removing = skill }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .softList()
            .overlay {
                if skills.isEmpty {
                    EmptyCard(symbol: "book.closed", title: L("No skills yet", "Henüz skill yok"), text: L("Add a folder with a SKILL.md in it; you can pick it when you start a session.", "İçinde SKILL.md olan bir klasör ekleyin; yeni oturum açarken seçebilirsiniz."))
                }
            }

            HStack {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.kervanCoral).font(.callout)
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(L("Add skill folder…", "Skill klasörü ekle…"), action: addSkill)
                    .buttonStyle(.kervanPrimary)
                    .disabled(busy || model.fileClient == nil)
            }
        }
        .padding(20)
        .settingsPage()
        .task { await reload() }
        .confirmationDialog(
            L("Delete the skill \(removing?.name ?? "")?", "\(removing?.name ?? "") skill'i silinsin mi?"),
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
        ) {
            Button(L("Delete skill", "Skill'i sil"), role: .destructive) {
                if let skill = removing { Task { await remove(skill) } }
            }
        } message: {
            Text(L("It's removed from the library. Copies in sessions started with it stay.", "Kütüphaneden kalkar. Bu skill ile açılmış oturumlardaki kopyalar etkilenmez."))
        }
    }

    private func addSkill() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = L("Add", "Ekle")
        panel.message = L("Choose one or more folders with a SKILL.md in them.", "İçinde SKILL.md olan bir ya da daha fazla klasör seçin.")
        guard panel.runModal() == .OK, let client = model.fileClient else { return }
        let folders = panel.urls
        Task {
            busy = true
            defer { busy = false }
            do {
                for folder in folders { try await client.uploadSkill(folder: folder) }
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            await reload()
        }
    }

    private func remove(_ skill: SkillInfo) async {
        do {
            try await model.fileClient?.deleteSkill(skill.name)
        } catch {
            self.error = error.localizedDescription
        }
        await reload()
    }

    private func reload() async {
        guard let client = model.fileClient else {
            error = L("Connect to a server first.", "Önce sunucuya bağlanın.")
            return
        }
        do {
            skills = try await client.listSkills()
        } catch {
            self.error = L("Couldn't load skills: \(error.localizedDescription)", "Skill'ler alınamadı: \(error.localizedDescription)")
        }
    }
}

private struct McpSettings: View {
    @Environment(AppModel.self) private var model
    @State private var editing: McpDraft?
    @State private var removing: McpServerSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("MCP servers give agents new tools (GitHub, databases, a browser…). Secret values stay on the server; only their names show here.", "MCP sunucuları ajanlara yeni araçlar verir (GitHub, veritabanı, tarayıcı…). Gizli değerler yalnızca sunucuda tutulur; burada sadece adları görünür."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List {
                ForEach(model.store.mcpServers) { server in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.name).font(.body.monospaced())
                            Text(summary(server)).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button(L("Edit", "Düzenle")) { editing = McpDraft(server) }.buttonStyle(.borderless)
                        Button(L("Delete", "Sil"), role: .destructive) { removing = server }.buttonStyle(.borderless)
                    }
                }
            }
            .softList()
            .overlay {
                if model.store.mcpServers.isEmpty {
                    EmptyCard(symbol: "point.3.connected.trianglepath.dotted", title: L("No MCP servers yet", "Henüz MCP sunucusu yok"), text: L("Give agents tools like GitHub, a database or a browser here.", "GitHub, veritabanı ya da tarayıcı gibi araçları ajanlara buradan verirsiniz."))
                }
            }

            HStack {
                Spacer()
                Button(L("Add MCP server…", "MCP sunucusu ekle…")) { editing = McpDraft() }
                    .buttonStyle(.kervanPrimary)
                    .disabled(!model.connection.state.isConnected)
            }
        }
        .padding(20)
        .settingsPage()
        .sheet(item: $editing) { draft in
            McpEditor(draft: draft) { input in
                Task { await model.store.saveMcp(input) }
            }
        }
        .confirmationDialog(
            L("Delete \(removing?.name ?? "")?", "\(removing?.name ?? "") silinsin mi?"),
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
        ) {
            Button(L("Delete server", "Sunucuyu sil"), role: .destructive) {
                if let server = removing { Task { await model.store.deleteMcp(server.name) } }
            }
        } message: {
            Text(L("Its saved secrets are deleted too. Open sessions lose it the next time they restart.", "Kayıtlı gizli değerleri de silinir. Açık oturumlar bir sonraki yeniden başlatmada bu sunucuyu kullanamaz."))
        }
    }

    private func summary(_ server: McpServerSummary) -> String {
        let target = server.transport == .http ? server.url ?? "" : ([server.command ?? ""] + (server.args ?? [])).joined(separator: " ")
        let secrets = server.envKeys + server.headerKeys
        return secrets.isEmpty ? target : "\(target)  ·  \(secrets.joined(separator: ", "))"
    }
}

/// Form state for one MCP server. Secret rows loaded from the server start empty and mean "keep".
struct McpDraft: Identifiable {
    struct Secret: Identifiable {
        let id = UUID()
        var key: String
        var value: String
        /// Came from the server: an empty value keeps what is stored.
        var stored: Bool
    }

    let id = UUID()
    var isNew: Bool
    var name = ""
    var transport: McpServerSummary.Transport = .stdio
    var command = ""
    var args = ""
    var url = ""
    var secrets: [Secret] = []

    init() { isNew = true }

    init(_ server: McpServerSummary) {
        isNew = false
        name = server.name
        transport = server.transport
        command = server.command ?? ""
        args = joinArguments(server.args ?? [])
        url = server.url ?? ""
        secrets = (server.transport == .http ? server.headerKeys : server.envKeys).map { Secret(key: $0, value: "", stored: true) }
    }

    var input: McpServerInput {
        let map = Dictionary(
            secrets.filter { !$0.key.isEmpty }.map { ($0.key, $0.stored && $0.value.isEmpty ? nil : Optional($0.value)) },
            uniquingKeysWith: { _, last in last }
        )
        switch transport {
        case .stdio:
            return McpServerInput(name: name, transport: .stdio, command: command, args: splitArguments(args), env: map)
        case .http:
            return McpServerInput(name: name, transport: .http, url: url, headers: map)
        }
    }

    var isValid: Bool {
        !name.isEmpty && (transport == .stdio ? !command.trimmingCharacters(in: .whitespaces).isEmpty : url.hasPrefix("http"))
    }
}

private struct McpEditor: View {
    @State var draft: McpDraft
    let save: (McpServerInput) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField(L("Name", "Ad"), text: $draft.name, prompt: Text("github"))
                    .disabled(!draft.isNew)
                Picker(L("Connection", "Bağlantı"), selection: $draft.transport) {
                    Text(L("Command (stdio)", "Komut (stdio)")).tag(McpServerSummary.Transport.stdio)
                    Text("HTTP").tag(McpServerSummary.Transport.http)
                }
                .pickerStyle(.segmented)
                .disabled(!draft.isNew)

                if draft.transport == .stdio {
                    TextField(L("Command", "Komut"), text: $draft.command, prompt: Text("npx"))
                        .font(.body.monospaced())
                    TextField(L("Arguments", "Argümanlar"), text: $draft.args, prompt: Text("-y @modelcontextprotocol/server-github"))
                        .font(.body.monospaced())
                } else {
                    TextField(L("Address", "Adres"), text: $draft.url, prompt: Text("https://mcp.example.com/mcp"))
                        .font(.body.monospaced())
                }

                Section(draft.transport == .stdio ? L("Environment variables", "Ortam değişkenleri") : L("HTTP headers", "HTTP başlıkları")) {
                    ForEach($draft.secrets) { $secret in
                        HStack {
                            TextField(L("Name", "Ad"), text: $secret.key)
                                .font(.body.monospaced())
                                .disabled(secret.stored)
                            SecureField(secret.stored ? L("saved — type to change", "kayıtlı — değiştirmek için yazın") : L("Value", "Değer"), text: $secret.value)
                            Button {
                                draft.secrets.removeAll { $0.id == secret.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(L("Remove \(secret.key)", "\(secret.key) satırını kaldır"))
                        }
                    }
                    Button(L("Add", "Ekle")) { draft.secrets.append(.init(key: "", value: "", stored: false)) }
                        .buttonStyle(.link)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            HStack {
                Spacer()
                Button(L("Cancel", "Vazgeç"), role: .cancel) { dismiss() }
                    .buttonStyle(.kervanQuiet)
                    .keyboardShortcut(.cancelAction)
                Button(draft.isNew ? L("Add", "Ekle") : L("Save", "Kaydet")) {
                    save(draft.input)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.kervanPrimary)
                .disabled(!draft.isValid)
            }
            .padding(16)
        }
        .frame(width: 500, height: 420) // fits under the Settings window; the form scrolls
        .background(Color.kervanCanvas)
    }
}

private struct AgentsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var editing: AgentDraft?
    @State private var removing: AgentConfig?
    @State private var browsing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("The agents the server can run. An agent you add is tried once on the server before it's saved; if it doesn't work, it isn't added.", "Sunucunun çalıştırabildiği ajanlar. Eklediğiniz ajan, kaydedilmeden önce sunucuda bir kez denenir; çalışmazsa eklenmez."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List {
                ForEach(model.store.agentConfigs) { agent in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(agent.name)
                                if agent.source == .builtin {
                                    Text(L("built in", "yerleşik")).font(.caption2).foregroundStyle(.secondary)
                                }
                                if !agent.available {
                                    Text(L("not working", "çalışmıyor")).font(.caption2).foregroundStyle(.kervanCoral)
                                }
                            }
                            Text(([agent.command] + agent.args).joined(separator: " "))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if AgentAccountSignIn.offers(agent.id) {
                                AgentAccountSignIn(
                                    agentID: agent.id,
                                    ready: agent.signedIn != false || model.store.agentLoginOutcomes[agent.id] == .signedIn,
                                    compact: true
                                )
                                .padding(.top, 4)
                            }
                        }
                        Spacer()
                        Button(L("Edit", "Düzenle")) { editing = AgentDraft(agent) }.buttonStyle(.borderless)
                        if agent.source == .app {
                            Button(L("Delete", "Sil"), role: .destructive) { removing = agent }.buttonStyle(.borderless)
                        }
                    }
                }
            }
            .softList()


            HStack {
                Spacer()
                Button(L("Add by command…", "Komutla ekle…")) { editing = AgentDraft() }
                    .disabled(!model.connection.state.isConnected)
                Button(L("Browse agents…", "Ajanlara göz at…")) { browsing = true }
                    .buttonStyle(.kervanPrimary)
                    .disabled(!model.connection.state.isConnected)
            }
        }
        .padding(20)
        .settingsPage()
        .task { await model.store.loadAgentConfigs() }
        .sheet(item: $editing) { draft in
            AgentEditor(draft: draft, nodes: model.store.nodes)
        }
        .sheet(isPresented: $browsing) {
            AgentCatalogSheet().environment(model)
        }
        .confirmationDialog(
            L("Delete \(removing?.name ?? "")?", "\(removing?.name ?? "") silinsin mi?"),
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
        ) {
            Button(L("Delete agent", "Ajanı sil"), role: .destructive) {
                if let agent = removing { Task { await model.store.deleteAgent(agent.id) } }
            }
        } message: {
            Text(L("Sessions with this agent keep their history but can't be restarted.", "Bu ajanla açılmış oturumlar geçmişleriyle kalır ama yeniden başlatılamaz."))
        }
    }
}

/// Form state for one agent. Editing a built-in agent saves an app-managed copy that replaces it.
struct AgentDraft: Identifiable {
    enum Kind: Hashable { case builtin, command }

    let id = UUID()
    var isNew: Bool
    var agentID = ""
    var name = ""
    var kind: Kind = .command
    var command = ""
    var args = ""
    var authMethod = ""
    var skillsDir = ""
    var node = "local"
    var terminal = false
    var quietMs: Int?
    var secrets: [McpDraft.Secret] = []

    static let builtinIDs = ["claude", "codex", "gemini"]

    init() { isNew = true }

    init(_ agent: AgentConfig) {
        isNew = false
        agentID = agent.id
        name = agent.name
        // Built-in agents are listed with their resolved path; editing keeps them on the shipped adapter.
        kind = agent.source == .builtin && Self.builtinIDs.contains(agent.id) || agent.command == "builtin" ? .builtin : .command
        command = kind == .builtin ? "" : agent.command
        args = kind == .builtin ? "" : joinArguments(agent.args)
        authMethod = agent.authMethod ?? ""
        skillsDir = agent.skillsDir ?? ""
        node = agent.node
        terminal = agent.protocol == "pty"
        quietMs = agent.quietMs
        secrets = agent.envKeys.map { McpDraft.Secret(key: $0, value: "", stored: agent.source == .app) }
    }

    var input: AgentInput {
        AgentInput(
            id: agentID,
            name: name,
            command: kind == .builtin ? "builtin" : command,
            args: kind == .builtin ? [] : splitArguments(args),
            authMethod: authMethod.isEmpty ? nil : authMethod,
            skillsDir: skillsDir.isEmpty ? nil : skillsDir,
            env: Dictionary(
                secrets.filter { !$0.key.isEmpty }.map { ($0.key, $0.stored && $0.value.isEmpty ? nil : Optional($0.value)) },
                uniquingKeysWith: { _, last in last }
            ),
            node: node,
            protocol: terminal ? "pty" : nil,
            quietMs: terminal ? quietMs : nil
        )
    }

    var isValid: Bool {
        !agentID.isEmpty && !name.isEmpty && (kind == .builtin ? Self.builtinIDs.contains(agentID) : !command.isEmpty)
    }
}

private struct AgentEditor: View {
    @State var draft: AgentDraft
    let nodes: [String]
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField(L("ID", "Kimlik"), text: $draft.agentID, prompt: Text("opencode"))
                    .font(.body.monospaced())
                    .disabled(!draft.isNew)
                TextField(L("Name", "Ad"), text: $draft.name, prompt: Text("OpenCode"))
                Picker("Node", selection: $draft.node) {
                    ForEach(nodes, id: \.self) { node in
                        Text(node == "local" ? L("This server", "Bu sunucu") : node).tag(node)
                    }
                }
                .help(L("Where the agent runs: this server or a kervan-node connected to it.", "Ajanın çalışacağı makine. Bu sunucu ya da ona bağlanmış bir kervan-node."))

                Picker(L("Source", "Kaynak"), selection: $draft.kind) {
                    Text(L("Command", "Komut")).tag(AgentDraft.Kind.command)
                    Text(L("Built-in adapter", "Yerleşik adaptör")).tag(AgentDraft.Kind.builtin)
                }
                .pickerStyle(.segmented)

                if draft.kind == .command {
                    TextField(L("Command", "Komut"), text: $draft.command, prompt: Text("opencode"))
                        .font(.body.monospaced())
                    TextField(L("Arguments", "Argümanlar"), text: $draft.args, prompt: Text("acp"))
                        .font(.body.monospaced())
                } else {
                    Text(L("Uses the adapter that comes with the server; the ID must be claude, codex or gemini.", "Sunucuyla gelen adaptör kullanılır; kimlik claude, codex ya da gemini olmalı."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if draft.kind == .command {
                    Toggle(isOn: $draft.terminal) {
                        Text(L("Run in a terminal", "Terminal üzerinden çalıştır"))
                        Text(L("For line-based tools without ACP. Messages are typed into a terminal and the answer ends when the agent goes quiet. No approval cards and no resuming.", "ACP desteklemeyen, satır satır çalışan araçlar için. Mesajlar terminale yazılır; ajan sustuğunda yanıt bitmiş sayılır. Onay kartı ve kaldığı yerden devam yoktur."))
                    }
                    if draft.terminal {
                        LabeledContent(L("Quiet time", "Sessizlik süresi")) {
                            HStack(spacing: 4) {
                                TextField(L("Quiet time", "Sessizlik süresi"), value: $draft.quietMs, format: .number, prompt: Text("2000"))
                                    .labelsHidden()
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 80)
                                Text("ms").foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                TextField(L("Auth method", "Kimlik doğrulama yöntemi"), text: $draft.authMethod, prompt: Text(L("optional, e.g. gemini-api-key", "isteğe bağlı, ör. gemini-api-key")))
                    .font(.body.monospaced())
                TextField(L("Skills folder", "Skill klasörü"), text: $draft.skillsDir, prompt: Text(L("optional, e.g. .claude/skills", "isteğe bağlı, ör. .claude/skills")))
                    .font(.body.monospaced())

                Section(L("Environment variables", "Ortam değişkenleri")) {
                    ForEach($draft.secrets) { $secret in
                        HStack {
                            TextField(L("Name", "Ad"), text: $secret.key)
                                .font(.body.monospaced())
                                .disabled(secret.stored)
                            SecureField(secret.stored ? L("saved — type to change", "kayıtlı — değiştirmek için yazın") : L("Value", "Değer"), text: $secret.value)
                            Button {
                                draft.secrets.removeAll { $0.id == secret.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(L("Remove \(secret.key)", "\(secret.key) satırını kaldır"))
                        }
                    }
                    Button(L("Add", "Ekle")) { draft.secrets.append(.init(key: "", value: "", stored: false)) }
                        .buttonStyle(.link)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .disabled(saving)

            HStack {
                if saving {
                    ProgressView().controlSize(.small)
                    Text(L("Trying the agent on the server…", "Ajan sunucuda deneniyor…")).foregroundStyle(.secondary)
                } else if let error = model.store.agentSaveError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.kervanCoral)
                        .lineLimit(3)
                        .font(.callout)
                }
                Spacer()
                Button(L("Cancel", "Vazgeç"), role: .cancel) { dismiss() }
                    .buttonStyle(.kervanQuiet)
                    .keyboardShortcut(.cancelAction)
                Button(draft.isNew ? L("Try and add", "Dene ve ekle") : L("Try and save", "Dene ve kaydet")) {
                    Task {
                        saving = true
                        await model.store.saveAgent(draft.input)
                        saving = false
                        if model.store.agentSaveError == nil { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.kervanPrimary)
                .disabled(!draft.isValid || saving)
            }
            .padding(16)
        }
        .frame(width: 520, height: 440) // fits under the Settings window; the form scrolls
        .background(Color.kervanCanvas)
    }
}

/// What an empty settings list says: what belongs here and how to add the first one.
struct EmptyCard: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            EmptyRoute(symbol: symbol)
                .padding(.bottom, 4)
            Text(title).font(.headline)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .padding(24)
    }
}
