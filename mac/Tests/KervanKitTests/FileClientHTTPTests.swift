import Foundation
import Testing
@testable import KervanKit

/// Answers `URLSession` from memory and records what it was asked.
private final class StubServer: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var seen: [URLRequest] = []
    nonisolated(unsafe) private static var answer: @Sendable (URLRequest) -> (Int, Data) = { _ in (200, Data()) }

    static func reset(_ newAnswer: @escaping @Sendable (URLRequest) -> (Int, Data)) {
        lock.withLock {
            seen = []
            answer = newAnswer
        }
    }

    static var requests: [URLRequest] { lock.withLock { seen } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let (status, body) = Self.lock.withLock { () -> (Int, Data) in
            Self.seen.append(request)
            return Self.answer(request)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite(.serialized) struct FileClientHTTPTests {
    private let client: FileClient = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubServer.self]
        return FileClient(address: ServerAddress("kervan")!, token: "secret", session: URLSession(configuration: configuration))
    }()

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kervan-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test func listsASessionsFilesWithTheAccessKey() async throws {
        StubServer.reset { _ in (200, Data(#"{"entries":[{"path":"src/a b.swift","type":"file","size":3,"modifiedAt":"t"},{"path":"src","type":"dir","size":0,"modifiedAt":"t"}],"truncated":true}"#.utf8)) }
        let listing = try await client.list(sessionID: "s/1")
        #expect(listing.truncated)
        #expect(listing.entries.map(\.name) == ["a b.swift", "src"])
        #expect(listing.entries[0].id == "src/a b.swift" && listing.entries[0].depth == 1 && listing.entries[1].type == .dir)
        let request = try #require(StubServer.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(request.url?.absoluteString == "http://kervan:7420/v1/sessions/s%2F1/files", "an id can't change the path")
    }

    @Test func turnsAnHTTPErrorIntoItsMeaning() async throws {
        for (status, word) in [(401, "key"), (404, "found"), (413, "larger"), (400, "path"), (500, "500")] {
            StubServer.reset { _ in (status, Data()) }
            do {
                _ = try await client.list(sessionID: "s")
                Issue.record("\(status) must throw")
            } catch let error as FileClientError {
                #expect(error == .http(status: status))
                #expect(error.errorDescription?.contains(word) == true, "\(status)")
            }
        }
        #expect(FileClientError.notASkill.errorDescription?.contains("SKILL.md") == true)
    }

    @Test func uploadsWithPutToThePathGiven() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("a.txt")
        try write("hello", to: file)
        StubServer.reset { _ in (200, Data()) }
        try await client.upload(sessionID: "s", file: file, to: "docs/a b.txt")
        let request = try #require(StubServer.requests.first)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.absoluteString == "http://kervan:7420/v1/sessions/s/files/docs/a%20b.txt")

        StubServer.reset { _ in (413, Data()) }
        await #expect(throws: FileClientError.http(status: 413)) { try await client.upload(sessionID: "s", file: file, to: "a") }
    }

    @Test func downloadsNextToWhatIsThereWithoutOverwritingIt() async throws {
        let folder = try folder().appendingPathComponent("new")
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        StubServer.reset { _ in (200, Data("body".utf8)) }
        let first = try await client.download(sessionID: "s", path: "dir/rapor.pdf", into: folder)
        #expect(first.lastPathComponent == "rapor.pdf")
        let second = try await client.download(sessionID: "s", path: "dir/rapor.pdf", into: folder)
        #expect(second.lastPathComponent == "rapor 2.pdf")
        #expect(try Data(contentsOf: first) == Data("body".utf8))

        StubServer.reset { _ in (404, Data("not the file".utf8)) }
        await #expect(throws: FileClientError.http(status: 404)) { _ = try await client.download(sessionID: "s", path: "gone.pdf", into: folder) }
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("gone.pdf").path), "an error page isn't saved as the file")
    }

    @Test func listsAndDeletesSkills() async throws {
        StubServer.reset { _ in (200, Data(#"{"skills":[{"name":"rapor","description":"d","files":2}]}"#.utf8)) }
        let skills = try await client.listSkills()
        #expect(skills == [SkillInfo(name: "rapor", description: "d", files: 2)])
        #expect(skills[0].id == "rapor")
        #expect(StubServer.requests.first?.url?.absoluteString == "http://kervan:7420/v1/skills")

        StubServer.reset { _ in (200, Data()) }
        try await client.deleteSkill("a/b")
        #expect(StubServer.requests.first?.httpMethod == "DELETE")
        #expect(StubServer.requests.first?.url?.absoluteString == "http://kervan:7420/v1/skills/a%2Fb")
    }

    @Test func uploadsASkillsMarkerLastWhateverTheFolderHolds() async throws {
        let folder = try folder().appendingPathComponent("Rapor Şablonu")
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        for index in 0..<120 { try write("x", to: folder.appendingPathComponent("files/\(index).md")) }
        try write("x", to: folder.appendingPathComponent("SKILL.md"))
        try write("x", to: folder.appendingPathComponent(".DS_Store"))
        StubServer.reset { _ in (200, Data()) }

        #expect(try await client.uploadSkill(folder: folder) == "rapor-sablonu")
        let paths = StubServer.requests.compactMap(\.url?.path)
        #expect(paths.count == 121, "hidden files stay behind")
        #expect(paths.last == "/v1/skills/rapor-sablonu/SKILL.md", "the server lists a skill once SKILL.md arrives")
        #expect(StubServer.requests.allSatisfy { $0.httpMethod == "PUT" })
    }

    @Test func stopsAtAFailedSkillFileSoTheSkillNeverAppearsHalfDone() async throws {
        let folder = try folder().appendingPathComponent("yarim")
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        try write("x", to: folder.appendingPathComponent("a.md"))
        try write("x", to: folder.appendingPathComponent("SKILL.md"))
        StubServer.reset { _ in (500, Data()) }
        await #expect(throws: FileClientError.http(status: 500)) { try await client.uploadSkill(folder: folder) }
        #expect(StubServer.requests.compactMap(\.url?.lastPathComponent) == ["a.md"])
    }

    @Test func refusesAFolderThatIsntASkill() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write("x", to: folder.appendingPathComponent("readme.md"))
        StubServer.reset { _ in (200, Data()) }
        await #expect(throws: FileClientError.notASkill) { try await client.uploadSkill(folder: folder) }
        #expect(StubServer.requests.isEmpty)
    }
}
