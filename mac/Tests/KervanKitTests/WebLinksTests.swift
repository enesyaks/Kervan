import Foundation
import Testing
@testable import KervanKit

@Suite struct WebLinksTests {
    let tailscale = HubAddress(address: "100.66.121.56:7420", kind: .tailscale, host: "kervan.tail1234.ts.net")
    let lan = HubAddress(address: "192.168.1.21:7420", kind: .lan, network: "192.168.1.0/24")

    @Test func listsTailscaleFirstWithItsNameThenTheLan() {
        let links = WebLinks.all(addresses: [lan, tailscale], current: URL(string: "ws://192.168.1.21:7420/v1/ws"))
        #expect(links.map(\.url) == ["http://100.66.121.56:7420", "http://kervan.tail1234.ts.net:7420", "http://192.168.1.21:7420"])
        #expect(links.map(\.reach) == [.tailscale, .tailscale, .lan])
        #expect(links.map(\.isName) == [false, true, false])
    }

    @Test func prefersTailscaleForLinksThatMustWorkAwayFromHome() {
        #expect(WebLinks.preferred(addresses: [lan, tailscale], current: nil) == "http://100.66.121.56:7420")
        #expect(WebLinks.preferred(addresses: [lan], current: URL(string: "ws://kervan:7420/v1/ws")) == "http://192.168.1.21:7420")
    }

    @Test func fallsBackToTheAppsAddressWhenTheHubReportedNone() {
        #expect(WebLinks.all(addresses: [], current: URL(string: "ws://kervan.local:7500/v1/ws")) == [WebLink(url: "http://kervan.local:7500", reach: .current)])
        #expect(WebLinks.all(addresses: [], current: URL(string: "ws://kervan.tail1234.ts.net/v1/ws")).first?.reach == .tailscale)
        #expect(WebLinks.all(addresses: [], current: URL(string: "ws://100.70.1.2:7420/v1/ws")).first?.reach == .tailscale)
        #expect(WebLinks.preferred(addresses: [], current: nil) == nil)
    }

    @Test func knowsWhetherTheHubIsOnTailscale() {
        #expect(WebLinks.hasTailscale([lan, tailscale]))
        #expect(!WebLinks.hasTailscale([lan]))
    }

    @Test func decodesTheMagicDNSNameAndToleratesItsAbsence() throws {
        let json = #"[{"address":"100.66.121.56:7420","kind":"tailscale","host":"kervan.tail1234.ts.net"},{"address":"192.168.1.21:7420","kind":"lan","network":"192.168.1.0/24"}]"#
        let decoded = try JSONDecoder().decode([HubAddress].self, from: Data(json.utf8))
        #expect(decoded == [tailscale, lan])
        #expect(decoded[1].host == nil)
    }
}

@Suite struct HubFallbackTests {
    @Test func knowsATailscaleName() {
        for host in ["kervan.tail1234.ts.net", "KERVAN.TAIL1234.TS.NET"] { #expect(HubFallback.isTailscaleName(host), "\(host)") }
        for host in [".ts.net", "ts.net", "evil-ts.net", "kervan.ts.net.evil.com", "100.92.238.61", ""] { #expect(!HubFallback.isTailscaleName(host), "\(host)") }
    }

    @Test func knowsATailscaleIP() {
        for host in ["100.64.0.1", "100.92.238.61", "100.127.255.255"] { #expect(HubFallback.isTailscaleIP(host), "\(host)") }
        for host in ["100.63.0.1", "100.128.0.1", "192.168.1.32", "100.92.238", "100.92.238.999", "kervan"] { #expect(!HubFallback.isTailscaleIP(host), "\(host)") }
    }

    @Test func remembersOnlyAMagicDNSName() {
        let named = HubAddress(address: "100.92.238.61:7420", kind: .tailscale, host: "kervan-1.tail1.ts.net")
        let lan = HubAddress(address: "192.168.1.32:7420", kind: .lan)
        #expect(HubFallback.address(among: [lan, named], current: "192.168.1.32") == "kervan-1.tail1.ts.net:7420")
        #expect(HubFallback.address(among: [named], current: "100.92.238.61") == "kervan-1.tail1.ts.net:7420")
        #expect(HubFallback.address(among: [named], current: "kervan-1.tail1.ts.net") == nil)
        #expect(HubFallback.address(among: [lan], current: "192.168.1.32") == nil)
        #expect(HubFallback.address(among: [HubAddress(address: "100.92.238.61:7420", kind: .tailscale)], current: "192.168.1.32") == nil)
        // A hub can't talk the app into sending the key to some other name.
        #expect(HubFallback.address(among: [HubAddress(address: "100.92.238.61:7420", kind: .tailscale, host: "evil.example.com")], current: "192.168.1.32") == nil)
    }

    @Test func readsTheNameFromTailscaleStatus() {
        #expect(HubFallback.name(fromStatus: "kervan-1.tail1.ts.net.\n") == "kervan-1.tail1.ts.net")
        #expect(HubFallback.name(fromStatus: "") == nil)
        #expect(HubFallback.name(fromStatus: "something else") == nil)
    }
}

@Suite struct MessageSizeTests {
    @Test func staysUnderTheServersFrameLimit() {
        #expect(SessionStore.fitsInOneMessage("merhaba"))
        #expect(SessionStore.fitsInOneMessage(String(repeating: "x", count: 900_000)))
        #expect(!SessionStore.fitsInOneMessage(String(repeating: "x", count: 1_100_000)))
        #expect(!SessionStore.fitsInOneMessage(String(repeating: "\n", count: 600_000)), "line breaks double in JSON")
    }
}
