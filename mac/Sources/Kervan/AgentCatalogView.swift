import AppKit
import KervanKit
import SwiftUI

/// The agents of the Agent Client Protocol's registry, as the chosen machine sees them: ones installed on it by hand
/// (added with one click), ones it can install for Kervan without sudo, and the rest with why not. Agents that can
/// run a local model offer that machine's Ollama and LM Studio models.
struct AgentCatalogSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var loadError: String?
    @State private var installing: String?
    @State private var errors: [String: String] = [:]
    @State private var showUnavailable = false
    /// The node to add agents to; nil for the server itself.
    @State private var node: String?

    private var connectedNodes: [String] { model.store.nodeInfos.filter(\.connected).map(\.name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Add an agent", "Ajan ekle")).font(.title2.weight(.semibold))
                Text(L(
                    "From the Agent Client Protocol's list of agents. Kervan installs them on the machine you choose, for itself, without sudo, and tries each one before adding it.",
                    "Agent Client Protocol'ün ajan listesinden. Kervan bunları seçtiğiniz makineye kendisi için, sudo gerekmeden kurar ve eklemeden önce her birini dener."
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding([.horizontal, .top], 22)
            .padding(.bottom, 12)

            if !connectedNodes.isEmpty {
                Picker(L("Run on", "Nerede çalışsın"), selection: $node) {
                    Text(L("This server", "Bu sunucu")).tag(String?.none)
                    ForEach(connectedNodes, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .disabled(installing != nil)
                .padding(.horizontal, 22)
                .padding(.bottom, 12)
                .onChange(of: node) { _, chosen in
                    errors = [:]
                    Task { loadError = await model.store.loadOfferedAgents(node: chosen) }
                }
            }

            if let ollama = model.store.ollama, ollama.running {
                LocalModelNote(app: .ollama, status: ollama, node: node).padding(.horizontal, 22).padding(.bottom, 12)
            } else if let node, model.store.ollama != nil {
                Label(L("Ollama isn't running on \(node). Start it there to use its models; other agents can still be added.", "\(node) üzerinde Ollama çalışmıyor. Modellerini kullanmak için orada başlatın; diğer ajanlar yine eklenebilir."), systemImage: "cpu")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 12)
            }

            if let lmStudio = model.store.lmStudio, lmStudio.running {
                LocalModelNote(app: .lmStudio, status: lmStudio, node: node).padding(.horizontal, 22).padding(.bottom, 12)
            } else if let node, model.store.lmStudio != nil {
                // A service can't see whether LM Studio is installed, only whether its local server answers.
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Label(L("Using LM Studio on \(node)? Turn on its local server there (lms server start) to see its models.", "\(node) üzerinde LM Studio mu kullanıyorsunuz? Modellerini görmek için orada yerel sunucusunu açın (lms server start)."), systemImage: "cpu")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(L("Check again", "Yeniden bak")) {
                        Task { loadError = await model.store.loadOfferedAgents(node: node) }
                    }
                    .disabled(installing != nil)
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 12)
            }

            TextField(L("Search agents", "Ajan ara"), text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 22)
                .padding(.bottom, 10)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack {
                if let source = sourceLink {
                    Link(L("About the list", "Liste hakkında"), destination: source).font(.caption)
                }
                Spacer()
                Button(L("Done", "Bitti")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(installing != nil)
            }
            .padding(14)
        }
        .frame(width: 580, height: 460) // fits under the Settings window; the list scrolls
        .background(Color.kervanCanvas)
        .task { loadError = await model.store.loadOfferedAgents() }
    }

    private var sourceLink: URL? { URL(string: "https://agentclientprotocol.com/get-started/registry") }

    @ViewBuilder
    private var content: some View {
        if let agents = model.store.offeredAgents {
            let shown = agents.filter(matches)
            let unavailable = shown.filter { $0.status == .unavailable }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    section(node.map { L("On \($0)", "\($0) üzerinde") } ?? L("On your server", "Sunucunuzda"), L("Installed by hand; they only need adding.", "Elle kurulmuş; yalnızca eklenmeleri gerekiyor."), shown.filter { $0.status == .found })
                    section(L("Can be installed", "Kurulabilir"), nil, shown.filter { $0.status == .installable })
                    section(L("Added", "Eklenmiş"), nil, shown.filter { $0.status == .added || $0.status == .builtin })
                    if !unavailable.isEmpty {
                        DisclosureGroup(isExpanded: $showUnavailable) {
                            card(unavailable).padding(.top, 8)
                        } label: {
                            Text(L("Not available here (\(unavailable.count))", "Burada kullanılamayanlar (\(unavailable.count))"))
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if shown.isEmpty {
                        Text(L("No agent matches “\(search)”.", "“\(search)” ile eşleşen ajan yok."))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 6)
            }
        } else if let loadError {
            VStack(spacing: 8) {
                Label(loadError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.kervanCoral)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L("Try again", "Yeniden dene")) { Task { self.loadError = await model.store.loadOfferedAgents(node: node) } }
            }
            .padding(22)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("Reading the list of agents…", "Ajan listesi okunuyor…")).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ note: String?, _ agents: [OfferedAgent]) -> some View {
        if !agents.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title).font(.headline)
                    if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
                }
                card(agents)
            }
        }
    }

    /// Agents on one soft card, divided by hairlines.
    private func card(_ agents: [OfferedAgent]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(agents.enumerated()), id: \.element.id) { index, agent in
                if index > 0 { Divider().padding(.leading, 14) }
                row(agent).padding(.horizontal, 14).padding(.vertical, 8)
            }
        }
        .softSurface(radius: Radius.panel)
    }

    private func row(_ agent: OfferedAgent) -> some View {
        CatalogRow(
            agent: agent,
            ollamaModels: (model.store.ollama?.running == true && agent.ollama) ? model.store.ollama?.models ?? [] : [],
            lmStudioModels: (model.store.lmStudio?.running == true && agent.ollama) ? model.store.lmStudio?.models ?? [] : [],
            installing: installing == agent.id,
            busy: installing != nil,
            error: errors[agent.id],
            install: { install(agent, model: $0) }
        )
    }

    private func matches(_ agent: OfferedAgent) -> Bool {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return agent.name.localizedCaseInsensitiveContains(query) || agent.description.localizedCaseInsensitiveContains(query)
    }

    private func install(_ agent: OfferedAgent, model localModel: LocalModel?) {
        installing = agent.id
        errors[agent.id] = nil
        Task {
            if let failure = await model.store.installAgent(agent.id, ollamaModel: localModel?.ollama, lmStudioModel: localModel?.lmStudio, node: node) {
                errors[agent.id] = failure
            }
            installing = nil
        }
    }
}

