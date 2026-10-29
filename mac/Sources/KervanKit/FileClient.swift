import Foundation

public struct WorkspaceEntry: Decodable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Decodable, Sendable { case file, dir }

    public let path: String
    public let type: Kind
    public let size: Int64
    public let modifiedAt: String

    public var id: String { path }
    public var name: String { path.split(separator: "/").last.map(String.init) ?? path }
    /// Nesting level for indenting a flat, path-sorted list.
    public var depth: Int { path.split(separator: "/").count - 1 }

    public init(path: String, type: Kind, size: Int64, modifiedAt: String) {
        self.path = path
        self.type = type
        self.size = size
        self.modifiedAt = modifiedAt
    }
}

public struct WorkspaceListing: Decodable, Equatable, Sendable {
    public let entries: [WorkspaceEntry]
    public let truncated: Bool
}

public enum FileClientError: Error, Equatable, LocalizedError {
    case http(status: Int)

    public var errorDescription: String? {
        switch self {
        case .http(401): "Sunucu erişim anahtarını kabul etmedi."
        case .http(404): "Dosya ya da oturum sunucuda bulunamadı."
        case .http(413): "Dosya sunucunun kabul ettiği boyuttan büyük."
        case .http(400): "Bu dosya yolu kabul edilmedi."
        case .http(let status): "Sunucu isteği tamamlayamadı (HTTP \(status))."
        }
    }
}

/// Talks to the server's file API (protocol/v1.md, "Files"): list, upload, download.
public struct FileClient: Sendable {
    private let base: URL
    private let token: String
    private let session: URLSession

    public init(address: ServerAddress, token: String, session: URLSession = .shared) {
        self.base = address.httpBase
        self.token = token
        self.session = session
    }

    /// `/v1/sessions/<id>/files[/<path>]`, every segment percent-encoded on its own.
    public func url(sessionID: String, path: String = "") -> URL {
        let segments = ["v1", "sessions", sessionID, "files"] + path.split(separator: "/").map(String.init)
        let encoded = segments.map { $0.addingPercentEncoding(withAllowedCharacters: Self.segmentAllowed) ?? $0 }
        return URL(string: encoded.joined(separator: "/"), relativeTo: base)!.absoluteURL
    }

    public func list(sessionID: String) async throws -> WorkspaceListing {
        let (data, response) = try await session.data(for: request(url(sessionID: sessionID)))
        try Self.check(response)
        return try JSONDecoder().decode(WorkspaceListing.self, from: data)
    }

    public func upload(sessionID: String, file: URL, to path: String) async throws {
        var request = request(url(sessionID: sessionID, path: path))
        request.httpMethod = "PUT"
        let (_, response) = try await session.upload(for: request, fromFile: file)
        try Self.check(response)
    }

    /// Downloads into `folder`, keeping the file name; returns where it landed.
    public func download(sessionID: String, path: String, into folder: URL) async throws -> URL {
        let (temporary, response) = try await session.download(for: request(url(sessionID: sessionID, path: path)))
        try Self.check(response)
        let name = path.split(separator: "/").last.map(String.init) ?? "dosya"
        let destination = Self.freeName(for: folder.appendingPathComponent(name))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static let segmentAllowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))

    private static func check(_ response: URLResponse) throws {
        guard let status = (response as? HTTPURLResponse)?.statusCode else { return }
        guard (200..<300).contains(status) else { throw FileClientError.http(status: status) }
    }

    /// "rapor.pdf" → "rapor 2.pdf" if taken, so a download never overwrites a local file.
    static func freeName(for url: URL) -> URL {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return url }
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        for n in 2... {
            let candidate = url.deletingLastPathComponent().appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            if !manager.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }
}

extension ServerAddress {
    /// The HTTP origin of the same server: ws → http, wss → https.
    public var httpBase: URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "wss" ? "https" : "http"
        components.path = "/"
        return components.url!
    }
}
