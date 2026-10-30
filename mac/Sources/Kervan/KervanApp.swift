import AppKit
import KervanKit
import SwiftUI

@main
struct KervanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @AppStorage(Appearance.key) private var appearance = Appearance.light.rawValue

    var body: some Scene {
        WindowGroup("Kervan") {
            RootView()
                .environment(model)
                .tint(.kervanLapis)
                .preferredColorScheme(Appearance(rawValue: appearance)?.scheme)
        }
        .defaultSize(width: 960, height: 620)
        .commands {
            CommandGroup(replacing: .newItem) {
                NewSessionCommands(model: model)
            }
            CommandGroup(replacing: .help) {
                Button(L("Set Up Kervan…", "Kervan'ı Kur…")) {
                    withAnimation(Motion.smooth) { model.showOnboarding = true }
                }
                Button(L("Welcome Tour", "Tanıtım Turu")) { WelcomeTour.show() }
                Button(L("Report a Problem…", "Sorun Bildir…")) { model.showReportProblem = true }
                Link(L("Kervan on GitHub", "GitHub'da Kervan"), destination: URL(string: "https://github.com/enesyaks/Kervan")!)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .tint(.kervanLapis)
                .preferredColorScheme(Appearance(rawValue: appearance)?.scheme)
        }
    }
}

/// File › New Session: ⌘N for the last-used agent, a submenu for picking one.
/// The item doesn't name the agent: menu commands don't redraw on observable changes, so a name would go stale.
private struct NewSessionCommands: View {
    let model: AppModel

    var body: some View {
        let agents = model.store.agents
        Button(L("New session", "Yeni oturum")) { model.newSession() }
            .keyboardShortcut("n")
            .disabled(!model.canCreateSession)
        Button(L("New team…", "Yeni takım…")) { model.showNewTeam = true }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(!model.canCreateSession)
        if agents.count > 1 {
            Menu(L("New session with agent", "Ajanla yeni oturum")) {
                ForEach(agents) { agent in
                    Button(agent.displayName) { model.newSession(agent: agent.id) }
                }
            }
            .disabled(!model.canCreateSession)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare binary (swift run); harmless inside the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
