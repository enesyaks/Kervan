import KervanKit
import SwiftUI

/// Hands one task from a lead's chat to an agent somewhere else, as a helper.
///
/// It asks the lead rather than starting the helper behind its back: a helper the lead doesn't know about
/// would answer into a conversation nobody is reading. So the sheet writes the request as a message from
/// the user, the lead starts the helper with its own tools, and the whole exchange stays in this chat.
struct HandOffSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let sessionID: String

    @State private var agent = ""
    @State private var task = ""
    @FocusState private var writing: Bool

    private var chosen: AgentInfo? {
        model.store.agents.first { $0.id == agent }
    }

    /// Where that agent lives, for the message and for the warning about files.
    private var place: (english: String, turkish: String)? {
        guard let node = chosen?.node else { return nil }
        return ("on \(node)", "\(node) üzerinde")
    }

    private var places: Int {
        AgentPlace.all(agents: model.store.agents, nodes: model.store.nodeInfos).count
    }

    /// The lead has to be free to read the request; a turn in flight would swallow it.
    private var canSend: Bool {
        model.store.session(sessionID)?.status == .idle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Hand a task to another agent", "Görevi başka bir ajana ver"))
                    .font(.title3.weight(.semibold))
                Text(L(
                    "The agent in this chat starts it as a helper and tells you what comes back. Helpers show up under this session in the sidebar.",
                    "Bu sohbetteki ajan onu bir yardımcı olarak başlatır ve dönen cevabı size aktarır. Yardımcılar kenar çubuğunda bu oturumun altında görünür."
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding([.horizontal, .top], 22)
            .padding(.bottom, 10)

            Form {
                AgentPicker(agent: $agent)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(height: places > 1 ? 104 : 64)

            VStack(alignment: .leading, spacing: 6) {
                Text(L("Task", "Görev"))
                TextEditor(text: $task)
                    .focused($writing)
                    .font(.body)
                    .frame(height: 110)
                    .overlay(RoundedRectangle(cornerRadius: Radius.chip).strokeBorder(Color.secondary.opacity(0.25)))
                if place != nil {
                    Text(L(
                        "That machine has files of its own, so the helper can't see this folder: put everything it needs in the task.",
                        "O makinenin dosyaları ayrı, yani yardımcı bu klasörü göremez: ihtiyacı olan her şeyi göreve yazın."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if !canSend {
                    Text(L("The agent is answering; it can take this once it's done.", "Ajan şu an yanıtlıyor; bitince alabilir."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 22)

            Spacer(minLength: 14)
            Divider()
            HStack {
                Spacer()
                Button(L("Cancel", "Vazgeç")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Hand it over", "Görevi ver")) { handOver() }
                    .buttonStyle(.borderedProminent)
                    .tint(.kervanLapis)
                    .keyboardShortcut(.defaultAction)
                    .disabled(agent.isEmpty || task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !canSend)
            }
            .padding(14)
        }
        .frame(width: 520)
        .background(Color.kervanCanvas)
        .onAppear {
            if agent.isEmpty { agent = model.store.session(sessionID)?.agent ?? model.store.agents.first?.id ?? "" }
            writing = true
        }
    }

    private func handOver() {
        guard let chosen else { return }
        let text = HandOff.message(agentName: chosen.name, node: chosen.node, task: task)
        dismiss()
        Task { await model.store.prompt(sessionID, text: text, attachments: []) }
    }
}
