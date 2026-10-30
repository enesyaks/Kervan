import AppKit
import CryptoKit
import Foundation
import KervanKit
import Observation

/// Finds a newer release on GitHub and installs it: download, check the SHA-256 published with it,
/// swap the app bundle once this process has quit, and open the new one.
@MainActor
@Observable
final class AppUpdater {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(AppRelease)
        case downloading
        case installing
        case failed(String)
    }

    private(set) var state = State.idle
    private static let autoKey = "autoUpdateCheck"
    private static let lastCheckKey = "lastUpdateCheck"

    /// Checks once a day, at launch, unless turned off in Settings.
    var checksAutomatically: Bool = UserDefaults.standard.object(forKey: AppUpdater.autoKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(checksAutomatically, forKey: Self.autoKey) }
    }

    var available: AppRelease? {
        if case .available(let release) = state { release } else { nil }
    }

    /// Only a real app bundle with Kervan's own identity can replace itself; test copies and `swift run` can't.
    var canInstall: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier == "com.enes.kervan"
    }

    func checkIfDue() {
        guard checksAutomatically else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 20 * 60 * 60 else { return }
        Task { await check(quietly: true) }
    }

    /// `quietly`: a failure leaves the state as it was instead of showing an error.
    func check(quietly: Bool = false) async {
        if !quietly { state = .checking }
        do {
            var request = URLRequest(url: AppRelease.latestURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let release = AppRelease.parse(data) else {
                if !quietly { state = .upToDate }
                return
            }
            if release.isNewer(than: KervanVersion.current) {
                state = .available(release)
            } else if !quietly {
                state = .upToDate
            }
        } catch {
            if !quietly {
                state = .failed(L("Couldn't check for updates: \(error.localizedDescription)", "Güncellemeler denetlenemedi: \(error.localizedDescription)"))
            }
        }
    }

    func install(_ release: AppRelease) {
        guard canInstall else {
            state = .failed(L(
                "This copy of Kervan can't update itself. Download the new version from the release page.",
                "Kervan'ın bu kopyası kendini güncelleyemiyor. Yeni sürümü sürüm sayfasından indirin."
            ))
            return
        }
        let target = Bundle.main.bundleURL
        let folder = target.deletingLastPathComponent().path
        guard FileManager.default.isWritableFile(atPath: folder) else {
            state = .failed(L(
                "Kervan can't replace itself in \(folder). Move it to Applications or update from the release page.",
                "Kervan, \(folder) içinde kendini değiştiremiyor. Uygulamalar klasörüne taşıyın ya da sürüm sayfasından güncelleyin."
            ))
            return
        }
        state = .downloading
        Task {
            do {
                let app = try await Self.download(release)
                state = .installing
                try Self.relaunch(replacing: target, with: app)
                NSApp.terminate(nil)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    struct UpdateError: LocalizedError {
        let errorDescription: String?
    }

    /// The new Kervan.app, unpacked in a temporary folder after its checksum matched.
    private static func download(_ release: AppRelease) async throws -> URL {
        guard let checksumURL = release.checksum else {
            throw UpdateError(errorDescription: L(
                "This release has no checksum, so it isn't installed automatically. Use the release page.",
                "Bu sürümün sağlama toplamı yok; kendiliğinden kurulmuyor. Sürüm sayfasını kullanın."
            ))
        }
        let (checksumData, _) = try await URLSession.shared.data(from: checksumURL)
        guard let expected = AppRelease.digest(inChecksumFile: String(decoding: checksumData, as: UTF8.self)) else {
            throw UpdateError(errorDescription: L("The release's checksum file is unreadable.", "Sürümün sağlama toplamı dosyası okunamadı."))
        }
        let (archive, _) = try await URLSession.shared.download(from: release.archive)
        let digest = SHA256.hash(data: try Data(contentsOf: archive)).map { String(format: "%02x", $0) }.joined()
        guard digest == expected else {
            throw UpdateError(errorDescription: L(
                "The download doesn't match its checksum; nothing was installed.",
                "İndirilen dosya sağlama toplamıyla eşleşmiyor; hiçbir şey kurulmadı."
            ))
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kervan-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, folder.path])
        let app = folder.appendingPathComponent("Kervan.app")
        guard Bundle(url: app)?.bundleIdentifier == "com.enes.kervan" else {
            throw UpdateError(errorDescription: L("The download isn't a Kervan app.", "İndirilen dosya bir Kervan uygulaması değil."))
        }
        return app
    }

    /// Waits for this process to exit, swaps the bundles (the old one comes back if the move fails),
    /// and opens the app.
    private static func relaunch(replacing target: URL, with app: URL) throws {
        let script = """
        while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done
        /bin/rm -rf "$2.old"
        if /bin/mv "$2" "$2.old"; then
          if /bin/mv "$1" "$2"; then /bin/rm -rf "$2.old"; else /bin/mv "$2.old" "$2"; fi
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$2" 2>/dev/null
        /usr/bin/open "$2"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script, "kervan-update", app.path, target.path]
        try process.run()
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError(errorDescription: L("Couldn't unpack the update.", "Güncelleme açılamadı."))
        }
    }
}
