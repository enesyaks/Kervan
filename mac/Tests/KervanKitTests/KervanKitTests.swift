import Foundation
import Testing
@testable import KervanKit

@Suite struct ServerAddressTests {
    @Test(arguments: [
        ("kervan", "ws://kervan:7420/v1/ws"),
        ("  kervan:7500 ", "ws://kervan:7500/v1/ws"),
        ("ws://100.66.121.56", "ws://100.66.121.56:7420/v1/ws"),
        ("http://kervan:7420/health", "ws://kervan:7420/v1/ws"),
        ("https://kervan.example.ts.net", "wss://kervan.example.ts.net:7420/v1/ws"),
    ])
    func normalises(input: String, expected: String) {
        #expect(ServerAddress(input)?.url.absoluteString == expected)
    }

    @Test(arguments: ["", "   ", "ftp://kervan", "ws://"])
    func rejects(input: String) {
        #expect(ServerAddress(input) == nil)
    }

    @Test func exposesHost() {
        #expect(ServerAddress("kervan")?.host == "kervan")
    }
}

@Suite struct ProtocolTests {
    @Test func encodesHello() throws {
        let json = try ClientMessage.hello(client: PeerInfo(name: "Kervan for Mac", version: "0.1.0")).jsonString()
        #expect(json == #"{"client":{"name":"Kervan for Mac","version":"0.1.0"},"protocol":1,"type":"hello"}"#)
    }

    @Test func encodesPing() throws {
        #expect(try ClientMessage.ping(id: "p1").jsonString() == #"{"id":"p1","type":"ping"}"#)
    }

    @Test func decodesWelcome() throws {
        let message = try ServerMessage.decode(#"{"type":"welcome","protocol":1,"server":{"name":"kervan","version":"0.1.0"}}"#)
        #expect(message == .welcome(protocolVersion: 1, server: PeerInfo(name: "kervan", version: "0.1.0")))
    }

    @Test func decodesPongAndError() throws {
        #expect(try ServerMessage.decode(#"{"type":"pong","id":"p1"}"#) == .pong(id: "p1"))
        #expect(
            try ServerMessage.decode(#"{"type":"error","code":"bad_message","message":"nope"}"#)
                == .error(code: "bad_message", message: "nope", id: nil)
        )
    }

    @Test func toleratesUnknownTypes() throws {
        #expect(try ServerMessage.decode(#"{"type":"session.created","foo":1}"#) == .unknown(type: "session.created"))
    }
}

@Suite struct BackoffTests {
    @Test func growsThenCaps() {
        #expect((1...7).map(Backoff.delay(attempt:)) == [1, 2, 4, 8, 16, 30, 30])
    }

    @Test func onlyNetworkFailuresRetry() {
        #expect(ConnectionFailure.unreachable("x").isRetryable)
        #expect(!ConnectionFailure.unauthorized.isRetryable)
        #expect(!ConnectionFailure.unsupportedProtocol("x").isRetryable)
    }
}
