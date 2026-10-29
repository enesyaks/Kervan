import AppKit
import KervanKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            Group {
                if !model.isLinked || model.connection.state.isFailed {
                    ConnectView()
                } else if let id = model.selectedSessionID, model.store.session(id) != nil {
                    ChatView(sessionID: id).id(id)
                } else {
                    OverviewView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .sheet(isPresented: Binding(get: { model.newSessionAgent != nil }, set: { if !$0 { model.newSessionAgent = nil } })) {
            if let agent = model.newSessionAgent {
                NewSessionSheet(agent: agent).environment(model)
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

    var body: some View {
        @Bindable var model = model
        let store = model.store
        let (groups, archived) = SessionGroups.group(store.sessions, lastActivity: { store.lastActivity($0.id) })
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty

        List(selection: $model.selectedSessionID) {
            if searching {
                SearchResults(hits: store.searchHits, query: query, searching: typing || store.isSearching)
            } else {
                if groups.isEmpty {
                    Section("Oturumlar") {
                        Text("Henüz oturum yok").foregroundStyle(.secondary)
                    }
                }
                ForEach(groups) { group in
                    Section(group.title) {
                        ForEach(group.sessions) { session in
                            SessionRow(session: session).tag(session.id).contextMenu { menu(for: session) }
                        }
                    }
                }
                if !archived.isEmpty {
                    Section(isExpanded: $showArchive) {
                        ForEach(archived) { session in
                            SessionRow(session: session).tag(session.id).contextMenu { menu(for: session) }
                        }
                    } header: {
                        Text("Arşiv (\(archived.count))")
                    }
                }
                Section("Takımlar") {
                    Text("Henüz takım yok").foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $query, placement: .sidebar, prompt: "Konuşmalarda ara")
        .onChange(of: query) { typing = true }
        .task(id: query) {
            // Wait for a pause in typing before asking the server.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await store.search(query)
            typing = false
        }
        .alert("Oturumu yeniden adlandır", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Başlık", text: $newTitle)
            Button("Kaydet") {
                if let session = renaming { Task { await store.rename(session.id, title: newTitle) } }
            }
            Button("Vazgeç", role: .cancel) {}
        }
        .toolbar {
            ToolbarItem {
                // A plain button: a menu button here pushes the whole toolbar into overflow on macOS 15.
                // Other agents are in File › New Session and on the overview's split button.
                Button {
                    model.newSession()
                } label: {
                    Label("Yeni oturum", systemImage: "square.and.pencil")
                }
                .help("\(model.defaultAgent?.name ?? "Ajan") ile yeni oturum (⌘N)")
                .disabled(!model.canCreateSession)
            }
        }
        .safeAreaInset(edge: .bottom) {
            SidebarStatus(state: model.connection.state, host: model.activeAddress?.host ?? model.serverInput)
        }
    }

    @ViewBuilder
    private func menu(for session: SessionInfo) -> some View {
        Button("Yeniden adlandır…") {
            newTitle = session.title
            renaming = session
        }
        Button(session.archived ? "Arşivden çıkar" : "Arşivle") {
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
            Section("Sonuçlar") {
                Text("Aranıyor…").foregroundStyle(.secondary)
            }
        } else if hits.isEmpty {
            Section("Sonuçlar") {
                Text("\u{201C}\(query)\u{201D} için sonuç yok").foregroundStyle(.secondary)
            }
        } else {
            let order = hits.reduce(into: [String]()) { ids, hit in if !ids.contains(hit.sessionId) { ids.append(hit.sessionId) } }
            ForEach(order, id: \.self) { sessionID in
                Section(model.store.session(sessionID)?.title ?? "Oturum") {
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
            Text(hit.role == .user ? "Siz" : "Ajan")
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
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(session.status.tint)
                .frame(width: 7, height: 7)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .lineLimit(1)
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
        let label = "Yeni oturum başlat"
        Group {
            if agents.count > 1 {
                Menu {
                    ForEach(agents) { agent in
                        Button(agent.name) { model.newSession(agent: agent.id) }
                    }
                } label: {
                    Label(label, systemImage: "square.and.pencil")
                } primaryAction: {
                    model.newSession()
                }
                .help("\(model.defaultAgent?.name ?? "Ajan") ile yeni oturum (⌘N); okla başka bir ajan seçin")
            } else {
                Button {
                    model.newSession()
                } label: {
                    Label(label, systemImage: "square.and.pencil")
                }
                .help("Yeni oturum başlat (⌘N)")
            }
        }
        .disabled(!model.canCreateSession)
    }
}
