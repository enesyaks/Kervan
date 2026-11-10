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

@Suite struct WordingTests {
    // In the tests' language, English: the language is shared by tests running at the same time, so it isn't switched here.
    @Test func countsFiles() {
        #expect(fileCount(1) == "1 file")
        #expect(fileCount(2) == "2 files")
    }

    @Test func translatesOnlyTheServersFixedSentences() {
        #expect(ServerWording.translated("ACP connection closed") == "The connection to the agent closed.")
        #expect(ServerWording.translated("an agent's own words") == "an agent's own words")
    }
}

@Suite struct MacNodeTests {
    @Test func flagsADifferentNodeVersionOfThisMac() {
        let nodes = [NodeInfo(name: "mac", connected: true, version: "0.3.10"), NodeInfo(name: "other", connected: true, version: "0.1.0")]
        #expect(MacNode.outdatedVersion(in: nodes, named: "mac", current: "0.3.18") == "0.3.10")
        #expect(MacNode.outdatedVersion(in: nodes, named: "mac", current: "0.3.10") == nil)
        #expect(MacNode.outdatedVersion(in: nodes, named: "mac", current: "0.3.2") == "0.3.10")
        #expect(MacNode.outdatedVersion(in: nodes, named: nil, current: "0.3.18") == nil)
        #expect(MacNode.outdatedVersion(in: nodes, named: "gone", current: "0.3.18") == nil)
        #expect(MacNode.outdatedVersion(in: [NodeInfo(name: "mac", connected: false)], named: "mac", current: "0.3.18") == nil)
    }

    @Test func suggestsANameFromTheHostName() {
        #expect(MacNode.suggestedName(from: "Enes's MacBook Pro.local") == "enes-s-macbook-pro")
        #expect(MacNode.suggestedName(from: "local") == "mac")
        #expect(MacNode.suggestedName(from: "") == "mac")
        #expect(MacNode.isValidName(MacNode.suggestedName(from: "İşçi--Makine")))
        #expect(MacNode.suggestedName(from: String(repeating: "a", count: 50)).count == 32)
    }

    @Test func checksNames() {
        for good in ["macbook", "a", "mac-2"] { #expect(MacNode.isValidName(good), "\(good)") }
        for bad in ["", "local", "-mac", "Mac", "a b", "a;b", String(repeating: "a", count: 33)] { #expect(!MacNode.isValidName(bad), "\(bad)") }
    }

    @Test func keepsEveryArgumentOneWordForTheShell() {
        let command = MacNode.installCommand(script: "/Applications/My Apps/Kervan's.app/x.sh", hub: "h.ts.net:7420", code: "abc", name: "mac", log: "/tmp/a b.log")
        #expect(command == "'/bin/bash' '/Applications/My Apps/Kervan'\\''s.app/x.sh' 'install' '--hub' 'http://h.ts.net:7420' '--code' 'abc' '--name' 'mac' >> '/tmp/a b.log' 2>&1")
        #expect(MacNode.removeCommand(script: "/x.sh", log: "/l") == "'/bin/bash' '/x.sh' 'remove' >> '/l' 2>&1")
        #expect(MacNode.keepAwakeCommand(script: "/x.sh", on: true, log: "/l") == "'/bin/bash' '/x.sh' 'keep-awake' 'on' >> '/l' 2>&1")
        #expect(MacNode.keepAwakeCommand(script: "/x.sh", on: false, log: "/l") == "'/bin/bash' '/x.sh' 'keep-awake' 'off' >> '/l' 2>&1")
    }

    @Test func commandReachesTheShellIntactThroughAppleScript() throws {
        // Run for real, without the prompt: what could break is the quoting between AppleScript and the shell.
        var arguments = MacNode.adminArguments(for: #"printf %s 'a "b" \c d'"#)
        arguments[1] = arguments[1].replacingOccurrences(of: " with administrator privileges", with: "")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(output.trimmingCharacters(in: .newlines) == #"a "b" \c d"#)
    }

    @Test func tellsAClosedPromptFromAFailure() {
        #expect(MacNode.wasCancelled("0:60: execution error: User canceled. (-128)"))
        #expect(!MacNode.wasCancelled("0:60: execution error: Kervan: this Mac can't reach the hub. (1)"))
    }

    @Test func followsTheSetupsStages() {
        #expect(MacNode.Step.reached(in: "") == .checking)
        #expect(MacNode.Step.reached(in: "==> checking the hub (x)\n==> user and folders\n==> Kervan code\n") == .code)
        #expect(MacNode.Step.reached(in: "==> joining the hub as 'mac'\n==> service\n") == .service)
    }

    @Test func knowsWhetherItsInstalled() {
        #expect(MacNode.isInstalled { $0 == MacNode.service })
        #expect(!MacNode.isInstalled { _ in false })
    }
}

@Suite struct RoleIDTests {
    @Test func acceptsWhatTheServerAccepts() {
        for good in ["inceleyici", "kod-inceleyici", "qa1"] { #expect(Role.isValidID(good), "\(good)") }
        for bad in ["", "-a", "Kod", "kod inceleyici", "şef", "İnceleyici", String(repeating: "a", count: 65)] { #expect(!Role.isValidID(bad), "\(bad)") }
    }
}
