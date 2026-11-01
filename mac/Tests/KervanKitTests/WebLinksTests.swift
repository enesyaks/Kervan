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
