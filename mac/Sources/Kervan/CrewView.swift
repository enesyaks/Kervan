import KervanKit
import SwiftUI

/// Every member of a team (or a lead and its helpers) side by side, under a strip of who handed what to whom.
struct CrewView: View {
    let crew: Crew
    let selected: String
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.store
        let members = crew.members.compactMap { store.session($0.id) }
        let working = members.filter { [.starting, .running, .waiting].contains($0.status) }.count

        VStack(spacing: 0) {
            FlowStrip(items: Flow.build(members, events: store.events), name: name)
            Divider()
            GeometryReader { geometry in
                let gap: CGFloat = 12
                let fit = (geometry.size.width - 32 - gap * CGFloat(members.count - 1)) / CGFloat(max(members.count, 1))
                // The first member blocked on an approval is the one that needs the user; keep it in view.
                let waiting = members.first { $0.status == .waiting }?.id
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: gap) {
                            ForEach(members) { member in
                                MemberPanel(session: member, isSelected: member.id == selected, name: name)
                                    .frame(width: max(fit, 280))
                                    .id(member.id)
                            }
                        }
                        .padding(16)
                        .frame(height: geometry.size.height)
                    }
                    .onAppear { if let waiting { proxy.scrollTo(waiting) } }
                    .onChange(of: waiting) { _, id in
                        if let id { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id) } }
                    }
                }
            }
        }
        .navigationTitle(crew.title)
        .navigationSubtitle(
            [
                working == 0 ? "\(members.count) ajan, hepsi boşta" : "\(members.count) ajan, \(working) çalışıyor",
                members.first(where: { $0.orchestrate }).flatMap(store.costSummary),
            ]
            .compactMap { $0 }
            .joined(separator: ", ")
        )
        .toolbar {
            ToolbarItem {
                Button {
                    model.showCrew = false
                } label: {
                    Label("Tek oturum", systemImage: "rectangle")
                }
                .help("Seçili oturuma dön (⌥⌘T)")
                .keyboardShortcut("t", modifiers: [.command, .option])
            }
        }
    }

    private func name(_ sessionID: String) -> String {
        guard let session = model.store.session(sessionID) else { return "Ajan" }
        return session.role ?? session.title
    }
}

/// The route along the top: each hand-off is a stop. Newest on the right; picking one opens that message.
private struct FlowStrip: View {
    let items: [FlowItem]
    let name: (String) -> String
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if items.isEmpty {
                Text("Henüz görev alışverişi yok. Ana ajan yardımcıya iş verdiğinde burada görünür.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                    .padding(.horizontal, 16)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 10) {
                            ForEach(items) { item in
                                Button {
                                    model.focus = (item.sessionID, item.seq)
                                    model.selectedSessionID = item.sessionID
                                    model.showCrew = false
                                } label: {
                                    FlowStop(item: item, name: name)
                                }
                                .buttonStyle(.plain)
                                .help("Bu mesajı aç")
                                .id(item.id)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(alignment: .center) {
                            // The caravan's route, running through every stop.
                            Rectangle()
                                .fill(Color.kervanLapis.opacity(0.25))
                                .frame(height: 1)
                                .padding(.horizontal, 16)
                        }
                    }
                    .scrollIndicators(.never)
                    .onAppear { proxy.scrollTo(items.last?.id, anchor: .trailing) }
                    .onChange(of: items.last?.id) { _, last in
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .trailing) }
                    }
                }
            }
        }
        .background(Color.kervanCanvas)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Akış şeridi")
    }
}

private struct FlowStop: View {
    let item: FlowItem
    let name: (String) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(headline, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
            if !item.text.isEmpty {
                Text(item.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: 240, alignment: .leading)
        .softSurface(radius: Radius.chip, lift: false)
        .overlay(
            RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                .strokeBorder(tint.opacity(item.kind == .waiting ? 0.7 : 0), lineWidth: 1.5)
        )
        .accessibilityElement(children: .combine)
    }

    private var headline: String {
        let who = name(item.sessionID)
        return switch item.kind {
        case .assigned(let from): "\(name(from)) → \(who)"
        case .userWrote: "Siz → \(who)"
        case .replied: "\(who) yanıtladı"
        case .waiting: "\(who) onay bekliyor"
        case .failed: "\(who): hata"
        }
    }

    private var symbol: String {
        switch item.kind {
        case .assigned: "flag.fill"
        case .userWrote: "person.fill"
        case .replied: "arrowshape.turn.up.left.fill"
        case .waiting: "hand.raised.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch item.kind {
        case .assigned, .waiting: .kervanSaffron
        case .userWrote: .kervanLapis
        case .replied: .kervanOasis
        case .failed: .red
        }
    }
}

/// One member's conversation, live. Approvals can be answered here without leaving the view.
private struct MemberPanel: View {
    let session: SessionInfo
    let isSelected: Bool
    let name: (String) -> String
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.store
        let items = store.transcript(for: session.id)
        let agentName = store.agentName(session.agent)

        VStack(spacing: 0) {
            header(agentName: agentName)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if items.isEmpty {
                            Text(session.status == .starting ? "\(agentName) başlatılıyor…" : "Henüz mesaj yok.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(items) { item in
                            TranscriptRow(
                                item: item,
                                agentName: agentName,
                                senderName: name,
                                terminal: store.isTerminal(session.id),
                                resume: item.id == Transcript.resumable(items) && session.status == .idle
                                    ? { Task { await store.resume(session.id) } }
                                    : nil
                            ) { requestId, choice in
                                Task { await store.respond(session.id, requestId: requestId, optionId: choice.optionId) }
                            }
                            .font(.callout)
                            .id(item.id)
                        }
                        if session.status == .running {
                            HStack(spacing: 6) {
                                CaravanDots()
                                Text("yanıtlıyor…").font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(12)
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: items.count) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: session.status) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .softSurface(radius: Radius.panel)
        .overlay(
            RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
                .strokeBorder(border, lineWidth: 1.5)
        )
        .shadow(color: session.status == .waiting ? Color.kervanSaffron.opacity(0.25) : .clear, radius: 12)
    }

    private var border: Color {
        if session.status == .waiting { return .kervanSaffron.opacity(0.6) }
        return isSelected ? .kervanLapis.opacity(0.45) : .clear
    }

    private func header(agentName: String) -> some View {
        HStack(spacing: 8) {
            if session.parentId != nil {
                Image(systemName: "arrow.turn.down.right").foregroundStyle(Color.kervanSaffron)
            } else if session.orchestrate {
                Image(systemName: "flag.fill").foregroundStyle(Color.kervanSaffron)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(session.role ?? session.title).font(.headline).lineLimit(1)
                HStack(spacing: 5) {
                    StatusDot(color: session.status.tint, size: 6)
                    Text(
                        ["\(agentName), \(session.status.label.lowercased())", session.usage?.costUsd.map(usd)]
                            .compactMap { $0 }
                            .joined(separator: ", ")
                    )
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let branch = session.branch {
                    BranchLabel(branch: branch)
                }
            }
            Spacer()
            Button {
                model.selectedSessionID = session.id
                model.showCrew = false
            } label: {
                Label("Aç", systemImage: "arrow.up.left.and.arrow.down.right")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Bu oturumu tek başına aç")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }
}
