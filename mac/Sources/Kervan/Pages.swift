import Charts
import KervanKit
import SwiftUI

/// A page's frame: a title, a line under it, then its content, like the overview.
private struct Page<Content: View, Actions: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var actions: Actions
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title).font(.system(size: 26, weight: .semibold, design: .rounded))
                        Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    actions
                }
                content
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 36)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity)
        }
        .background(Color.kervanCanvas)
    }
}

// MARK: Projects

/// One project: its folder, its instructions and its sessions.
struct ProjectView: View {
    let projectID: String
    @Environment(AppModel.self) private var model
    @State private var editing = false
    @State private var confirmDelete = false

    var body: some View {
        if let project = model.store.project(projectID) {
            let sessions = model.store.sessions.filter { $0.projectId == projectID && $0.parentId == nil }
            Page(title: project.name, subtitle: project.path) {
                HStack {
                    Button(L("Edit…", "Düzenle…")) { editing = true }
                    Button {
                        model.newSession(project: projectID)
                    } label: {
                        Label(L("New session here", "Bu projede oturum"), systemImage: "square.and.pencil")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.kervanLapis)
                    .disabled(!model.canCreateSession)
                }
            } content: {
                SettingsCard(title: L("Instructions", "Talimatlar")) {
                    Text(project.instructions.isEmpty
                        ? L("No instructions. Agents still read CLAUDE.md or AGENTS.md in the folder themselves.", "Talimat yok. Ajanlar klasördeki CLAUDE.md ya da AGENTS.md dosyalarını yine kendileri okur.")
                        : project.instructions)
                        .foregroundStyle(project.instructions.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                SettingsCard(title: L("Sessions", "Oturumlar")) {
                    if sessions.isEmpty {
                        Text(L("No sessions in this project yet.", "Bu projede henüz oturum yok.")).foregroundStyle(.secondary)
                    }
                    ForEach(sessions) { session in
                        Button {
                            model.selectedSessionID = session.id
                        } label: {
                            HStack(spacing: 10) {
                                StatusDot(color: session.status.tint)
                                Text(session.title).lineLimit(1)
                                Spacer()
                                Text(model.store.agentName(session.agent)).font(.caption).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button(L("Remove project…", "Projeyi kaldır…"), role: .destructive) { confirmDelete = true }
                    .buttonStyle(.link)
                    .foregroundStyle(Color.kervanCoral)
            }
            .sheet(isPresented: $editing) { ProjectSheet(project: project) }
            .confirmationDialog(L("Remove \(project.name)?", "\(project.name) kaldırılsın mı?"), isPresented: $confirmDelete) {
                Button(L("Remove", "Kaldır"), role: .destructive) {
                    Task {
                        await model.store.deleteProject(projectID)
                        model.selectedSessionID = nil
                    }
                }
            } message: {
                Text(L("The folder and its sessions stay on the server; only the project is removed from the list.", "Klasör ve içindeki oturumlar sunucuda kalır; yalnızca proje listeden çıkar."))
            }
        } else {
            Page(title: L("Project not found", "Proje bulunamadı"), subtitle: L("It may have been removed from the server.", "Bu proje sunucudan kaldırılmış olabilir.")) { EmptyView() } content: { EmptyView() }
        }
    }
}

/// Makes a project (from a repository to clone, a folder on the server, or an empty folder) or edits one.
struct ProjectSheet: View {
    enum Source: String, CaseIterable, Identifiable {
        case clone, folder, empty
        var id: String { rawValue }
        var title: String {
            switch self {
            case .clone: L("Clone a git repository", "Git deposu klonla")
            case .folder: L("Folder on the server", "Sunucudaki klasör")
            case .empty: L("Empty folder", "Boş klasör")
            }
        }
    }

    var project: ProjectInfo?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var instructions = ""
    @State private var source = Source.clone
    @State private var location = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField(L("Name", "Ad"), text: $name, prompt: Text(L("e.g. Website", "ör. Web sitesi")))
                if project == nil {
                    Picker(L("Source", "Kaynak"), selection: $source) {
                        ForEach(Source.allCases) { Text($0.title).tag($0) }
                    }
                    switch source {
                    case .clone:
                        TextField(L("Repository URL", "Depo adresi"), text: $location, prompt: Text(L("https://github.com/user/repo.git", "https://github.com/kullanici/depo.git")))
                            .font(.body.monospaced())
                        Text(L("The server clones with its own git access; private repositories need an SSH key or credentials on the server.", "Sunucu kendi git erişimiyle klonlar; özel depolar için sunucuda SSH anahtarı ya da kimlik bilgisi gerekir."))
                            .font(.caption).foregroundStyle(.secondary)
                    case .folder:
                        TextField(L("Folder path", "Klasör yolu"), text: $location, prompt: Text(L("/home/ubuntu/projects/site", "/home/ubuntu/projelerim/site")))
                            .font(.body.monospaced())
                    case .empty:
                        Text(L("A new empty folder is made in Kervan's projects folder.", "Kervan'ın proje klasöründe yeni, boş bir klasör açılır.")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    TextEditor(text: $instructions)
                        .frame(minHeight: 120)
                } header: {
                    Text(L("Instructions", "Talimatlar"))
                } footer: {
                    Text(L("Told to every agent in this project before its first message: code style, test command, things to watch out for.", "Bu projedeki her ajana ilk mesajdan önce söylenir: kod stili, test komutu, dikkat edilecekler."))
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.kervanCoral)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            HStack {
                if saving {
                    ProgressView().controlSize(.small)
                    Text(source == .clone && project == nil ? L("Cloning…", "Klonlanıyor…") : L("Saving…", "Kaydediliyor…")).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("Cancel", "Vazgeç"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(project == nil ? L("Create project", "Projeyi oluştur") : L("Save", "Kaydet")) { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave || saving)
            }
            .padding(16)
        }
        .frame(width: 500, height: 520)
        .background(Color.kervanCanvas)
        .onAppear {
            name = project?.name ?? ""
            instructions = project?.instructions ?? ""
        }
    }

    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return project != nil || source == .empty || !location.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let place = location.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = ProjectInput(
            id: project?.id,
            name: name.trimmingCharacters(in: .whitespaces),
            instructions: instructions,
            path: project == nil && source == .folder ? place : nil,
            gitUrl: project == nil && source == .clone ? place : nil
        )
        let before = Set(model.store.projects.map(\.id))
        if let failure = await model.store.saveProject(input) {
            error = failure
            return
        }
        if project == nil, let made = model.store.projects.first(where: { !before.contains($0.id) }) {
            model.selectedSessionID = AppModel.projectPage(made.id)
        }
        dismiss()
    }
}

// MARK: Scheduled tasks

/// A schedule being edited in the sheet; a new one has no id yet.
private struct ScheduleDraft: Identifiable {
    let id = UUID()
    var input: ScheduleInput
}

struct SchedulesView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: ScheduleDraft?
    @State private var error: String?

    var body: some View {
        let store = model.store
        Page(
            title: L("Scheduled tasks", "Zamanlanmış görevler"),
            subtitle: L("The server is always on: when a task is due it opens its own session and writes to the agent. You get a notification when it's done.", "Sunucu hep açık: görev vakti gelince kendi oturumunu açar ve ajana yazar. Bittiğinde bildirim gelir.")
        ) {
            Button {
                editing = ScheduleDraft(input: ScheduleInput(
                    title: "", agent: model.defaultAgent?.id ?? "", prompt: "", when: .daily(time: "09:00", weekdays: Array(1...5))
                ))
            } label: {
                Label(L("New task", "Yeni görev"), systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(.kervanLapis)
            .disabled(store.agents.isEmpty)
        } content: {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.kervanCoral)
            }
            if store.schedules.isEmpty {
                EmptyCard(
                    symbol: "calendar.badge.clock",
                    title: L("No tasks yet", "Henüz görev yok"),
                    text: L("For example \"run the tests and fix what breaks\" every morning at 09:00, or \"summarize new issues\" every hour.", "Ör. her sabah 09:00'da \"testleri çalıştır, kırılanı düzelt\" ya da her saat \"yeni issue'ları özetle\".")
                )
                .frame(maxWidth: .infinity)
            }
            ForEach(store.schedules) { schedule in
                row(schedule)
            }
        }
        .sheet(item: $editing) { draft in ScheduleSheet(input: draft.input) }
        .task { await store.loadSchedules() }
    }

    private func row(_ schedule: ScheduleInfo) -> some View {
        let project = model.store.project(schedule.projectId).map { ", \($0.name)" } ?? ""
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: schedule.enabled ? "clock.fill" : "clock")
                .foregroundStyle(schedule.enabled ? Color.kervanSaffron : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(schedule.title).font(.headline)
                Text("\(schedule.when.label), \(model.store.agentName(schedule.agent))\(project)")
                    .font(.callout).foregroundStyle(.secondary)
                Text(schedule.prompt).font(.callout).lineLimit(2).foregroundStyle(.secondary)
                if let lastError = schedule.lastError {
                    Label(L("Last run failed: \(lastError)", "Son çalıştırma başarısız: \(lastError)"), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.kervanCoral)
                } else if let last = schedule.lastRunAt.flatMap(Self.date) {
                    HStack(spacing: 6) {
                        Text(L("Last ran: \(last.formatted(date: .abbreviated, time: .shortened))", "Son çalıştı: \(last.formatted(date: .abbreviated, time: .shortened))"))
                        if let sessionID = schedule.lastSessionId, model.store.session(sessionID) != nil {
                            Button(L("Open session", "Oturumu aç")) { model.selectedSessionID = sessionID }.buttonStyle(.link)
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Toggle(L("On", "Açık"), isOn: Binding(get: { schedule.enabled }, set: { on in
                    var input = ScheduleInput(schedule)
                    input.enabled = on
                    Task { error = await model.store.saveSchedule(input) }
                }))
                .toggleStyle(.switch)
                .labelsHidden()
                .help(schedule.enabled ? L("Pause task", "Görevi duraklat") : L("Turn task on", "Görevi aç"))
                Menu {
                    Button(L("Run now", "Şimdi çalıştır")) { Task { error = await model.store.runSchedule(schedule.id) } }
                    Button(L("Edit…", "Düzenle…")) { editing = ScheduleDraft(input: ScheduleInput(schedule)) }
                    Divider()
                    Button(L("Delete", "Sil"), role: .destructive) { Task { error = await model.store.deleteSchedule(schedule.id) } }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel(L("\(schedule.title) options", "\(schedule.title) seçenekleri"))
            }
        }
        .padding(16)
        .softSurface()
    }

    static func date(_ iso: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    }
}

private struct ScheduleSheet: View {
    @State var input: ScheduleInput
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var daily = true
    @State private var time = Date()
    @State private var weekdays: Set<Int> = Set(1...5)
    @State private var minutes = 60
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField(L("Name", "Ad"), text: $input.title, prompt: Text(L("e.g. Morning test run", "ör. Sabah test turu")))
                Picker(L("Agent", "Ajan"), selection: $input.agent) {
                    ForEach(model.store.agents) { Text($0.displayName).tag($0.id) }
                }
                Picker(L("Project", "Proje"), selection: $input.projectId) {
                    Text(L("None (its own folder)", "Yok (kendi klasörü)")).tag(String?.none)
                    ForEach(model.store.projects) { Text($0.name).tag(Optional($0.id)) }
                }
                Section(L("When", "Ne zaman")) {
                    Picker(L("Repeat", "Tekrar"), selection: $daily) {
                        Text(L("Daily at a set time", "Her gün belirli saatte")).tag(true)
                        Text(L("At an interval", "Belirli aralıklarla")).tag(false)
                    }
                    .pickerStyle(.radioGroup)
                    if daily {
                        DatePicker(L("Time", "Saat"), selection: $time, displayedComponents: .hourAndMinute)
                        HStack(spacing: 4) {
                            ForEach(1...7, id: \.self) { day in
                                Toggle(ScheduleWhen.dayNames[day - 1], isOn: Binding(
                                    get: { weekdays.contains(day) },
                                    set: { on in if on { weekdays.insert(day) } else { weekdays.remove(day) } }
                                ))
                                .toggleStyle(.button)
                            }
                        }
                    } else {
                        Picker(L("Interval", "Aralık"), selection: $minutes) {
                            ForEach([15, 30, 60, 120, 240, 720], id: \.self) { value in
                                Text(ScheduleWhen.interval(minutes: value).label).tag(value)
                            }
                        }
                    }
                    Text(L("Time zone: \(input.timeZone)", "Saat dilimi: \(input.timeZone)")).font(.caption).foregroundStyle(.secondary)
                }
                Section(L("What to tell the agent", "Ajana ne yazılsın")) {
                    TextEditor(text: $input.prompt).frame(minHeight: 110)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.kervanCoral)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            HStack {
                Spacer()
                Button(L("Cancel", "Vazgeç"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Save", "Kaydet")) { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
            .padding(16)
        }
        .frame(width: 500, height: 620)
        .background(Color.kervanCanvas)
        .onAppear(perform: load)
    }

    private var canSave: Bool {
        !saving && !input.title.trimmingCharacters(in: .whitespaces).isEmpty
            && !input.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (!daily || !weekdays.isEmpty)
    }

    private func load() {
        switch input.when {
        case .daily(let hhmm, let days):
            daily = true
            weekdays = Set(days)
            let parts = hhmm.split(separator: ":").compactMap { Int($0) }
            time = Calendar.current.date(bySettingHour: parts.first ?? 9, minute: parts.last ?? 0, second: 0, of: .now) ?? .now
        case .interval(let value):
            daily = false
            minutes = value
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        input.when = daily
            ? .daily(time: String(format: "%02d:%02d", parts.hour ?? 9, parts.minute ?? 0), weekdays: weekdays.sorted())
            : .interval(minutes: minutes)
        if let failure = await model.store.saveSchedule(input) {
            error = failure
        } else {
            dismiss()
        }
    }
}

// MARK: Usage

struct UsageView: View {
    @Environment(AppModel.self) private var model
    @State private var days = 30

    var body: some View {
        let report = model.store.usage
        Page(
            title: L("Usage", "Kullanım"),
            subtitle: L("Spending as the agents report it. Only agents that report cost (Claude API) count for now; agents used through a subscription don't show up.", "Ajanların bildirdiği harcama. Şimdilik yalnızca maliyet bildiren ajanlar (Claude API) sayılır; abonelikle çalışan ajanlar görünmez.")
        ) {
            Picker(L("Period", "Dönem"), selection: $days) {
                Text(L("7 days", "7 gün")).tag(7)
                Text(L("30 days", "30 gün")).tag(30)
                Text(L("90 days", "90 gün")).tag(90)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
        } content: {
            if let report {
                totals(report)
                if report.days.isEmpty {
                    EmptyCard(symbol: "chart.bar", title: L("No spending in this period", "Bu dönemde harcama yok"), text: L("Daily totals build up here as agents report their cost.", "Ajanlar maliyet bildirdikçe günlük toplamlar burada birikir."))
                        .frame(maxWidth: .infinity)
                } else {
                    SettingsCard(title: L("Daily", "Günlük")) { chart(report) }
                    SettingsCard(title: L("By agent", "Ajanlara göre")) {
                        ForEach(report.byAgent, id: \.agent) { entry in
                            HStack {
                                Text(model.store.agentName(entry.agent))
                                Spacer()
                                Text(usd(entry.costUsd)).monospacedDigit()
                            }
                        }
                    }
                    SettingsCard(title: L("Top sessions", "En çok harcayan oturumlar")) {
                        ForEach(report.sessions, id: \.sessionId) { entry in
                            Button {
                                if model.store.session(entry.sessionId) != nil { model.selectedSessionID = entry.sessionId }
                            } label: {
                                HStack {
                                    Text(model.store.session(entry.sessionId)?.title ?? L("Deleted session", "Silinmiş oturum")).lineLimit(1)
                                    Spacer()
                                    Text(usd(entry.costUsd)).monospacedDigit().foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .task(id: days) { await model.store.loadUsage(days: days) }
    }

    private func chart(_ report: UsageReport) -> some View {
        Chart(Array(report.days.enumerated()), id: \.offset) { _, day in
            BarMark(
                x: .value(L("Day", "Gün"), Self.day(day.date) ?? .now, unit: .day),
                y: .value("USD", day.costUsd)
            )
            .foregroundStyle(by: .value(L("Agent", "Ajan"), model.store.agentName(day.agent)))
            .cornerRadius(3)
        }
        .chartForegroundStyleScale(range: [Color.kervanLapis, .kervanSaffron, .kervanOasis, .kervanCoral])
        // The whole period, so a single day is one narrow bar among empty days, not a bar across the chart.
        .chartXScale(domain: periodStart...Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now))!)
        .frame(height: 200)
        .accessibilityLabel(L("Daily spending chart", "Günlük harcama grafiği"))
    }

    private var periodStart: Date {
        Calendar.current.date(byAdding: .day, value: -(days - 1), to: Calendar.current.startOfDay(for: .now)) ?? .now
    }

    private func totals(_ report: UsageReport) -> some View {
        let today = Self.key(.now)
        let week = Self.key(Calendar.current.date(byAdding: .day, value: -6, to: .now) ?? .now)
        return HStack(spacing: 12) {
            tile(L("Today", "Bugün"), report.total(since: today))
            tile(L("Last 7 days", "Son 7 gün"), report.total(since: week))
            tile(L("Last \(days) days", "Son \(days) gün"), report.total)
        }
    }

    private func tile(_ label: String, _ amount: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(usd(amount)).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .softSurface()
        .accessibilityElement(children: .combine)
    }

    private static let dayFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func key(_ date: Date) -> String { dayFormat.string(from: date) }
    private static func day(_ key: String) -> Date? { dayFormat.date(from: key) }
}
