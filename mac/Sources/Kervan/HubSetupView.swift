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
    /// macOS keeps the app off the local network: the screen offers the settings page.
    private(set) var localNetworkBlocked = false
    var started: Bool { startedAt != nil }
    private var task: Task<Void, Never>?
    private var process: Process?

    /// `token`: the hub's existing token when updating it; a new one is made for a fresh hub.
    func run(user: String, host: String, access: HubSetup.Access, token existing: String? = nil, connect: @escaping (String) -> Void) {
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
                let payload = try Self.payload(token: token)
                defer { try? FileManager.default.removeItem(at: payload.deletingLastPathComponent()) }
                try await self.ssh(HubSetup.uploadArguments(user: user, host: host), stdin: payload)

                self.step = .packages
                do {
                    try await self.ssh(HubSetup.sudoCheckArguments(user: user, host: host))
                    try await self.ssh(HubSetup.runArguments(user: user, host: host, access: access))
                } catch let error as SetupError where error.needsPassword {
                    // sudo wants a password: the user runs the setup in their own Terminal; we wait for the server.
                    self.waitingForTerminal = true
                }
                try await self.waitUntilAnswering(host: host)
                self.step = .ready
                self.isRunning = false
                self.waitingForTerminal = false
                connect(token)
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
        localNetworkBlocked = false
        waitingForTerminal = false
        isRunning = false
    }

    func stop() {
        task?.cancel()
        if process?.isRunning == true { process?.terminate() }
    }

    private struct SetupError: Error {
        let message: String
        var needsPassword = false
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
        tar.arguments = ["-czf", archive.path, "-C", stage.path, "."]
        tar.environment = ["COPYFILE_DISABLE": "1"]
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else { throw SetupError(message: L("Couldn't prepare the setup package.", "Kurulum paketi hazırlanamadı.")) }
        return archive
    }

    /// Runs ssh, showing what it prints; the setup script's "==>" lines move the step list along.
    private func ssh(_ arguments: [String], stdin: URL? = nil) async throws {
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
        self.process = process
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
    private func waitUntilAnswering(host: String) async throws {
        let deadline = Date().addingTimeInterval(20 * 60)
        while Date() < deadline {
            try Task.checkCancellation()
            if await NodeSetup.isReachable("\(host):\(ServerAddress.defaultPort)") { return }
            try await Task.sleep(for: .seconds(3))
        }
        throw SetupError(message: L("The server didn't answer within 20 minutes. Check the detailed output or run setup again.", "Sunucu 20 dakika içinde yanıt vermedi. Ayrıntılı çıktıya bakın ya da kurulumu yeniden deneyin."))
    }
}
