import AppKit
import KervanKit
import SwiftUI

/// A file picked for the next message (uploaded to the session's `uploads/` folder at once) or for a board card.
struct Attachment: Identifiable, Equatable {
    enum State: Equatable {
        case uploading
        case ready
        case failed(String)
    }

    let id = UUID()
    let name: String
    /// Where it lands in the workspace; for a card file, the server's reference once uploaded.
    var remotePath: String
    var state: State = .uploading

    var isReady: Bool { state == .ready }

    /// `taken`: paths already used by this message, so two "rapor.pdf" files don't collide.
    init(name: String, taken: Set<String>) {
        self.name = name
        var path = "uploads/\(name)"
        var n = 2
        while taken.contains(path) {
            let url = URL(fileURLWithPath: name)
            let ext = url.pathExtension
            let stem = url.deletingPathExtension().lastPathComponent
            path = "uploads/\(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")"
            n += 1
        }
        self.remotePath = path
    }

    init(name: String, remotePath: String, state: State) {
        self.name = name
        self.remotePath = remotePath
        self.state = state
    }
}

struct AttachmentChip: View {
    let attachment: Attachment
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            switch attachment.state {
            case .uploading:
                ProgressView().controlSize(.mini)
            case .ready:
                Image(systemName: "doc").foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.kervanCoral)
            }
            Text(attachment.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 180)
            Button(action: remove) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(L("Remove attachment \(attachment.name)", "\(attachment.name) ekini kaldır"))
        }
        .font(.callout)
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .help(Self.help(attachment))
    }

    private static func help(_ attachment: Attachment) -> String {
        switch attachment.state {
        case .uploading: L("Uploading: \(attachment.name)", "Yükleniyor: \(attachment.name)")
        case .ready: L("Uploaded: \(attachment.remotePath)", "Yüklendi: \(attachment.remotePath)")
        case .failed(let reason): L("Upload failed: \(reason)", "Yüklenemedi: \(reason)")
        }
    }
}

/// File names on a sent message.
struct FlowChips: View {
    let names: [String]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(names, id: \.self) { name in
                Label(name, systemImage: "paperclip")
                    .font(.caption)
                    .lineLimit(1)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 7)
                    .background(Color.kervanLapis.opacity(0.1), in: Capsule())
            }
        }
    }
}

struct DropHint: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color.kervanLapis, style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
            .background(Color.kervanLapis.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                Label(L("Drop to upload files to the session's uploads folder and attach them to your message.", "Bırakın; dosyalar oturumun uploads klasörüne yüklenip mesaja eklenecek."), systemImage: "arrow.down.doc")
                    .font(.headline)
                    .foregroundStyle(Color.kervanLapis)
            }
            .padding(12)
            .allowsHitTesting(false)
    }
}

/// The session's working folder on the server: what the user uploaded and what the agent made.
struct FilesPanel: View {
    let sessionID: String
    @Environment(AppModel.self) private var model
    @State private var listing: WorkspaceListing?
    @State private var error: String?
    @State private var downloading: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("Working folder", "Çalışma klasörü")).font(.headline)
                Spacer()
                Button {
                    Task { await load() }
                } label: {
                    Label(L("Refresh", "Yenile"), systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(L("Refresh the list", "Listeyi yenile"))
            }
            .padding(12)

            Divider()

            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.kervanCoral)
                    .padding(12)
            } else if let listing, listing.entries.isEmpty {
                Text(L("The folder is empty. Drop files on the chat or ask the agent to make something.", "Klasör boş. Sohbete dosya sürükleyin ya da ajandan bir şey üretmesini isteyin."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else if let listing {
                List(listing.entries) { entry in
                    row(entry)
                }
                .listStyle(.plain)
                if listing.truncated {
                    Text(L("The list is cut short; showing the first 5000 items.", "Liste kısaltıldı; ilk 5000 öğe gösteriliyor."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity).padding()
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .task(id: refreshKey) { await load() }
    }

    /// Reload whenever the session's status changes: a finished turn may have written files.
    private var refreshKey: String {
        "\(sessionID)-\(model.store.session(sessionID)?.status.rawValue ?? "")"
    }

    private func row(_ entry: WorkspaceEntry) -> some View {
        HStack(spacing: 6) {
            Image(systemName: entry.type == .dir ? "folder" : "doc")
                .foregroundStyle(entry.type == .dir ? Color.kervanLapis : .secondary)
            Text(entry.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if entry.type == .file {
                Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if downloading.contains(entry.path) {
                    ProgressView().controlSize(.mini)
                } else {
                    Button {
                        Task { await download(entry) }
                    } label: {
                        Image(systemName: "arrow.down.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(L("Download to the Downloads folder", "İndirilenler klasörüne indir"))
                    .accessibilityLabel(L("Download \(entry.name)", "\(entry.name) dosyasını indir"))
                }
            }
        }
        .padding(.leading, CGFloat(entry.depth) * 14)
        .accessibilityElement(children: .contain) // keep the download button reachable on its own
    }

    private func load() async {
        guard let client = model.fileClient else { return }
        do {
            listing = try await client.list(sessionID: sessionID)
            error = nil
        } catch {
            self.error = L("Couldn't load files: \(error.localizedDescription)", "Dosyalar alınamadı: \(error.localizedDescription)")
        }
    }

    private func download(_ entry: WorkspaceEntry) async {
        guard let client = model.fileClient else { return }
        downloading.insert(entry.path)
        defer { downloading.remove(entry.path) }
        do {
            let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("Kervan")
            let saved = try await client.download(sessionID: sessionID, path: entry.path, into: folder)
            NSWorkspace.shared.activateFileViewerSelecting([saved])
        } catch {
            self.error = L("Download failed: \(error.localizedDescription)", "İndirilemedi: \(error.localizedDescription)")
        }
    }
}
