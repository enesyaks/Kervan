import KervanKit
import SwiftUI

/// Moves a project session from a node to the server: the session's branch holds the node's work up to its last
/// finished turn, and an agent here picks it up with the conversation so far.
struct TakeoverSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let sessionID: String

    @State private var agent = ""
    @State private var failure: String?
    @State private var working = false

    private var session: SessionInfo? { model.store.session(sessionID) }
    private var node: String { model.store.agents.first { $0.id == session?.agent }?.node ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Continue on the server", "Sunucuda devam et")).font(.title3.weight(.semibold))
            Text(L(
                "The work \(node) sent after each turn is on branch \(session?.branch ?? ""). An agent on the server picks it up there, in a worktree of its own, and gets the conversation so far with your next message. Anything from a turn \(node) didn't finish is missing; if \(node) comes back with it, it's kept as a separate branch.",
                "\(node) her turdan sonra gönderdiği işi \(session?.branch ?? "") dalında tutuyor. Sunucudaki bir ajan işi orada, kendi worktree'sinde devralır ve bir sonraki mesajınızla birlikte o ana kadarki konuşmayı alır. \(node) makinesinin bitiremediği bir turdaki iş eksik olur; \(node) geri dönüp onu getirirse ayrı bir dal olarak saklanır."
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if model.store.takeoverAgents.isEmpty {
                Text(L("This server has no agent to continue with. Add one in Settings.", "Bu sunucuda devam edecek bir ajan yok. Ayarlar'dan ekleyebilirsiniz."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker(L("Agent", "Ajan"), selection: $agent) {
                    ForEach(model.store.takeoverAgents) { Text($0.name).tag($0.id) }
                }
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Color.kervanCoral)
            }
            HStack {
                Spacer()
                Button(L("Cancel", "Vazgeç"), role: .cancel) { dismiss() }
                    .buttonStyle(.kervanQuiet)
                    .keyboardShortcut(.cancelAction)
                Button(L("Continue on the Server", "Sunucuda Devam Et")) {
                    Task {
                        working = true
                        defer { working = false }
                        if let refusal = await model.store.continueOnServer(sessionID, agent: agent.isEmpty ? nil : agent) {
                            failure = refusal
                        } else {
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.kervanPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(working || agent.isEmpty || session?.status == .running || session?.status == .waiting)
            }
        }
        .padding(22)
        .frame(width: 440)
        .background(Color.kervanCanvas)
        .onAppear { agent = model.store.takeoverAgents.first?.id ?? "" }
    }
}
