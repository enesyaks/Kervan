import KervanKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            Group {
                if case .connected(let server) = model.connection.state {
                    ConnectedView(server: server)
                } else {
                    ConnectView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section("Oturumlar") {
                Text("Henüz oturum yok").foregroundStyle(.secondary)
            }
            Section("Takımlar") {
                Text("Henüz takım yok").foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            SidebarStatus(state: model.connection.state, host: model.activeAddress?.host ?? model.serverInput)
        }
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
