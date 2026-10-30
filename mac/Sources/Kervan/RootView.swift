import AppKit
import KervanKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 230, ideal: 260)
        } detail: {
            Group {
                if !model.isLinked || model.connection.state.isFailed {
                    ConnectView()
                } else if model.selectedSessionID == AppModel.usagePage {
                    UsageView()
                } else if model.selectedSessionID == AppModel.schedulesPage {
                    SchedulesView()
                } else if let id = model.selectedSessionID, id.hasPrefix(AppModel.projectPrefix) {
                    ProjectView(projectID: String(id.dropFirst(AppModel.projectPrefix.count))).id(id)
                } else if let id = model.selectedSessionID, model.store.session(id) != nil {
                    if model.showCrew, let crew = Crew.of(id, sessions: model.store.sessions, teams: model.store.teams) {
                        CrewView(crew: crew, selected: id)
                    } else {
                        ChatView(sessionID: id).id(id)
                    }
                } else {
                    OverviewView()
                }
            }
            // A page's content never sets the window's minimum size; long pages scroll instead.
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.kervanCanvas)
        }
        .frame(minWidth: 820, minHeight: 540)
        // Under the first run the app is not there yet: no clicks, no VoiceOver.
        .allowsHitTesting(!model.showOnboarding)
        .accessibilityHidden(model.showOnboarding)
        .fontDesign(.rounded)
        // The intro fills the whole window; the toolbar comes back with everything else.
        .toolbar(model.showIntro || model.showOnboarding ? .hidden : .visible, for: .windowToolbar)
        .overlay {
            if model.showOnboarding {
                OnboardingView()
                    .transition(.opacity)
            }
        }
        .overlay {
            if model.showIntro {
                IntroView {
                    withAnimation(Motion.pick(Motion.smooth, reduce: reduceMotion)) { model.showIntro = false }
                }
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 1.04)))
            }
        }
        .sheet(isPresented: Bindable(model).showServerUpdate) {
            ServerUpdateSheet().environment(model)
        }
        .sheet(isPresented: Bindable(model).showReportProblem) {
            ReportProblemSheet().environment(model)
        }
        .sheet(isPresented: Bindable(model).showNewTeam) {
            NewTeamSheet().environment(model)
        }
        .sheet(isPresented: Binding(get: { model.newSessionAgent != nil }, set: { if !$0 { model.newSessionAgent = nil } })) {
            if let agent = model.newSessionAgent {
                NewSessionSheet(agent: agent, project: model.newSessionProject).environment(model)
            }
        }
        .onChange(of: model.store.lastCreatedSessionID) { _, created in
            if let created { model.selectedSessionID = created }
        }
        // Agents blocked on an approval show up on the Dock icon, so a backgrounded app still asks.
        .onChange(of: model.store.waitingCount, initial: true) { _, waiting in
            NSApp.dockTile.badgeLabel = waiting > 0 ? "\(waiting)" : nil
        }
    }
}

private struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    /// Between a keystroke and the debounced request, so the list says "searching", not "no results".
    @State private var typing = false
    @State private var showArchive = false
    @State private var renaming: SessionInfo?
    @State private var newTitle = ""
    @State private var newProject = false

    var body: some View {
        @Bindable var model = model
        let store = model.store
        // Team members are listed under their team, helpers under their lead, not on their own.
        let (groups, archived) = SessionGroups.group(
            store.sessions.filter { $0.teamId == nil && $0.parentId == nil },
            lastActivity: { store.lastActivity($0.id) }
        )
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty

        List(selection: $model.selectedSessionID) {
            if searching {
                SearchResults(hits: store.searchHits, query: query, searching: typing || store.isSearching)
            } else {
                Section {
                    Label(L("Scheduled tasks", "Zamanlanmış görevler"), systemImage: "calendar.badge.clock").tag(AppModel.schedulesPage)
                    Label(L("Usage", "Kullanım"), systemImage: "chart.bar").tag(AppModel.usagePage)
                }
                Section {
                    ForEach(store.projects) { project in
                        Label(project.name, systemImage: "folder")
                            .tag(AppModel.projectPage(project.id))
                            .contextMenu {
                                Button(L("New session in this project", "Bu projede yeni oturum")) { model.newSession(project: project.id) }
                            }
                    }
                    if store.projects.isEmpty {
                        Button(L("Add project…", "Proje ekle…")) { newProject = true }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    HStack {
                        Text(L("Projects", "Projeler"))
                        Spacer()
                        Button {
                            newProject = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.borderless)
                        .help(L("New project", "Yeni proje"))
                        .accessibilityLabel(L("New project", "Yeni proje"))
                    }
                }
                if groups.isEmpty {
                    Section(L("Sessions", "Oturumlar")) {
                        Text(L("No sessions yet", "Henüz oturum yok")).foregroundStyle(.secondary)
                    }
                }
                ForEach(groups) { group in
                    Section(group.title) {
                        ForEach(group.sessions) { session in
                            SessionRow(session: session).tag(session.id).contextMenu { menu(for: session) }
                            ForEach(store.helpers(of: session.id)) { helper in
                                HelperRow(session: helper).tag(helper.id).contextMenu { menu(for: helper) }
                            }
                        }
                    }
                }
                if !archived.isEmpty {
                    Section(isExpanded: $showArchive) {
                        ForEach(archived) { session in
                            SessionRow(session: session).tag(session.id).contextMenu { menu(for: session) }
                        }
                    } header: {
                        Text(L("Archive (\(archived.count))", "Arşiv (\(archived.count))"))
                    }
                }
                TeamsSection()
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color.kervanSidebar)
        .searchable(text: $query, placement: .sidebar, prompt: L("Search conversations", "Konuşmalarda ara"))
        .onChange(of: query) { typing = true }
        .task(id: query) {
            // Wait for a pause in typing before asking the server.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await store.search(query)
            typing = false
        }
        .sheet(isPresented: $newProject) { ProjectSheet().environment(model) }
        .alert(L("Rename session", "Oturumu yeniden adlandır"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(L("Title", "Başlık"), text: $newTitle)
            Button(L("Save", "Kaydet")) {
                if let session = renaming { Task { await store.rename(session.id, title: newTitle) } }
            }
            Button(L("Cancel", "Vazgeç"), role: .cancel) {}
        }
        .toolbar {
            ToolbarItem {
                // A plain button: a menu button here pushes the whole toolbar into overflow on macOS 15.
                // Other agents are in File › New Session and on the overview's split button.
                Button {
                    model.newSession()
                } label: {
                    Label(L("New session", "Yeni oturum"), systemImage: "square.and.pencil")
                }
                .help(L("New session with \(model.defaultAgent?.name ?? "agent") (⌘N)", "\(model.defaultAgent?.name ?? "Ajan") ile yeni oturum (⌘N)"))
                .disabled(!model.canCreateSession)
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 4) {
                SidebarNotices()
                SidebarStatus(state: model.connection.state, host: model.activeAddress?.host ?? model.serverInput)
            }
        }
    }

    @ViewBuilder
    private func menu(for session: SessionInfo) -> some View {
        Button(L("Rename…", "Yeniden adlandır…")) {
            newTitle = session.title
            renaming = session
        }
        Button(session.archived ? L("Unarchive", "Arşivden çıkar") : L("Archive", "Arşivle")) {
            Task { await model.store.setArchived(session.id, !session.archived) }
        }
    }
}

/// Search hits grouped under their session; picking one opens the session at that message.
private struct SearchResults: View {
    let hits: [SearchHit]
    let query: String
    let searching: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        if hits.isEmpty && searching {
            Section(L("Results", "Sonuçlar")) {
                Text(L("Searching…", "Aranıyor…")).foregroundStyle(.secondary)
            }
        } else if hits.isEmpty {
            Section(L("Results", "Sonuçlar")) {
                Text(L("No results for \u{201C}\(query)\u{201D}", "\u{201C}\(query)\u{201D} için sonuç yok")).foregroundStyle(.secondary)
            }
        } else {
            let order = hits.reduce(into: [String]()) { ids, hit in if !ids.contains(hit.sessionId) { ids.append(hit.sessionId) } }
            ForEach(order, id: \.self) { sessionID in
                Section(model.store.session(sessionID)?.title ?? L("Session", "Oturum")) {
                    ForEach(hits.filter { $0.sessionId == sessionID }) { hit in
                        Button {
                            model.open(sessionID: hit.sessionId, at: hit.seq)
                        } label: {
                            HitRow(hit: hit)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private struct HitRow: View {
    let hit: SearchHit

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(hit.role == .user ? L("You", "Siz") : L("Agent", "Ajan"))
                .font(.caption2)
                .foregroundStyle(.secondary)
            hit.parts.reduce(Text("")) { text, part in
                text + (part.matched ? Text(part.text).bold().foregroundColor(.kervanLapis) : Text(part.text))
            }
            .font(.callout)
            .lineLimit(3)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct SessionRow: View {
    let session: SessionInfo
    @Environment(AppModel.self) private var model
    private var agentName: String { model.store.agentName(session.agent) }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            StatusDot(color: session.status.tint)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(session.title)
                        .lineLimit(1)
                    if session.orchestrate {
                        Image(systemName: "flag.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.kervanSaffron)
                            .help(L("Lead: can start helpers", "Ana ajan: yardımcı başlatabilir"))
                            .accessibilityLabel(L("lead", "ana ajan"))
                    }
                }
                Text("\(agentName), \(session.status.label.lowercased())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct SidebarStatus: View {
    let state: ConnectionState
    let host: String

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(state.tint)
                .frame(width: 8, height: 8)
            Text(state.shortLabel)
            Spacer()
            Text(host)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

/// Starts a session with the default agent; with several agents the arrow menu picks another.
struct NewSessionButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let agents = model.store.agents
        let label = L("Start a new session", "Yeni oturum başlat")
        Group {
            if agents.count > 1 {
                Menu {
                    ForEach(agents) { agent in
                        Button(agent.displayName) { model.newSession(agent: agent.id) }
                    }
                } label: {
                    Label(label, systemImage: "square.and.pencil")
                } primaryAction: {
                    model.newSession()
                }
                .help(L("New session with \(model.defaultAgent?.name ?? "agent") (⌘N); use the arrow for another agent", "\(model.defaultAgent?.name ?? "Ajan") ile yeni oturum (⌘N); okla başka bir ajan seçin"))
            } else {
                Button {
                    model.newSession()
                } label: {
                    Label(label, systemImage: "square.and.pencil")
                }
                .help(L("Start a new session (⌘N)", "Yeni oturum başlat (⌘N)"))
            }
        }
        .disabled(!model.canCreateSession)
    }
}
