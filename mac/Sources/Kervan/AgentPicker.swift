import KervanKit
import SwiftUI

/// Where the work runs and which agent does it. With only this server it's the agent menu; with nodes,
/// pick the machine first and then one of the agents on it.
struct AgentPicker: View {
    @Environment(AppModel.self) private var model
    @Binding var agent: String
    /// For work tied to a project, which only this server has.
    var serverOnly = false
    /// The machine picked, kept apart from the agent because a node may not have any agents yet.
    @State private var picked: String?

    private var places: [AgentPlace] {
        AgentPlace.all(agents: model.store.agents, nodes: model.store.nodeInfos)
    }

    private var placeID: String {
        picked ?? model.store.agents.first { $0.id == agent }?.node ?? AgentPlace.serverID
    }

    private var place: AgentPlace? {
        serverOnly ? places.first : places.first { $0.id == placeID }
    }

    var body: some View {
        if !serverOnly && places.count > 1 {
            Picker(selection: Binding(get: { placeID }, set: { choose($0) })) {
                ForEach(places) { Text($0.label).tag($0.id) }
            } label: {
                Text(L("Machine", "Makine"))
                Text(L("Where the work runs.", "İşin yapılacağı yer."))
            }
        }
        if let place, place.agents.isEmpty {
            Text(L("No agents on this machine yet. Add one in Settings.", "Bu makinede henüz ajan yok. Ayarlar'dan ekleyebilirsiniz."))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Picker(L("Agent", "Ajan"), selection: $agent) {
                ForEach(place?.agents ?? []) { Text($0.name).tag($0.id) }
            }
        }
        if let place, !place.online {
            Text(L("This machine is asleep or offline, so nothing can start on it now.", "Bu makine uykuda ya da çevrimdışı; şu an üzerinde iş başlatılamaz."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func choose(_ id: String) {
        picked = id
        agent = places.first { $0.id == id }?.agents.first?.id ?? ""
    }
}
