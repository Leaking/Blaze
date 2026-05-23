import XCTest
@testable import ProxyWorkbenchCore

final class ProfileSourceEditorTests: XCTestCase {
    func testAddingProxyInsertsIntoProxySection() throws {
        let source = """
        [Proxy]
        Existing = http, 127.0.0.1, 8080

        [Rule]
        FINAL,Existing
        """

        let edited = ProfileSourceEditor.addingProxy(
            name: "Manual SOCKS",
            kind: "socks5",
            host: "10.0.0.2",
            port: 1080,
            username: "user",
            password: "secret",
            to: source
        )

        let profile = ProfileParser.parse(edited)
        let proxy = try XCTUnwrap(profile.proxies.first { $0.name == "Manual SOCKS" })
        XCTAssertEqual(proxy.kind, .socks5)
        XCTAssertEqual(proxy.endpoint, "10.0.0.2:1080")
        XCTAssertEqual(proxy.username, "user")
        XCTAssertEqual(proxy.password, "secret")
        XCTAssertEqual(profile.rules.map(\.rawLine), ["FINAL,Existing"])
    }

    func testAddingTrojanProxyQuotesPasswordValue() throws {
        let edited = ProfileSourceEditor.addingProxy(
            name: "Trojan Manual",
            kind: "trojan",
            host: "proxy.example.com",
            port: 443,
            password: "sec,ret",
            to: ""
        )

        let proxy = try XCTUnwrap(ProfileParser.parse(edited).proxies.first)
        XCTAssertEqual(proxy.kind, .trojan)
        XCTAssertEqual(proxy.password, "sec,ret")
    }

    func testAddingRuleInsertsBeforeFinalRule() throws {
        let source = """
        [Proxy]
        Proxy = http, 1.2.3.4, 8080

        [Rule]
        DOMAIN-SUFFIX,apple.com,DIRECT
        FINAL,Proxy
        """

        let edited = ProfileSourceEditor.addingRule(
            type: "DOMAIN-SUFFIX",
            value: "openai.com",
            policy: "Proxy",
            to: source
        )

        let profile = ProfileParser.parse(edited)
        XCTAssertEqual(profile.rules.map(\.rawLine), [
            "DOMAIN-SUFFIX,apple.com,DIRECT",
            "DOMAIN-SUFFIX,openai.com,Proxy",
            "FINAL,Proxy"
        ])
    }

    func testAddingRuleCreatesRuleSectionWhenMissing() throws {
        let source = """
        [Proxy]
        Proxy = http, 1.2.3.4, 8080
        """

        let edited = ProfileSourceEditor.addingRule(
            type: "DOMAIN",
            value: "example.com",
            policy: "DIRECT",
            to: source
        )

        XCTAssertTrue(edited.contains("[Rule]\nDOMAIN,example.com,DIRECT"))
        XCTAssertEqual(ProfileParser.parse(edited).rules.first?.policy, "DIRECT")
    }

    func testRemovingRuleDeletesMatchingSourceLine() throws {
        let source = """
        [Rule]
        DOMAIN-SUFFIX,apple.com,DIRECT
        DOMAIN-SUFFIX,openai.com,Proxy
        FINAL,Proxy
        """

        let profile = ProfileParser.parse(source)
        let rule = try XCTUnwrap(profile.rules.first { $0.value == "openai.com" })
        let edited = ProfileSourceEditor.removingRule(rule, from: source)

        XCTAssertEqual(ProfileParser.parse(edited).rules.map(\.rawLine), [
            "DOMAIN-SUFFIX,apple.com,DIRECT",
            "FINAL,Proxy"
        ])
    }

    func testRemovingRuleFallsBackToRuleSectionMatch() throws {
        let source = """
        [Rule]
        DOMAIN-SUFFIX,apple.com,DIRECT
        DOMAIN-SUFFIX,openai.com,Proxy
        FINAL,Proxy
        """
        let staleRule = ProxyRule(
            type: "DOMAIN-SUFFIX",
            value: "openai.com",
            policy: "Proxy",
            options: [],
            sourceLine: 99,
            rawLine: "DOMAIN-SUFFIX,openai.com,Proxy"
        )

        let edited = ProfileSourceEditor.removingRule(staleRule, from: source)

        XCTAssertFalse(edited.contains("DOMAIN-SUFFIX,openai.com,Proxy"))
        XCTAssertEqual(ProfileParser.parse(edited).rules.count, 2)
    }
}
