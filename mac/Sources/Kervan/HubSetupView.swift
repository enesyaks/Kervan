import AppKit
import KervanKit
import SwiftUI

/// Numbered stages with done / in progress (with elapsed time) / failed / to come.
struct StepList: View {
    let steps: [(title: String, detail: String)]
    let reached: Int
    let running: Bool
    let failed: Bool
    let startedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(steps.indices, id: \.self) { index in
                // The last step counts as done once reached and nothing is running or failing.
                let done = index < reached || (index == steps.count - 1 && index == reached && !running && !failed)
                let current = index == reached && !done
                HStack(alignment: .top, spacing: 10) {
                    Group {
                        if done {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.kervanOasis)
                        } else if current && failed {
                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.kervanCoral)
                        } else if current && running {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "circle").foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(steps[index].title)
                            .font(.callout.weight(current ? .semibold : .regular))
                            .foregroundStyle(done || current ? .primary : .secondary)
                        if current {
                            Text(steps[index].detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if current && running, let startedAt {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let seconds = Int(context.date.timeIntervalSince(startedAt))
                            Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// Runs the hub setup over SSH: send the files, see whether sudo needs a password, run the script (or wait
/// for the user to run it in Terminal), then wait for the server to answer and hand back the token.
@MainActor
@Observable
final class HubInstaller {
    private(set) var output = ""
    private(set) var isRunning = false
    private(set) var waitingForTerminal = false
    private(set) var failure: String?
    private(set) var startedAt: Date?
    private(set) var step: HubSetupStep = .uploading
    private(set) var tailscaleURL: URL?
    /// The server's Tailscale address while this Mac can't reach it yet, which usually means Tailscale is off here.
    private(set) var waitingOnTailscale: String?
    /// macOS keeps the app off the local network: the screen offers the settings page.
    private(set) var localNetworkBlocked = false
    var started: Bool { startedAt != nil }
    /// The machine wouldn't let this Mac in with its key, which one command in Terminal puts right.
    var sshRefused: Bool { failure != nil && output.contains("Permission denied") }

    /// A step as the list shows it. While setup runs in the user's Terminal its progress can't be seen from here, so the
    /// step says what it's waiting for rather than seeming to work on something.
    func line(_ step: HubSetupStep) -> (title: String, detail: String) {
        guard waitingForTerminal, step == self.step else { return (step.title, step.detail) }
        return (
            L("Waiting for setup in Terminal", "Terminal'deki kurulum bekleniyor"),
            L("Run the command below if you haven't. Its progress shows there, and this window carries on when it's done.", "Henüz çalıştırmadıysanız aşağıdaki komutu çalıştırın. İlerlemesi orada görünür; bitince bu pencere kendiliğinden devam eder.")
        )
    }
    private var task: Task<Void, Never>?
    private var process: Process?
    /// What `resend` needs to put the setup files back; kept from the run that is waiting for Terminal.
    private var sent: (user: String, host: String, token: String)?

    /// `token`: the hub's existing token when updating it; a new one is made for a fresh hub.
    /// `connect` gets the token and the address the server answered on: its Tailscale one, once it has one.
    func run(user: String, host: String, access: HubSetup.Access, token existing: String? = nil, connect: @escaping (String, String) -> Void) {
        reset()
        startedAt = Date()
        isRunning = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                if await LocalNetwork.check(host: host) == false {
                    self.localNetworkBlocked = true
                    throw SetupError(message: L("macOS isn't letting Kervan reach machines on the local network. Turn Kervan on in Local Network settings, then try again.", "macOS, Kervan'ın yerel ağdaki makinelere ulaşmasına izin vermiyor. Yerel Ağ ayarlarında Kervan'ı açın, sonra yeniden deneyin."))
                }
                let token = existing ?? HubSetup.makeToken()
                try await self.upload(user: user, host: host, token: token)
                self.sent = (user, host, token)

                self.step = .packages
                do {
                    try await self.ssh(HubSetup.sudoCheckArguments(user: user, host: host))
                    try await self.ssh(HubSetup.runArguments(user: user, host: host, access: access))
                } catch let error as SetupError where error.needsPassword {
                    // sudo wants a password: the user runs the setup in their own Terminal; we wait for the server.
                    self.waitingForTerminal = true
                }
                let reached = try await self.waitUntilAnswering(user: user, host: host, access: access)
                self.step = .ready
                self.isRunning = false
                self.waitingForTerminal = false
                connect(token, reached)
            } catch is CancellationError {
                self.isRunning = false
            } catch {
                self.isRunning = false
                self.waitingForTerminal = false
                self.failure = (error as? SetupError)?.message ?? error.localizedDescription
                if self.output.contains("No route to host") { self.localNetworkBlocked = true }
            }
        }
    }

    func reset() {
        stop()
        output = ""
        failure = nil
        startedAt = nil
        step = .uploading
        tailscaleURL = nil
        waitingOnTailscale = nil
        localNetworkBlocked = false
        waitingForTerminal = false
        isRunning = false
        sent = nil
    }

    func stop() {
        task?.cancel()
        if process?.isRunning == true { process?.terminate() }
    }

    private struct SetupError: Error {
        let message: String
        var needsPassword = false
    }

    /// Puts the setup files on the server, replacing whatever a previous run left there.
    private func upload(user: String, host: String, token: String, track: Bool = true) async throws {
        let payload = try Self.payload(token: token)
        defer { try? FileManager.default.removeItem(at: payload.deletingLastPathComponent()) }
        try await ssh(HubSetup.uploadArguments(user: user, host: host), stdin: payload, track: track)
    }

    /// Sends the files again before the user starts the script in their own Terminal. The script removes the token as
    /// it exits, whether it worked or not, so a second run would otherwise find nothing and refuse. Nil when it worked.
    func resend() async -> String? {
        guard let sent else { return nil }
        do {
            // Untracked: this runs while the main task waits for the server, whose process must stay the cancellable one.
            try await upload(user: sent.user, host: sent.host, token: sent.token, track: false)
            return nil
        } catch {
            return (error as? SetupError)?.message ?? error.localizedDescription
        }
    }

    /// server.tar.gz, hub-setup.sh and kervan.service from the app bundle, plus the token, as one archive.
    private static func payload(token: String) throws -> URL {
        let names = [("server", "tar.gz"), ("hub-setup", "sh"), ("kervan", "service")]
        let sources = names.compactMap { Bundle.main.url(forResource: $0.0, withExtension: $0.1) }
        guard sources.count == names.count else {
            throw SetupError(message: L("This copy of the app has no setup files. Open the app as built by scripts/bundle.sh.", "Kurulum dosyaları bu uygulamada yok. Uygulamayı scripts/bundle.sh ile oluşturulmuş hâliyle açın."))
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kervan-setup-\(UUID().uuidString)")
        let stage = folder.appendingPathComponent("stage")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for source in sources { try FileManager.default.copyItem(at: source, to: stage.appendingPathComponent(source.lastPathComponent)) }
        let tokenFile = stage.appendingPathComponent("token")
        try Data(token.utf8).write(to: tokenFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)
        let archive = folder.appendingPathComponent("payload.tgz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        // Without the Mac's own file labels, which Linux's tar prints a warning about for every file.
        tar.arguments = ["--no-mac-metadata", "--no-xattrs", "--no-fflags", "-czf", archive.path, "-C", stage.path, "."]
        tar.environment = ["COPYFILE_DISABLE": "1"]
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else { throw SetupError(message: L("Couldn't prepare the setup package.", "Kurulum paketi hazırlanamadı.")) }
        return archive
    }

    /// Runs ssh, showing what it prints; the setup script's "==>" lines move the step list along.
    private func ssh(_ arguments: [String], stdin: URL? = nil, track: Bool = true) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = try stdin.map { try FileHandle(forReadingFrom: $0) } ?? FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard !text.isEmpty else { return }
            Task { @MainActor in
                guard let self else { return }
                self.output += text
                self.step = max(self.step, HubSetupStep.reached(in: self.output))
                if self.tailscaleURL == nil { self.tailscaleURL = HubSetup.tailscaleLoginURL(in: self.output) }
            }
        }
        if track { self.process = process }
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in continuation.resume(returning: finished.terminationStatus) }
                do { try process.run() } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            process.terminate()
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        try await Task.sleep(for: .milliseconds(100)) // let the last output land before deciding
        if status != 0 {
            let passwordWanted = output.contains("a password is required") || output.contains("a terminal is required")
            throw SetupError(message: NodeSetup.explain(output: output), needsPassword: passwordWanted)
        }
    }

    /// Polls /health on the new server for up to 20 minutes (long enough for a manual Terminal run).
    /// Waits for the server to answer as the version this app carries. Answering alone isn't enough: during an
    /// update the old server answers until the setup has run, and when sudo wants a password that is only once the
    /// user has run it in Terminal.
    private func waitUntilAnswering(user: String, host: String, access: HubSetup.Access) async throws -> String {
        let deadline = Date().addingTimeInterval(20 * 60)
        var tailscale: String?
        var round = 0
        // When the script in Terminal was first seen to have exited.
        var stopped: Date?
        while Date() < deadline {
            try Task.checkCancellation()
            // Over SSH, and not every time: it stays reachable when the server's own port has closed.
            if tailscale == nil, round % 4 == 0 { tailscale = await Self.tailscaleAddress(user: user, host: host) }
            round += 1
            var there: String?
            if let tailscale { there = await Self.runningVersion(host: tailscale) }
            // Setting up Podman leaves the version as it was, so the version can't say it's done; the server can.
            if access == .podman {
                for candidate in [tailscale, host].compactMap({ $0 }) {
                    if let address = ServerAddress(candidate), await HubFallback.buildsInContainers(at: address) == true {
                        waitingOnTailscale = nil
                        return candidate
                    }
                }
            } else {
                if let tailscale, there == KervanVersion.current {
                    waitingOnTailscale = nil
                    return tailscale
                }
                if await Self.runningVersion(host: host) == KervanVersion.current { return host }
            }
            // Only when nothing answers there. An older version answering means setup hasn't finished, not that Tailscale is off.
            waitingOnTailscale = round > 10 && there == nil ? tailscale : nil
            // The script removes the token as it exits. Once it's gone the run in Terminal is over, so a server that
            // still isn't back means it stopped on an error no one here can see: say so instead of waiting out the
            // twenty minutes. The grace is for the service, which the script has already waited for before exiting.
            if waitingForTerminal, round % 4 == 0 {
                stopped = await Self.tokenGone(user: user, host: host) ? (stopped ?? Date()) : nil
            }
            if let stopped, Date().timeIntervalSince(stopped) > 45 {
                throw SetupError(message: L(
                    "Setup stopped in the Terminal window before the server came back. What went wrong is written there; put it right and run the command again.",
                    "Terminal penceresindeki kurulum, sunucu geri gelmeden durdu. Nerede takıldığı orada yazıyor; onu giderip komutu yeniden çalıştırın."
                ))
            }
            try await Task.sleep(for: .seconds(3))
        }
        throw SetupError(message: L("The server didn't come back as \(KervanVersion.current) within 20 minutes. Check the detailed output or run setup again.", "Sunucu 20 dakika içinde \(KervanVersion.current) olarak geri gelmedi. Ayrıntılı çıktıya bakın ya da kurulumu yeniden deneyin."))
    }

    /// Whether the token is gone from the server, i.e. the setup script has run and exited. Only a plain "no such
    /// file" counts: an SSH that couldn't ask says nothing about the run.
    private static func tokenGone(user: String, host: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = HubSetup.tokenCheckArguments(user: user, host: host)
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { finished in continuation.resume(returning: finished.terminationStatus == 1) }
            do { try process.run() } catch { continuation.resume(returning: false) }
        }
    }

    /// The server's MagicDNS name, asked over SSH; nil until it has one.
    static func tailscaleAddress(user: String, host: String) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = HubSetup.tailscaleAddressArguments(user: user, host: host)
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { _ in
                let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                continuation.resume(returning: HubFallback.name(fromStatus: text))
            }
            do { try process.run() } catch { continuation.resume(returning: nil) }
        }
    }

    /// The version the server at `host` reports on /health, if it answers.
    private static func runningVersion(host: String) async -> String? {
        guard let address = ServerAddress(host) else { return nil }
        return await HubFallback.version(at: address)
    }
}
