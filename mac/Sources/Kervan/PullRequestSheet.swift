import AppKit
import KervanKit
import SwiftUI

/// Asks for the pull request's title and description, then has the server push the session's work and open it.
struct PullRequestSheet: View {
    let sessionID: String
    /// For a session on a node: its branch on the server is pushed as it is.
    var fromNode: String?
    let done: (PullRequestInfo) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var details = ""
    @State private var working = false
    @State private var failure: String?

    init(sessionID: String, title: String, fromNode: String? = nil, done: @escaping (PullRequestInfo) -> Void) {
        self.sessionID = sessionID
        self.fromNode = fromNode
        _title = State(initialValue: title)
        self.done = done
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Open a pull request", "Pull request aç")).font(.title2.weight(.semibold))
            Text(fromNode.map { node in
                L(
                    "The server first takes what \(node) hasn't sent yet, if it's reachable, then pushes the session's branch as it is to the project's repository. If GitHub's gh is signed in on the server, the pull request is opened for you; otherwise GitHub opens with it ready to send.",
                    "Sunucu önce, ulaşılabiliyorsa \(node) makinesinin henüz göndermediği işi alır, sonra oturumun dalını olduğu gibi projenin deposuna push eder. Sunucuda GitHub'ın gh aracı oturum açmışsa pull request sizin için açılır; değilse GitHub, gönderilmeye hazır hâliyle açılır."
                )
            } ?? L(
                "The server commits what's left, moves the work to a branch of its own if it's on the main branch, and pushes it. If GitHub's gh is signed in on the server, the pull request is opened for you; otherwise GitHub opens with it ready to send.",
                "Sunucu kalan değişiklikleri commit eder, iş ana branch'teyse kendi branch'ine taşır ve push eder. Sunucuda GitHub'ın gh aracı oturum açmışsa pull request sizin için açılır; değilse GitHub, gönderilmeye hazır hâliyle açılır."
            ))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            // Without a GitHub sign-in the push fails; connecting here saves a trip to Settings.
            if model.store.github?.signedIn != true {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("The server isn't connected to GitHub yet, so it can't push.", "Sunucu henüz GitHub'a bağlı değil, bu yüzden push edemez."))
                        .font(.callout.weight(.medium))
                    GitHubConnection()
                }
                .padding(12)
                .softSurface(radius: Radius.card)
            }

            Form {
                TextField(L("Title", "Başlık"), text: $title, prompt: Text(L("e.g. Fix the login redirect", "ör. Giriş yönlendirmesini düzelt")))
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Description", "Açıklama"))
                    TextEditor(text: $details).frame(height: 110)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .disabled(working)

            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Color.kervanCoral)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            HStack {
                if working {
                    ProgressView().controlSize(.small)
                    Text(L("Pushing…", "Push ediliyor…")).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("Cancel", "Vazgeç")) { dismiss() }
                    .buttonStyle(.kervanQuiet)
                    .keyboardShortcut(.cancelAction)
                Button(L("Open pull request", "Pull request aç")) { Task { await open() } }
                    .buttonStyle(.kervanPrimary)
                    .tint(.kervanLapis)
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 520)
    }

    private func open() async {
        working = true
        defer { working = false }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        switch await model.store.pullRequest(sessionID, title: title, body: details) {
        case .success(let result):
            if let url = result.url { NSWorkspace.shared.open(url) }
            done(result)
            dismiss()
        case .failure(let error):
            failure = error.message
        }
    }
}

/// Under the commit box after a pull request: where the work went, and a way back to it.
struct ProposedNote: View {
    let pullRequest: PullRequestInfo

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "arrow.triangle.pull").foregroundStyle(Color.kervanOasis)
            VStack(alignment: .leading, spacing: 2) {
                Text(pullRequest.created
                    ? L("Pull request opened from \(pullRequest.branch).", "\(pullRequest.branch) branch'inden pull request açıldı.")
                    : L("Pushed \(pullRequest.branch); finish the pull request into \(pullRequest.base) on GitHub.", "\(pullRequest.branch) push edildi; \(pullRequest.base) için pull request'i GitHub'da tamamlayın."))
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                if let url = pullRequest.url {
                    Link(pullRequest.created ? L("Open the pull request", "Pull request'i aç") : L("Open GitHub", "GitHub'ı aç"), destination: url)
                        .font(.caption)
                }
            }
        }
    }
}
