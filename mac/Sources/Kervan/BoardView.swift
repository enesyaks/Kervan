import AppKit
import KervanKit
import SwiftUI

extension CardColumn {
    var title: String {
        switch self {
        case .todo: L("To do", "Yapılacak")
        case .working: L("Working", "Çalışıyor")
        case .needs: L("Needs you", "Sizi bekliyor")
        case .review: L("Review", "İncelenecek")
        case .done: L("Done", "Bitti")
        }
    }

    var tint: Color {
        switch self {
        case .todo: .secondary
        case .working: .kervanSaffron
        case .needs: .kervanCoral
        case .review: .kervanLapis
        case .done: .kervanOasis
        }
    }
}

/// A project's task board: cards hold a prompt; dragging one to Working starts its session, and from then on the
/// server moves the card as the session waits, finishes or is archived.
struct BoardSection: View {
    let projectID: String
    @Environment(AppModel.self) private var model
    @State private var editing: CardDraft?
    @State private var target: CardColumn?

    var body: some View {
        let cards = model.store.boards[projectID] ?? []
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("Board", "Pano")).font(.headline)
                Spacer()
                Button {
                    editing = CardDraft(projectID: projectID, agent: model.store.agents.first { $0.node == nil }?.id ?? "")
                } label: {
                    Label(L("New card", "Yeni kart"), systemImage: "plus")
                }
                .buttonStyle(.kervanQuiet)
                .disabled(!model.connection.state.isConnected || !model.store.agents.contains { $0.node == nil })
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(CardColumn.allCases) { column in
                        lane(column, cards: cards.filter { $0.column == column }.laneOrder())
                    }
                }
                .padding(.bottom, 6)
            }
            .scrollIndicators(.automatic)
            Text(model.store.project(projectID)?.pm?.autoPickup == true
                ? L(
                    "New cards go to the PM at once, two at a time: it plans each, writes the plan on the card, hands the work out and follows it up. A card then moves by itself: Needs you when an agent asks, Review when it's done, Done when you archive the session.",
                    "Yeni kartlar hemen PM'e gider, aynı anda iki tane: PM her birini planlar, planı karta yazar, işi dağıtır ve takip eder. Kart sonra kendiliğinden ilerler: bir ajan bir şey sorunca Sizi bekliyor, iş bitince İncelenecek, oturumu arşivleyince Bitti."
                )
                : L(
                    "Drag a card to Working to start a session with its prompt. It then moves by itself: Needs you when the agent asks, Review when it finishes, Done when you archive the session.",
                    "Bir kartı Çalışıyor'a sürükleyince istemiyle bir oturum başlar. Sonra kendiliğinden ilerler: ajan bir şey sorunca Sizi bekliyor, bitirince İncelenecek, oturumu arşivleyince Bitti."
                ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .task(id: model.connection.state.isConnected) {
            if model.connection.state.isConnected { await model.store.loadBoard(projectID) }
        }
        .sheet(item: $editing) { draft in
            CardSheet(draft: draft).environment(model)
        }
        .sheet(item: choosing) { card in
            if let choice = card.modelChoice {
                ModelChoiceSheet(card: card, choice: choice).environment(model)
            }
        }
    }

    /// The card waiting for its model. The server ends the wait, so the sheet closes when the question goes away, or with the connection.
    private var choosing: Binding<CardInfo?> {
        Binding(
            get: {
                guard model.connection.state.isConnected else { return nil }
                return (model.store.boards[projectID] ?? []).first { $0.modelChoice != nil }
            },
            set: { _ in }
        )
    }

    private func lane(_ column: CardColumn, cards: [CardInfo]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                StatusDot(color: column.tint, size: 7)
                Text(column.title).font(.subheadline.weight(.semibold)).fixedSize()
                Text("\(cards.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                // A card travels left to right; the dotted road to the next lane says so.
                if column != CardColumn.allCases.last {
                    Rectangle()
                        .fill(Color.clear)
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                        .overlay(alignment: .center) {
                            GeometryReader { geometry in
                                Path { path in
                                    path.move(to: CGPoint(x: 0, y: 1))
                                    path.addLine(to: CGPoint(x: geometry.size.width, y: 1))
                                }
                                .stroke(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [1.5, 5]))
                            }
                        }
                        .accessibilityHidden(true)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                } else {
                    Spacer()
                }
            }
            .padding(.horizontal, 4)
            ForEach(cards) { card in
                CardTile(card: card, edit: { editing = CardDraft(card) })
            }
            if cards.isEmpty {
                RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                    .strokeBorder(Color.primary.opacity(target == column ? 0.35 : 0.1), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .frame(height: 56)
                    .overlay {
                        Text(L("Drop a card here", "Kartı buraya bırakın")).font(.caption).foregroundStyle(.tertiary)
                    }
            }
        }
        .padding(10)
        // The five lanes share the width; below 180 points each the board scrolls sideways instead.
        .containerRelativeFrame(.horizontal) { length, _ in max(180, (length - 4 * 12) / 5) }
        .frame(minHeight: 140, alignment: .top)
        .background(
            (target == column ? column.tint.opacity(0.10) : Color.kervanWell.opacity(0.6)),
            in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        )
        .animation(Motion.fast, value: target)
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first, let card = (model.store.boards[projectID] ?? []).first(where: { $0.id == id }), card.column != column else { return false }
            Task {
                if let failure = await model.store.moveCard(id, to: column) { model.store.lastError = failure }
            }
            return true
        } isTargeted: { inside in
            target = inside ? column : (target == column ? nil : target)
        }
    }
}

