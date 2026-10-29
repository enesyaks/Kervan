import AppKit
import SwiftUI

@main
struct KervanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Kervan") {
            RootView()
                .environment(model)
                .tint(.kervanLapis)
        }
        .defaultSize(width: 960, height: 620)
        .commands {
            CommandGroup(replacing: .newItem) {
                NewSessionCommands(model: model)
            }
        }
    }
}

/// File › New Session: ⌘N for the last-used agent, a submenu for picking one.
/// The item doesn't name the agent: menu commands don't redraw on observable changes, so a name would go stale.
private struct NewSessionCommands: View {
    let model: AppModel

    var body: some View {
        let agents = model.store.agents
        Button("Yeni oturum") { model.newSession() }
            .keyboardShortcut("n")
            .disabled(!model.canCreateSession)
        if agents.count > 1 {
            Menu("Ajanla yeni oturum") {
                ForEach(agents) { agent in
                    Button(agent.name) { model.newSession(agent: agent.id) }
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
