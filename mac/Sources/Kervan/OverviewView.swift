import AppKit
import KervanKit
import SwiftUI

/// Home, shown when connected (or briefly reconnecting) and no session is selected: what needs you first,
/// then what is on the road, then where you left off.
struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let state = model.connection.state
        let host = model.activeAddress?.host ?? model.serverInput
        let store = model.store
        // Helpers and team members count too: an approval is an approval, whoever asks.
        let live = store.sessions.filter { !$0.archived }
        let byRecent = live.sorted { store.lastActivity($0.id) > store.lastActivity($1.id) }
        let waiting = byRecent.filter { $0.status == .waiting }
        let stopped = byRecent.filter { $0.status == .error }
        let working = byRecent.filter { $0.status == .running || $0.status == .starting }
        let recent = byRecent.filter { $0.status == .idle && $0.parentId == nil }.prefix(5)

        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                header(state: state, host: host, waiting: waiting.count, working: working.count)

                if live.isEmpty {
                    FirstSession()
                } else {
                    if !waiting.isEmpty {
                        HomeSection(title: L("Waiting for you", "Sıra sizde"), count: waiting.count, tint: .kervanSaffron) {
                            ForEach(waiting) { HomeRow(session: $0, emphasis: .asks) }
                        }
                    }
                    if !stopped.isEmpty {
                        HomeSection(title: L("Stopped", "Duranlar"), count: stopped.count, tint: .kervanCoral) {
                            ForEach(stopped) { HomeRow(session: $0, emphasis: .none) }
                        }
                    }
                    if !working.isEmpty {
                        HomeSection(title: L("On the road", "Yolda"), count: working.count, tint: .kervanLapis) {
                            ForEach(working) { HomeRow(session: $0, emphasis: .none) }
                        }
                    }
                    if !recent.isEmpty {
                        HomeSection(title: L("Pick up where you left off", "Kaldığınız yerden devam edin"), count: nil, tint: .secondary) {
                            ForEach(Array(recent)) { HomeRow(session: $0, emphasis: .none) }
                        }
                    }
                }

                serverCard(state: state, host: host)
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.vertical, 44)
            .frame(maxWidth: .infinity)
        }
        .background(Color.kervanCanvas)
    }

    private func header(state: ConnectionState, host: String, waiting: Int, working: Int) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(Self.greeting())
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                Text(Self.summary(waiting: waiting, working: working, connected: state.isConnected, host: host))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            NewSessionButton()
                .controlSize(.large)
                .fixedSize()
        }
    }

    private func serverCard(state: ConnectionState, host: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            NetworkMap(state: state, host: host, nodes: model.store.nodeInfos)
                .frame(maxWidth: model.store.nodeInfos.isEmpty ? 380 : 460)
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 0) {
                if case .connected(let server) = state {
                    InfoRow(label: L("Server version", "Sunucu sürümü"), value: server.version)
                    Divider().opacity(0.5)
                }
                InfoRow(label: L("Latency", "Gecikme"), value: latencyText)
                Divider().opacity(0.5)
                InfoRow(label: L("Agents", "Ajanlar"), value: model.store.agents.map(\.displayName).joined(separator: ", "))
                Divider().opacity(0.5)
                InfoRow(label: L("Address", "Adres"), value: model.activeAddress?.url.absoluteString ?? "", monospaced: true)
            }
            HStack {
                Text(L("Agents run on the server; work goes on while this Mac sleeps.", "Ajanlar sunucuda çalışır; bu Mac uyurken de iş sürer."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button(L("Disconnect", "Bağlantıyı kes")) { model.disconnect() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .softSurface()
    }

    /// A small human touch: the greeting follows the time of day.
    static func greeting(at date: Date = Date()) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: L("Good morning", "Günaydın")
        case 12..<18: L("Good afternoon", "İyi günler")
        case 18..<23: L("Good evening", "İyi akşamlar")
        default: L("Good night", "İyi geceler")
        }
    }

    /// One sentence under the greeting: the thing to know before reading anything else.
    static func summary(waiting: Int, working: Int, connected: Bool, host: String) -> String {
        guard connected else {
            return host.isEmpty
                ? L("Reconnecting to the server…", "Sunucuya yeniden bağlanıyoruz…")
                : L("Reconnecting to \(host)…", "\(host) sunucusuna yeniden bağlanıyoruz…")
        }
        switch (waiting, working) {
        case (0, 0): return L("All quiet on \(host). Nothing needs you.", "\(host) sakin. Sizi bekleyen bir şey yok.")
        case (0, _): return L("\(working) at work on \(host). Nothing needs you.", "\(host) üzerinde \(working) ajan çalışıyor. Sizi bekleyen bir şey yok.")
        case (_, 0): return waiting == 1
            ? L("One agent is waiting for your approval.", "Bir ajan onayınızı bekliyor.")
            : L("\(waiting) agents are waiting for your approval.", "\(waiting) ajan onayınızı bekliyor.")
        default: return waiting == 1
            ? L("One agent is waiting for your approval; \(working) at work.", "Bir ajan onayınızı bekliyor; \(working) ajan çalışıyor.")
            : L("\(waiting) agents are waiting for your approval; \(working) at work.", "\(waiting) ajan onayınızı bekliyor; \(working) ajan çalışıyor.")
        }
    }

    private var latencyText: String {
        guard let latency = model.connection.latency else { return L("measuring…", "ölçülüyor…") }
        let ms = Double(latency.components.attoseconds) / 1e15 + Double(latency.components.seconds) * 1000
        return ms < 1 ? "<1 ms" : "\(Int(ms.rounded())) ms"
    }
}

