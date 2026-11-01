import Foundation

/// The server token, in a file only this user can read (0600, in a 0700 folder under Application Support),
/// never in UserDefaults.
///
/// Not in the Keychain: Kervan isn't signed with an Apple-issued certificate, and for such apps macOS ties a
/// Keychain item to the exact build, so every update asked for the key again (an open access list doesn't help;
/// the item's partition list still refuses the next build). Any program running as this user could read a file in
/// its home folder anyway, which is the line a Keychain item open to it would draw too.
enum TokenStore {
    /// Per app identity, so a second copy (e.g. a first-run test build) starts without the first one's token.
    private static var file: URL {
        let identity = Bundle.main.bundleIdentifier ?? "com.enes.kervan"
        return URL.applicationSupportDirectory.appending(path: identity, directoryHint: .isDirectory).appending(path: "server-token")
    }

    static func read() -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    static func save(_ token: String) {
        guard read() != token else { return }
        let folder = file.deletingLastPathComponent()
        let manager = FileManager.default
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        // Written private from the start: created 0600, then moved into place.
        let temporary = folder.appending(path: ".server-token-\(UUID().uuidString)")
        guard manager.createFile(atPath: temporary.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600]) else { return }
        _ = try? manager.replaceItemAt(file, withItemAt: temporary)
        if manager.fileExists(atPath: temporary.path) { try? manager.moveItem(at: temporary, to: file) }
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
