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
        .onChange(of: model.store.lastCreatedSessionID) { _, created in
            if let created { model.selectedSessionID = created }
        }
    }
}

private struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        List(selection: $model.selectedSessionID) {
            Section("Oturumlar") {
                if model.store.sessions.isEmpty {
                    Text("Henüz oturum yok").foregroundStyle(.secondary)
                }
                ForEach(model.store.sessions) { session in
                    SessionRow(session: session).tag(session.id)
                }
            }
            Section("Takımlar") {
                Text("Henüz takım yok").foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem {
                Button {
                    model.newSession()
                } label: {
                    Label("Yeni oturum", systemImage: "square.and.pencil")
                }
                .help("Yeni oturum başlat (⌘N)")
                .keyboardShortcut("n")
                .disabled(!model.canCreateSession)
            }
        }
        .safeAreaInset(edge: .bottom) {
            SidebarStatus(state: model.connection.state, host: model.activeAddress?.host ?? model.serverInput)
        }
    }
}

private struct SessionRow: View {
    let session: SessionInfo

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(session.status.tint)
                .frame(width: 7, height: 7)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .lineLimit(1)
                Text("\(session.agent.agentDisplayName), \(session.status.label.lowercased())")
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
