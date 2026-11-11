import AppKit
import KervanKit
import SwiftUI

/// Generates screenshots of every onboarding step and every tour card in light and dark mode,
/// and in English and Turkish, when KERVAN_SNAPSHOTS is present in the environment.
@MainActor
enum SnapshotRunner {
    static func checkAndRun(model: AppModel) {
        guard let outputDir = ProcessInfo.processInfo.environment["KERVAN_SNAPSHOTS"], !outputDir.isEmpty else { return }
        run(model: model, outputDirectory: outputDir)
    }

    static func run(model: AppModel, outputDirectory: String) {
        let fileManager = FileManager.default
        let outURL = URL(fileURLWithPath: outputDirectory)
        try? fileManager.createDirectory(at: outURL, withIntermediateDirectories: true)

        print("[SnapshotRunner] Capturing screenshots to: \(outputDirectory)")

        let appearances: [(name: String, ns: NSAppearance.Name, scheme: ColorScheme)] = [
            ("light", .aqua, .light),
            ("dark", .darkAqua, .dark)
        ]

        let languages: [(name: String, choice: Language.Choice)] = [
            ("en", .english),
            ("tr", .turkish)
        ]

        let onboardingStages: [(name: String, stage: OnboardingView.Stage)] = [
            ("01-onboarding-welcome", .welcome),
            ("02-onboarding-choose", .choose),
            ("03-onboarding-connect", .connect),
            ("04-onboarding-setup", .setupForm),
            ("05-onboarding-permission", .permission),
            ("06-onboarding-progress", .setupProgress),
            ("07-onboarding-agents", .agents),
            ("08-onboarding-done", .done)
        ]

        let tourCards: [(name: String, page: Int)] = [
            ("09-tour-card-1-sessions", 0),
            ("10-tour-card-2-projects", 1),
            ("11-tour-card-3-approvals", 2),
            ("12-tour-card-4-panel", 3),
            ("13-tour-card-5-sidebar", 4),
            ("14-tour-card-6-help", 5)
        ]

        let sampleConfigs = [
            AgentConfig(id: "claude", name: "Claude Code", command: "claude", source: .builtin, available: true, signedIn: false),
            AgentConfig(id: "codex", name: "Codex", command: "codex", source: .builtin, available: true, signedIn: true),
            AgentConfig(id: "gemini", name: "Gemini", command: "gemini", source: .builtin, available: true, signedIn: false)
        ]
        model.store.handle(.agentListResult(id: "snapshot", agents: sampleConfigs, nodes: []))
        model.store.handle(.agentRegistryResult(
            id: "snapshot",
            agents: [
                OfferedAgent(id: "opencode", name: "OpenCode", description: "The open source coding agent", version: "2.2.5", status: .found, path: "/usr/local/bin/opencode"),
                OfferedAgent(id: "goose", name: "goose", description: "A local, extensible, open source AI agent that automates engineering tasks", version: "1.57.0", status: .installable, source: "download", ollama: true),
                OfferedAgent(id: "qwen-code", name: "Qwen Code", description: "Alibaba's Qwen coding assistant", version: "0.26.5", status: .installable, source: "npm", ollama: true),
                OfferedAgent(id: "github-copilot-cli", name: "Copilot", description: "GitHub's AI pair programmer", version: "1.0.105", status: .installable, source: "npm"),
                OfferedAgent(id: "claude-acp", name: "Claude Agent", description: "ACP wrapper for Anthropic's Claude", status: .builtin),
                OfferedAgent(id: "cursor", name: "Cursor", description: "Cursor's coding agent", status: .unavailable, reason: "its download has no published checksum"),
            ],
            ollama: OllamaStatus(running: true, url: "http://127.0.0.1:11434", models: ["qwen3-coder:30b", "llama3.1:8b"])
        ))

        // Sessions in every state, so the home page and the sidebar rows have something to say.
        let stamp = ISO8601DateFormatter()
        func ago(_ minutes: Double) -> String { stamp.string(from: Date().addingTimeInterval(-minutes * 60)) }
        model.store.handle(.agentsUpdated(sampleConfigs.map { AgentInfo(id: $0.id, name: $0.name) }))
        let sampleSessions = [
            SessionInfo(id: "s1", agent: "claude", title: "Add a dark theme to the site", status: .waiting, createdAt: ago(4)),
            SessionInfo(id: "s2", agent: "codex", title: "Add retries to the API client", status: .running, createdAt: ago(1)),
            SessionInfo(id: "s3", agent: "gemini", title: "Mobile menu accessibility", status: .idle, createdAt: ago(95)),
            SessionInfo(id: "s4", agent: "claude", title: "Draft the release notes", status: .idle, createdAt: ago(60 * 26)),
            SessionInfo(id: "s5", agent: "codex", title: "Shrink the font files", status: .error, createdAt: ago(60 * 5)),
        ]
        var inProject = sampleSessions
        inProject[0].projectId = "p1"
        inProject[2].projectId = "p1"
        model.store.handle(.sessionListResult(id: "snapshot", sessions: inProject))
        model.store.handle(.sessionHistoryResult(id: "snapshot", sessionId: "s1", events: [
            SessionEvent(seq: 1, at: ago(4), body: .permissionRequest(
                requestId: "p1", title: "git push origin dark-theme", toolKind: "execute", detail: nil,
                options: [PermissionChoice(optionId: "a", name: "Allow", kind: "allow_once"), PermissionChoice(optionId: "r", name: "Reject", kind: "reject_once")]
            )),
        ]))
        // A project with a board, decoded as the server would send it.
        let sampleCards = [
            ("c1", "Paginate the archive", "Add paging to the archive page; 20 posts a page.", "claude", "todo"),
            ("c2", "Shrink the font files", "Move to woff2 and subset to the characters the site uses.", "codex", "todo"),
            ("c3", "Add a dark theme", "Follow the system setting, and add a toggle in the header.", "claude", "needs"),
            ("c4", "Generate a sitemap", "Write sitemap.xml as part of publishing.", "gemini", "review"),
        ].map { #"{"id":"\#($0.0)","projectId":"p1","title":"\#($0.1)","prompt":"\#($0.2)","agent":"\#($0.3)","column":"\#($0.4)","createdAt":"","updatedAt":""}"# }
        for json in [
            #"{"type":"project.list.result","id":"snapshot","projects":[{"id":"p1","name":"Kervan website","path":"/srv/kervan-site","instructions":"","createdAt":""}]}"#,
            #"{"type":"board.result","id":"snapshot","projectId":"p1","cards":[\#(sampleCards.joined(separator: ","))]}"#,
        ] {
            if let message = try? ServerMessage.decode(json) { model.store.handle(message) } else { print("[SnapshotRunner] could not decode \(json.prefix(40))") }
        }
        let samplePlan = [
            PlanEntry(content: "Look at the stylesheet and its color variables", status: "completed"),
            PlanEntry(content: "Add the dark theme colors", status: "completed"),
            PlanEntry(content: "Put a theme button in the header", status: "in_progress"),
            PlanEntry(content: "Run the tests and check contrast", status: "pending"),
        ]

        let sampleTranscript: [TranscriptItem] = [
            .user(id: 1, text: "Add a dark theme to the site: follow the system setting, and add a toggle in the header."),
            .tool(id: 2, toolCallId: "t1", title: "Read styles.css", kind: "read", status: "completed"),
            .tool(id: 3, toolCallId: "t2", title: "Edit styles.css", kind: "edit", status: "completed", diffs: [FileDiff(path: "styles.css", oldText: "a { color: blue; }", newText: "a { color: var(--accent); }")]),
            .tool(id: 4, toolCallId: "t3", title: "npm test", kind: "execute", status: "in_progress"),
            .tool(id: 5, toolCallId: "t4", title: "npm run lint", kind: "execute", status: "failed"),
            .agent(id: 6, text: "## The dark theme is ready\n\nWhat changed:\n\n- **styles.css**: the colors were already variables, so I added dark values for `prefers-color-scheme: dark`.\n- **index.html**: a theme button in the header.\n  - It sets `data-theme` and overrides the system preference.\n\n1. Run the tests\n2. Check the contrast\n\n```bash\nnpm test\nnpm run contrast -- --min 4.5\n```\n\nContrast is **12.4:1** in dark mode; it passes WCAG AA."),
            .permission(id: 7, PermissionPrompt(
                requestId: "p1", title: "git push origin dark-theme", toolKind: "execute", detail: "git push origin dark-theme",
                options: [PermissionChoice(optionId: "a", name: "Allow", kind: "allow_once"), PermissionChoice(optionId: "aa", name: "Always", kind: "allow_always"), PermissionChoice(optionId: "r", name: "Reject", kind: "reject_once")]
            )),
        ]

        // The language is a saved setting; put the user's own choice back before quitting.
        let ownLanguage = Language.shared.choice
        for lang in languages {
            Language.shared.choice = lang.choice

            for app in appearances {
                // 1. Onboarding stages
                for step in onboardingStages {
                    let view = OnboardingView(stage: step.stage)
                        .environment(model)
                        .fontDesign(.rounded)
                        .preferredColorScheme(app.scheme)
                        .environment(\.colorScheme, app.scheme)
                        .frame(width: 860, height: 580)

                    let filename = "\(step.name)-\(lang.name)-\(app.name).png"
                    let fileURL = outURL.appendingPathComponent(filename)
                    render(view: view, size: CGSize(width: 860, height: 580), appearance: NSAppearance(named: app.ns)!, to: fileURL)
                    print("[SnapshotRunner] Wrote \(filename)")
                }

                // 1b. The welcome film, stopped at moments through its chapters.
                let filmMoments: [Double] = [2.0, Film.finished(0), 7.5, Film.finished(1), 12.6, Film.finished(2), Film.finished(3)]
                for (index, moment) in filmMoments.enumerated() {
                    let view = OnboardingView(stage: .welcome, filmTime: moment)
                        .environment(model)
                        .fontDesign(.rounded)
                        .preferredColorScheme(app.scheme)
                        .environment(\.colorScheme, app.scheme)
                        .frame(width: 860, height: 580)

                    let filename = "00-film-\(index + 1)-\(lang.name)-\(app.name).png"
                    render(view: view, size: CGSize(width: 860, height: 580), appearance: NSAppearance(named: app.ns)!, to: outURL.appendingPathComponent(filename))
                    print("[SnapshotRunner] Wrote \(filename)")
                }

                // 1c. The agent catalog.
                let catalog = AgentCatalogSheet()
                    .environment(model)
                    .fontDesign(.rounded)
                    .preferredColorScheme(app.scheme)
                    .environment(\.colorScheme, app.scheme)
                let catalogName = "15-agent-catalog-\(lang.name)-\(app.name).png"
                render(view: catalog, size: CGSize(width: 580, height: 560), appearance: NSAppearance(named: app.ns)!, to: outURL.appendingPathComponent(catalogName))
                print("[SnapshotRunner] Wrote \(catalogName)")

                // 1d. Setting up Tailscale on the server, from Web access.
                let tailscale = ServerUpdateSheet(access: .tailscale)
                    .environment(model)
                    .fontDesign(.rounded)
                    .preferredColorScheme(app.scheme)
                    .environment(\.colorScheme, app.scheme)
                let tailscaleName = "16-tailscale-setup-\(lang.name)-\(app.name).png"
                render(view: tailscale, size: CGSize(width: 520, height: 330), appearance: NSAppearance(named: app.ns)!, to: outURL.appendingPathComponent(tailscaleName))
                print("[SnapshotRunner] Wrote \(tailscaleName)")

                // 1e. Home, a transcript and the sidebar rows, with the sample sessions above.
                let home = OverviewView()
                    .environment(model)
                    .fontDesign(.rounded)
                    .preferredColorScheme(app.scheme)
                    .environment(\.colorScheme, app.scheme)
                let homeName = "17-home-\(lang.name)-\(app.name).png"
                render(view: home, size: CGSize(width: 820, height: 900), appearance: NSAppearance(named: app.ns)!, to: outURL.appendingPathComponent(homeName))
                print("[SnapshotRunner] Wrote \(homeName)")

                let chat = HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(sampleSessions) { SessionRow(session: $0) }
                    }
                    .padding(16)
                    .frame(width: 260, alignment: .leading)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(Color.kervanSidebar)
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(sampleTranscript) { item in
                            TranscriptRow(item: item, agentName: "Claude Code", senderName: { $0 }) { _, _ in }
                        }
                    }
                    .padding(28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color.kervanCanvas)
                }
                .environment(model)
                .fontDesign(.rounded)
                .preferredColorScheme(app.scheme)
                .environment(\.colorScheme, app.scheme)
                let chatName = "18-chat-\(lang.name)-\(app.name).png"
                render(view: chat, size: CGSize(width: 960, height: 860), appearance: NSAppearance(named: app.ns)!, to: outURL.appendingPathComponent(chatName))
                print("[SnapshotRunner] Wrote \(chatName)")

                // 1g. A project page with its board, the plan card and an empty place.
                let project = ProjectView(projectID: "p1")
                    .environment(model)
                    .fontDesign(.rounded)
                    .tint(.kervanLapis)
                    .preferredColorScheme(app.scheme)
                    .environment(\.colorScheme, app.scheme)
                let projectName = "20-project-\(lang.name)-\(app.name).png"
                render(view: project, size: CGSize(width: 1040, height: 900), appearance: NSAppearance(named: app.ns)!, to: outURL.appendingPathComponent(projectName))
                print("[SnapshotRunner] Wrote \(projectName)")

                let pieces = VStack(alignment: .leading, spacing: 24) {
                    PlanCard(entries: samplePlan).frame(width: 480)
                    EmptyCard(symbol: "calendar.badge.clock", title: L("No tasks yet", "Henüz görev yok"), text: L("For example \"run the tests and fix what breaks\" every morning at 09:00.", "Ör. her sabah 09:00'da \"testleri çalıştır, kırılanı düzelt\"."))
                    HStack {
                        Button(L("Cancel", "Vazgeç")) {}.buttonStyle(.kervanQuiet)
                        Button(L("Hand it over", "Görevi ver")) {}.buttonStyle(.kervanPrimary)
                        Button(L("Delete", "Sil"), role: .destructive) {}.buttonStyle(.kervanPrimary)
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color.kervanCanvas)
                .fontDesign(.rounded)
                .preferredColorScheme(app.scheme)
                .environment(\.colorScheme, app.scheme)
                let piecesName = "21-pieces-\(lang.name)-\(app.name).png"
                render(view: pieces, size: CGSize(width: 560, height: 520), appearance: NSAppearance(named: app.ns)!, to: outURL.appendingPathComponent(piecesName))
                print("[SnapshotRunner] Wrote \(piecesName)")

                // 1f. Settings, at its first stop and one further down the route.
                let ownTab = UserDefaults.standard.string(forKey: SettingsTab.key)
                for stop in [SettingsTab.general, SettingsTab.agents] {
                    UserDefaults.standard.set(stop, forKey: SettingsTab.key)
                    let settings = SettingsView()
                        .environment(model)
                        .tint(.kervanLapis)
                        .preferredColorScheme(app.scheme)
                        .environment(\.colorScheme, app.scheme)
                    let settingsName = "19-settings-\(stop)-\(lang.name)-\(app.name).png"
                    render(view: settings, size: CGSize(width: 860, height: 600), appearance: NSAppearance(named: app.ns)!, to: outURL.appendingPathComponent(settingsName))
                    print("[SnapshotRunner] Wrote \(settingsName)")
                }
                UserDefaults.standard.set(ownTab, forKey: SettingsTab.key)

                // 2. Tour cards
                for card in tourCards {
                    let view = WelcomeTourView(close: {}, initialPage: card.page)
                        .fontDesign(.rounded)
                        .preferredColorScheme(app.scheme)
                        .environment(\.colorScheme, app.scheme)

                    let filename = "\(card.name)-\(lang.name)-\(app.name).png"
                    let fileURL = outURL.appendingPathComponent(filename)
                    render(view: view, size: CGSize(width: 560, height: 430), appearance: NSAppearance(named: app.ns)!, to: fileURL)
                    print("[SnapshotRunner] Wrote \(filename)")
                }
            }
        }

        Language.shared.choice = ownLanguage
        print("[SnapshotRunner] All screenshots captured successfully.")
        exit(0)
    }

    private static func render<V: View>(view: V, size: CGSize, appearance: NSAppearance, to url: URL) {
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = CGRect(origin: .zero, size: size)
        hostingView.appearance = appearance

        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = hostingView
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()

        // Wait a tick for SwiftUI layout
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) ?? NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * 2),
            pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        rep.size = size
        hostingView.cacheDisplay(in: hostingView.bounds, to: rep)

        if let pngData = rep.representation(using: .png, properties: [:]) {
            try? pngData.write(to: url)
        }
    }
}