/// Nothing has run yet: say what a session is and offer the one thing to do.
private struct FirstSession: View {
    var body: some View {
        HStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Start your first session", "İlk oturumunuzu başlatın"))
                    .font(.headline)
                Text(L("A session is one conversation with an agent in a folder on the server. Start one and it shows up here and in the list on the left.", "Oturum, sunucudaki bir klasörde bir ajanla yaptığınız konuşmadır. Başlattığınızda burada ve soldaki listede görünür."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .softSurface()
    }
}

private struct HomeSection<Rows: View>: View {
    let title: String
    let count: Int?
    let tint: Color
    @ViewBuilder let rows: Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title).font(.headline)
                if let count {
                    Text("\(count)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(tint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(tint.opacity(0.16), in: Capsule())
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            VStack(spacing: 8) { rows }
        }
    }
}

/// One session on the home page; the whole row opens it.
struct HomeRow: View {
    enum Emphasis { case none, asks }

    let session: SessionInfo
    var emphasis: Emphasis = .none
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let store = model.store
        let ask = emphasis == .asks ? pendingAsk : nil
        Button {
            model.selectedSessionID = session.id
        } label: {
            HStack(alignment: .center, spacing: 12) {
                if session.status == .running || session.status == .starting {
                    CaravanDots().frame(width: 22)
                } else {
                    StatusDot(color: session.status.tint).frame(width: 22)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text(detail(store))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let ask {
                        Text(ask)
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 12)
                if emphasis == .asks {
                    Text(L("Review", "İncele"))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.kervanOnAccent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.kervanLapis, in: Capsule())
                } else {
                    if let when = RelativeTime.short(store.lastActivity(session.id)) {
                        Text(when).font(.callout.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .opacity(hovering ? 1 : 0.4)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .softSurface(lift: hovering || emphasis == .asks)
            .overlay(alignment: .leading) {
                if emphasis == .asks {
                    // The saffron edge is the "your turn" mark, the same color as the status everywhere else.
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .fill(Color.kervanSaffron)
                        .mask(alignment: .leading) { Rectangle().frame(width: 4) }
                        .allowsHitTesting(false)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
        .buttonStyle(SoftPressStyle())
        .onHover { hovering = $0 }
        .animation(Motion.fast, value: hovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([session.title, detail(store), ask].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint(L("Opens the session", "Oturumu açar"))
    }

    /// "Claude Code in Kervan website, waiting for you": who, where, and how it stands.
    private func detail(_ store: SessionStore) -> String {
        let agent = store.agentName(session.agent)
        let place = store.project(session.projectId).map { L("\(agent) in \($0.name)", "\($0.name) projesinde \(agent)") } ?? agent
        return [place, session.status.label.lowercased(), store.costSummary(session)].compactMap { $0 }.joined(separator: ", ")
    }

    /// What the agent is asking to do, when the session's history is already here.
    private var pendingAsk: String? {
        for item in model.store.transcript(for: session.id).reversed() {
            if case .permission(_, let prompt) = item, prompt.resolution == nil { return prompt.title }
        }
        return nil
    }
}

private struct InfoRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(monospaced ? .callout.monospaced() : .body)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }
}
