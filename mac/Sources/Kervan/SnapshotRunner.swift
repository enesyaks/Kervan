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
