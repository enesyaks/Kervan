import AppKit
import KervanKit
import SwiftUI

/// The project's branches: the user's own and Kervan's, each against the base, so it's plain where the work is and
/// what still has to be merged. Kervan's rows open their session.
struct ProjectBranchesSection: View {
    let projectID: String
    @Environment(AppModel.self) private var model
    @AppStorage("branches.hideMerged") private var hideMerged = true
    @State private var loading = false
    @State private var error: String?
    @State private var confirmPrune = false
    @State private var showRemote = false

    private var store: SessionStore { model.store }
    private var sessions: [SessionInfo] { store.sessions.filter { $0.projectId == projectID } }
    /// Changes whenever a session here starts, ends a turn or is archived: the branches move then.
    private var refreshKey: String {
        projectID + sessions.map { "\($0.id):\($0.status.rawValue):\($0.archived)" }.joined(separator: ",")
    }

    var body: some View {
        SettingsCard(
            title: L("Branches", "Dallar"),
            footer: L(
                "Every Kervan session works on a branch of its own, so nothing reaches your branches until you merge it. Ahead and behind are counted against the base. The server doesn't fetch from origin by itself, so origin's branches are as git last saw them.",
                "Her Kervan oturumu kendi dalında çalışır; siz birleştirene kadar hiçbir şey sizin dallarınıza girmez. Önde ve geride sayıları ana dala göredir. Sunucu origin'den kendiliğinden çekmez; origin'in dalları git'in en son gördüğü haliyledir."
            )
        ) {
            switch store.projectBranches[projectID] {
            case .none:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L("Reading the branches…", "Dallar okunuyor…")).foregroundStyle(.secondary)
                }
            case .some(.none):
                Text(L(
                    "This project isn't a git repository with a commit yet, so it has no branches. Sessions work in the folder itself.",
                    "Bu proje henüz commit'i olan bir git deposu değil, bu yüzden dalı yok. Oturumlar doğrudan klasörde çalışır."
                ))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            case .some(.some(let branches)):
                content(branches)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Color.kervanCoral)
            }
        }
        .task(id: refreshKey) {
            // A turn that just ended has committed; give it a moment, and don't ask once per status flicker.
            if store.projectBranches[projectID] != nil { try? await Task.sleep(for: .seconds(1)) }
            guard !Task.isCancelled else { return }
            await load()
        }
        .confirmationDialog(L("Delete Kervan's merged branches?", "Kervan'ın birleşmiş dalları silinsin mi?"), isPresented: $confirmPrune) {
            Button(L("Delete", "Sil"), role: .destructive) {
                Task {
                    loading = true
                    defer { loading = false }
                    error = await store.pruneBranches(projectID)
                }
            }
        } message: {
            Text(L(
                "Only kervan/… branches whose work is already in the folder's branch, and that no session still in use or worktree has. Their commits stay in the branch they were merged into.",
                "Yalnızca işi klasörün dalına zaten girmiş, hâlâ kullanılan bir oturumun ya da worktree'nin tutmadığı kervan/… dalları. Commit'leri birleştikleri dalda kalır."
            ))
        }
    }

    @ViewBuilder
    private func content(_ branches: ProjectBranches) -> some View {
        let kervan = branches.kervan(hidingMerged: hideMerged)
        let scale = ProjectBranches.scale(branches.own + kervan)
        header(branches)

        group(L("Your branches", "Sizin dallarınız"), count: branches.own.count) {
            ForEach(branches.own) { branch in
                BranchRow(branch: branch, scale: scale, base: branches.base, badge: nil, open: nil)
            }
        }

        Divider()

        group(L("Kervan's branches", "Kervan'ın dalları"), count: branches.kervan().count) {
            Toggle(L("Hide merged", "Birleşmişleri gizle"), isOn: $hideMerged)
                .toggleStyle(.checkbox)
                .controlSize(.small)
        } rows: {
            if kervan.isEmpty {
                Text(branches.kervan().isEmpty
                    ? L("None yet. A session in this project gets one when it starts.", "Henüz yok. Bu projedeki bir oturum başlayınca kendi dalını alır.")
                    : L("All of them are merged.", "Hepsi birleşmiş."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                CappedScroll(maxHeight: 360) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(kervan) { branch in
                            let session = branch.sessionId.flatMap { id in store.sessions.first { $0.id == id } }
                            BranchRow(
                                branch: branch,
                                scale: scale,
                                base: branches.base,
                                badge: BranchBadge(branch: branch, session: session, card: card(of: session), node: node(of: session)),
                                title: session?.title,
                                open: session.map { session in { model.selectedSessionID = session.id } }
                            )
                        }
                    }
                }
            }
        }

        if !branches.remoteOnly.isEmpty {
            DisclosureGroup(isExpanded: $showRemote) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(branches.remoteOnly) { branch in
                        BranchRow(branch: branch, scale: scale, base: branches.base, badge: nil, open: nil)
                    }
                }
            } label: {
                Text(L("Only on origin (\(branches.remoteOnly.count))", "Yalnızca origin'de (\(branches.remoteOnly.count))"))
                    .font(.callout.weight(.medium))
            }
        }

        if branches.truncated == true {
            Text(L("Showing the newest branches only.", "Yalnızca en yeni dallar gösteriliyor."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if let deleted = store.prunedBranches[projectID] {
            Label(L("Deleted \(deleted.count) merged branches.", "\(deleted.count) birleşmiş dal silindi."), systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(Color.kervanOasis)
                .help(deleted.joined(separator: "\n"))
        }
        if branches.mergedKervanCount > 0 {
            Button(L("Delete Kervan's merged branches…", "Kervan'ın birleşmiş dallarını temizle…")) { confirmPrune = true }
                .buttonStyle(.link)
                .disabled(loading || !model.connection.state.isConnected)
        }
    }

    private func header(_ branches: ProjectBranches) -> some View {
        HStack(spacing: 10) {
            Label {
                Text(branches.current ?? L("detached", "dalsız"))
                    .font(.callout.monospaced().weight(.semibold))
            } icon: {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(Color.kervanLapis)
            }
            .help(L("The branch the project folder is on.", "Proje klasörünün açık olduğu dal."))
            Text(summary(branches)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if loading { ProgressView().controlSize(.small) }
            Button {
                Task { await load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(loading || !model.connection.state.isConnected)
            .help(L("Read the branches again", "Dalları yeniden oku"))
        }
    }

    private func summary(_ branches: ProjectBranches) -> String {
        var parts: [String] = []
        if branches.current != branches.base { parts.append(L("base \(branches.base)", "ana dal \(branches.base)")) }
        let working = branches.workingCount(sessions: sessions)
        if working > 0 { parts.append(L("\(working) working", "\(working) çalışıyor")) }
        let open = branches.kervan().filter { !$0.merged }.count
        if open > 0 { parts.append(L("\(open) to merge", "\(open) birleşmeyi bekliyor")) }
        if branches.mergedKervanCount > 0 { parts.append(L("\(branches.mergedKervanCount) merged", "\(branches.mergedKervanCount) birleşti")) }
        return parts.joined(separator: " · ")
    }

    private func group<Rows: View>(_ title: String, count: Int, @ViewBuilder rows: () -> Rows) -> some View {
        group(title, count: count, accessory: { EmptyView() }, rows: rows)
    }

    private func group<Accessory: View, Rows: View>(_ title: String, count: Int, @ViewBuilder accessory: () -> Accessory, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.callout.weight(.medium))
                Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                accessory()
            }
            rows()
        }
    }

    private func card(of session: SessionInfo?) -> CardInfo? {
        guard let session else { return nil }
        return store.boards[projectID]?.first { $0.sessionId == session.id }
    }

    private func node(of session: SessionInfo?) -> String? {
        guard let session else { return nil }
        return store.agents.first { $0.id == session.agent }?.node
    }

    private func load() async {
        loading = true
        defer { loading = false }
        error = await store.loadBranches(projectID)
    }
}

/// One branch: its name and state, its last commit, and how far it is ahead of and behind the base.
private struct BranchRow: View {
    let branch: BranchInfo
    let scale: Int
    let base: String
    let badge: BranchBadge?
    var title: String?
    let open: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(iconTint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(branch.name)
                        .font(.callout.monospaced().weight(branch.isCurrent || branch.isBase ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if branch.isCurrent { Chip(text: L("Checked out", "Açık"), tint: .kervanLapis) }
                    if branch.worktree == true, badge == nil { Chip(text: L("In a worktree", "Worktree'de"), tint: .secondary) }
                    if let badge { Chip(text: badge.title, tint: tint(badge)) }
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(branch.subject)
            }
            Spacer(minLength: 8)
            if !branch.isBase {
                DivergenceBar(ahead: branch.ahead, behind: branch.behind, scale: scale, base: base)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering && open != nil ? Color.kervanWell : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { open?() }
        .contextMenu {
            if let open { Button(L("Open the Session", "Oturumu aç"), action: open) }
            Button(L("Copy Branch Name", "Dal adını kopyala")) { copy(branch.name) }
            Button(L("Copy Commit", "Commit'i kopyala")) { copy(branch.head) }
        }
        .help(open == nil ? "" : L("Open the session that works on this branch", "Bu dalda çalışan oturumu aç"))
    }

    private var detail: String {
        var parts: [String] = []
        if let title, !title.isEmpty { parts.append(title) }
        parts.append(branch.subject.isEmpty ? String(branch.head.prefix(7)) : branch.subject)
        if let date = branch.commitDate { parts.append(Self.relative.localizedString(for: date, relativeTo: Date())) }
        if !branch.isKervan, !branch.author.isEmpty { parts.append(branch.author) }
        return parts.joined(separator: " · ")
    }

    private var icon: String {
        if branch.isBase { return "star.fill" }
        if branch.isRemote { return "cloud" }
        if branch.fromNode != nil { return "arrow.down.circle" }
        if branch.isKervan { return branch.merged ? "checkmark.circle" : "sparkles" }
        return "arrow.triangle.branch"
    }

    private var iconTint: Color {
        if branch.isBase { return .kervanSaffron }
        if branch.isKervan { return branch.merged ? .kervanOasis : .kervanLapis }
        return .secondary
    }

    private func tint(_ badge: BranchBadge) -> Color {
        switch badge {
        case .working, .onNode: .kervanLapis
        case .waiting: .kervanSaffron
        case .review, .ready, .merged: .kervanOasis
        case .saved: .kervanCoral
        case .archived, .noSession: .secondary
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

private struct Chip: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(tint)
            .background(Capsule().fill(tint.opacity(0.14)))
            .lineLimit(1)
            .fixedSize()
    }
}

/// Behind on the left, ahead on the right, from a line in the middle: GitHub's way of showing how a branch diverged.
/// Bars grow with the logarithm, so one branch hundreds of commits off doesn't flatten the rest.
private struct DivergenceBar: View {
    let ahead: Int
    let behind: Int
    let scale: Int
    let base: String

    var body: some View {
        HStack(spacing: 4) {
            Text(behind > 0 ? "\(behind)" : "")
                .frame(width: 30, alignment: .trailing)
            HStack(spacing: 1) {
                bar(behind, alignment: .trailing, color: Color.secondary.opacity(0.45))
                Rectangle().fill(Color.kervanHairline).frame(width: 1, height: 14)
                bar(ahead, alignment: .leading, color: .kervanLapis)
            }
            .frame(width: 100)
            Text(ahead > 0 ? "\(ahead)" : "")
                .frame(width: 30, alignment: .leading)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .help(L("\(behind) behind and \(ahead) ahead of \(base)", "\(base) dalının \(behind) commit gerisinde, \(ahead) commit önünde"))
    }

    private func bar(_ count: Int, alignment: Alignment, color: Color) -> some View {
        GeometryReader { proxy in
            let share = count == 0 ? 0 : log1p(Double(count)) / log1p(Double(max(scale, 1)))
            Capsule()
                .fill(color)
                .frame(width: count == 0 ? 0 : max(3, proxy.size.width * share), height: 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        }
        .frame(height: 14)
    }
}