/// The app a local model comes from.
private enum LocalModelApp {
    case ollama, lmStudio

    var name: String {
        switch self {
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        }
    }
}

/// A local model to run an agent on.
private struct LocalModel {
    let app: LocalModelApp
    let name: String

    var ollama: String? { app == .ollama ? name : nil }
    var lmStudio: String? { app == .lmStudio ? name : nil }
}

/// One agent: what it is, where it stands, and the way to add it.
private struct CatalogRow: View {
    let agent: OfferedAgent
    /// The chosen machine's Ollama models, when this agent can use them.
    let ollamaModels: [String]
    /// The same from LM Studio.
    let lmStudioModels: [String]
    let installing: Bool
    let busy: Bool
    let error: String?
    let install: (LocalModel?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(agent.name).font(.headline)
                        if let version = agent.version {
                            Text(version).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                        }
                        if agent.ollama {
                            Text(L("Local models", "Yerel model"))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.kervanOasis)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.kervanOasis.opacity(0.12), in: Capsule())
                                .help(L("Can run a local model from Ollama or LM Studio.", "Ollama ya da LM Studio'dan yerel bir model çalıştırabilir."))
                        }
                    }
                    if !agent.description.isEmpty {
                        Text(agent.description)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    detail
                }
                Spacer(minLength: 8)
                action
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.kervanCoral)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var detail: some View {
        switch agent.status {
        case .found:
            if let path = agent.path {
                Text(path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        case .unavailable:
            if let reason = agent.reason { Text(reason).font(.caption).foregroundStyle(.secondary) }
        case .installable:
            Text(sourceText).font(.caption).foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    private var sourceText: String {
        switch agent.source {
        case "npm": L("Installs from npm", "npm'den kurulur")
        case "download": L("Downloads and checks it against the published checksum", "İndirilir ve yayınlanan sağlama değeriyle denetlenir")
        case "uvx": L("Runs with uv", "uv ile çalışır")
        default: ""
        }
    }

    @ViewBuilder
    private var action: some View {
        if installing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(agent.status == .found ? L("Adding…", "Ekleniyor…") : L("Installing…", "Kuruluyor…"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else {
            switch agent.status {
            case .found, .installable:
                let label = agent.status == .found ? L("Add", "Ekle") : L("Install", "Kur")
                if ollamaModels.isEmpty && lmStudioModels.isEmpty {
                    Button(label) { install(nil) }.disabled(busy)
                } else {
                    Menu(label) {
                        Button(L("With its own sign-in", "Kendi girişiyle")) { install(nil) }
                        if !ollamaModels.isEmpty {
                            Section(L("With an Ollama model", "Bir Ollama modeliyle")) {
                                ForEach(ollamaModels, id: \.self) { name in
                                    Button(name) { install(LocalModel(app: .ollama, name: name)) }
                                }
                            }
                        }
                        if !lmStudioModels.isEmpty {
                            Section(L("With an LM Studio model", "Bir LM Studio modeliyle")) {
                                ForEach(lmStudioModels, id: \.self) { name in
                                    Button(name) { install(LocalModel(app: .lmStudio, name: name)) }
                                }
                            }
                        }
                    }
                    .fixedSize()
                    .disabled(busy)
                }
            case .added, .builtin:
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.kervanOasis)
                    Text(agent.status == .builtin ? L("Built in", "Yerleşik") : L("Added", "Eklendi")).foregroundStyle(.secondary)
                }
                .font(.callout)
            case .unavailable:
                if let site = agent.website.flatMap(URL.init(string:)) {
                    Link(L("Website", "Web sitesi"), destination: site).font(.callout)
                }
            }
        }
    }
}

/// A local model app answering on the chosen machine, and how agents can use it.
private struct LocalModelNote: View {
    let app: LocalModelApp
    let status: OllamaStatus
    var node: String?

    private var place: (english: String, turkish: String) {
        node.map { ("on \($0)", "\($0) üzerinde") } ?? ("on the server", "sunucuda")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "cpu").foregroundStyle(Color.kervanOasis)
            Text(status.models.isEmpty
                ? L("\(app.name) is running \(place.english) but has no chat models yet. Download one there to use it.", "\(app.name) \(place.turkish) çalışıyor ama henüz sohbet modeli yok. Kullanmak için orada bir model indirin.")
                : L("\(app.name) is running \(place.english) with \(status.models.count) models. Agents marked Local models can run one: your code and the model stay \(node == nil ? "on your server" : "on that machine").", "\(app.name) \(place.turkish) \(status.models.count) modelle çalışıyor. Yerel model işaretli ajanlar bunlardan birini çalıştırabilir; kodunuz da model de \(node == nil ? "sunucunuzda" : "o makinede") kalır."))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.kervanOasis.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}