/// One card: what it asks for, which agent, and, once started, its session's state with a way to open it.
private struct CardTile: View {
    let card: CardInfo
    let edit: () -> Void
    @Environment(AppModel.self) private var model

    /// Handled by the project's PM: started by it, or waiting for it.
    private var byPM: Bool {
        if card.sessionId != nil { return card.pm == true }
        return card.direct != true && model.store.project(card.projectId)?.pm.map { pm in model.store.roles.contains { $0.id == pm.roleId } } == true
    }

    var body: some View {
        let session = card.sessionId.flatMap { id in model.store.sessions.first { $0.id == id } }
        VStack(alignment: .leading, spacing: 6) {
            if let origin = card.openedBy {
                HStack(spacing: 4) {
                    Text(origin.title)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .foregroundStyle(origin.kind == .security ? Color.kervanCoral : origin.kind == .fix ? Color.kervanSaffron : Color.kervanLapis)
                        .background((origin.kind == .security ? Color.kervanCoral : origin.kind == .fix ? Color.kervanSaffron : Color.kervanLapis).opacity(0.14), in: Capsule())
                    Text(L("Opened by the PM", "PM açtı")).font(.caption2).foregroundStyle(.secondary)
                }
                .help(origin.reason)
            }
            Text(card.title).font(.callout.weight(.semibold)).lineLimit(2)
            if let origin = card.openedBy {
                Text(origin.reason).font(.caption2).foregroundStyle(.secondary).lineLimit(2).help(origin.reason)
            }
            Text(card.prompt).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            if let files = card.files, !files.isEmpty {
                Label(files.map(CardInfo.fileName).joined(separator: ", "), systemImage: "paperclip")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let plan = card.plan, !plan.isEmpty {
                Text(plan)
                    .font(.caption2)
                    .lineLimit(4)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.kervanWell.opacity(0.7), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .help(plan)
            }
            if let sessionID = card.sessionId, card.pm == true {
                let helpers = model.store.helpers(of: sessionID)
                if !helpers.isEmpty {
                    Label(helpers.map(\.title).joined(separator: ", "), systemImage: "person.2")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            if let error = card.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(Color.kervanCoral)
                    .lineLimit(3)
            }
            HStack(spacing: 6) {
                Text(byPM ? L("PM", "PM") : model.store.agentName(card.agent))
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(byPM ? Color.kervanLapis.opacity(0.18) : Color.kervanWell, in: Capsule())
                Spacer(minLength: 0)
                if let session {
                    StatusDot(color: session.status.tint, size: 6)
                    Button(L("Open", "Aç")) { model.selectedSessionID = session.id }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .softSurface(radius: Radius.chip)
        .contentShape(Rectangle())
        .draggable(card.id) {
            Text(card.title).font(.callout.weight(.semibold)).padding(8).softSurface(radius: Radius.chip)
        }
        .onTapGesture(count: 2) {
            if let session { model.selectedSessionID = session.id } else { edit() }
        }
        .contextMenu {
            if card.sessionId == nil {
                Button(L("Start", "Başlat")) { move(.working) }
                Button(L("Edit…", "Düzenle…"), action: edit)
            }
            Menu(L("Move to", "Taşı")) {
                ForEach(CardColumn.allCases.filter { $0 != card.column && !(card.sessionId != nil && $0 == .todo) }) { column in
                    Button(column.title) { move(column) }
                }
            }
            Divider()
            Button(L("Delete card", "Kartı sil"), role: .destructive) {
                Task { if let failure = await model.store.deleteCard(card.id) { model.store.lastError = failure } }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(card.sessionId == nil ? L("Drag to Working to start it", "Başlatmak için Çalışıyor'a sürükleyin") : L("Double-click to open its session", "Oturumunu açmak için çift tıklayın"))
    }

    private func move(_ column: CardColumn) {
        Task { if let failure = await model.store.moveCard(card.id, to: column) { model.store.lastError = failure } }
    }
}

/// Says which model the card is going on with, and offers the session's default instead.
private struct ModelChoiceSheet: View {
    let card: CardInfo
    let choice: CardModelChoice
    @Environment(AppModel.self) private var model
    @State private var countdown: ClosedRange<Date>
    @State private var sending = false

    init(card: CardInfo, choice: CardModelChoice) {
        self.card = card
        self.choice = choice
        let now = Date()
        _countdown = State(initialValue: now...now.addingTimeInterval(TimeInterval(choice.waitSeconds)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Continuing with \(choice.model)", "\(choice.model) ile devam ediliyor")).font(.title2.weight(.semibold))
            Text(explanation).fixedSize(horizontal: false, vertical: true)
            Text(L("Your default model: \(choice.defaultModel)", "Varsayılan modeliniz: \(choice.defaultModel)"))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text(L("Starts by itself in", "Kendiliğinden başlamasına kalan"))
                Text(timerInterval: countdown, countsDown: true).monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L("Use default model", "Varsayılan modelle devam et")) { answer(useDefault: true) }
                    .disabled(sending)
                Button(L("Continue", "Devam et")) { answer(useDefault: false) }
                    .buttonStyle(.kervanPrimary)
                    .tint(.kervanLapis)
                    .keyboardShortcut(.defaultAction)
                    .disabled(sending)
            }
        }
        .padding(22)
        .frame(width: 420)
        .interactiveDismissDisabled()
    }

    private var explanation: String {
        choice.size == "small"
            ? L("\"\(card.title)\" looks like a small task, so a cheaper model should be enough.", "\"\(card.title)\" küçük bir iş gibi görünüyor, bu yüzden daha ucuz bir model yeterli olmalı.")
            : L("\"\(card.title)\" looks like a routine task, so a cheaper model should be enough.", "\"\(card.title)\" sıradan bir iş gibi görünüyor, bu yüzden daha ucuz bir model yeterli olmalı.")
    }

    private func answer(useDefault: Bool) {
        sending = true
        Task {
            if let failure = await model.store.answerCardModel(card.id, useDefault: useDefault) { model.store.lastError = failure }
            sending = false
        }
    }
}

/// What the card sheet edits: a new card, or one that hasn't started.
struct CardDraft: Identifiable {
    let id = UUID()
    var cardID: String?
    var projectID: String
    var title = ""
    var prompt = ""
    var agent: String
    var split = false
    var autoApprove = false
    var files: [Attachment] = []
    /// In a project with a PM: straight to `agent` instead.
    var direct = false

    init(projectID: String, agent: String) {
        self.projectID = projectID
        self.agent = agent
    }

    init(_ card: CardInfo) {
        cardID = card.id
        projectID = card.projectId
        title = card.title
        prompt = card.prompt
        agent = card.agent
        split = card.split ?? false
        autoApprove = card.autoApprove ?? false
        direct = card.direct ?? false
        files = (card.files ?? []).map { Attachment(name: CardInfo.fileName($0), remotePath: $0, state: .ready) }
    }
}

private struct CardSheet: View {
    @State var draft: CardDraft
    @Environment(AppModel.self) private var model

    /// The project's PM, while its role exists; a card then goes to it unless sent straight to an agent.
    private var pmRole: Role? {
        model.store.project(draft.projectID)?.pm.flatMap { pm in model.store.roles.first { $0.id == pm.roleId } }
    }
    @Environment(\.dismiss) private var dismiss
    @State private var failure: String?
    @State private var saving = false
    @State private var dropTargeted = false
    @State private var pasteMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.cardID == nil ? L("New card", "Yeni kart") : L("Edit card", "Kartı düzenle")).font(.title2.weight(.semibold))
            Form {
                TextField(L("Title", "Başlık"), text: $draft.title, prompt: Text(L("e.g. Add a dark theme", "ör. Koyu tema ekle")))
                if let pm = pmRole {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(L("\(pm.name) plans this card and hands it to the right agent.", "\(pm.name) bu kartı planlar ve doğru ajana verir."), systemImage: "person.crop.circle.badge.checkmark")
                        Toggle(L("Give it straight to an agent instead", "Bunun yerine doğrudan bir ajana ver"), isOn: $draft.direct)
                    }
                }
                if pmRole == nil || draft.direct {
                    AgentPicker(agent: $draft.agent, forProject: true)
                    Toggle(L("Split into helpers when the work is large", "İş büyük olduğunda yardımcılara böl"), isOn: $draft.split)
                }
                Toggle(L("Auto-approve: only ask before major changes", "Otomatik onay: yalnızca büyük değişikliklerde sor"), isOn: $draft.autoApprove)
                    .help(L("Approves routine actions by itself. It still asks before major ones: pushing, deleting folders, rewriting git history, deploying, touching secrets or files outside this task's folder.", "Sıradan işlemleri kendisi onaylar. Büyük işlemlerde yine sorar: push, klasör silme, git geçmişini değiştirme, yayına alma, gizli bilgilere ya da bu görevin klasörü dışındaki dosyalara dokunma."))
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Prompt", "İstem"))
                    TextEditor(text: $draft.prompt).frame(height: 120)
                    Text(L("Sent as the first message when the card moves to Working.", "Kart Çalışıyor'a geçince ilk mesaj olarak gönderilir."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(L("Files", "Dosyalar"))
                        Spacer()
                        Button(L("Add Files…", "Dosya ekle…"), systemImage: "paperclip", action: chooseFiles)
                    }
                    if !draft.files.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(draft.files) { file in
                                    AttachmentChip(attachment: file) { draft.files.removeAll { $0.id == file.id } }
                                }
                            }
                        }
                    }
                    Text(L(
                        "Drop files here or paste a screenshot with ⌘V. They go to the session's uploads folder with the prompt.",
                        "Dosyaları buraya bırakın ya da ekran görüntüsünü ⌘V ile yapıştırın. İstemle birlikte oturumun uploads klasörüne gider."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Color.kervanCoral)
            }
            HStack {
                Spacer()
                Button(L("Cancel", "Vazgeç")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(draft.cardID == nil ? L("Add card", "Kartı ekle") : L("Save", "Kaydet")) { Task { await save() } }
                    .buttonStyle(.kervanPrimary)
                    .tint(.kervanLapis)
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || !draft.files.allSatisfy(\.isReady) || draft.title.trimmingCharacters(in: .whitespaces).isEmpty || draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 480)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.kervanLapis, style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                    .background(Color.kervanLapis.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        Label(L("Drop to add the files to the card.", "Bırakın; dosyalar karta eklenecek."), systemImage: "arrow.down.doc")
                            .font(.headline)
                            .foregroundStyle(Color.kervanLapis)
                    }
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            attach(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .onAppear {
            // ⌘V with a screenshot on the pasteboard adds it to the card; text pastes as usual.
            pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                      event.charactersIgnoringModifiers == "v", let file = PastedImage.take()
                else { return event }
                attach([file])
                return nil
            }
        }
        .onDisappear {
            if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
            pasteMonitor = nil
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = L("Add", "Ekle")
        if panel.runModal() == .OK { attach(panel.urls) }
    }

    /// Uploads each file to the server right away; the card can be saved once all are there.
    private func attach(_ urls: [URL]) {
        guard let client = model.fileClient else { return }
        for url in urls where url.isFileURL {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                failure = L("Folders can't be attached yet: \(url.lastPathComponent)", "Klasörler henüz eklenemiyor: \(url.lastPathComponent)")
                continue
            }
            let file = Attachment(name: url.lastPathComponent, remotePath: "", state: .uploading)
            draft.files.append(file)
            Task {
                let result: (String, Attachment.State)
                do {
                    result = (try await client.uploadCardFile(url, name: url.lastPathComponent), .ready)
                } catch {
                    result = ("", .failed(error.localizedDescription))
                }
                if let index = draft.files.firstIndex(where: { $0.id == file.id }) {
                    draft.files[index].remotePath = result.0
                    draft.files[index].state = result.1
                }
            }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        failure = await model.store.saveCard(CardInput(
            id: draft.cardID, projectId: draft.projectID, title: draft.title, prompt: draft.prompt, agent: draft.agent, split: draft.split, autoApprove: draft.autoApprove,
            files: draft.files.map(\.remotePath), direct: draft.direct
        ))
        if failure == nil { dismiss() }
    }
}
