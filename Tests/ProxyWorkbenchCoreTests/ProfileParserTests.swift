import XCTest
@testable import ProxyWorkbenchCore

final class ProfileParserTests: XCTestCase {
    func testParserReadsCoreSections() throws {
        let source = """
        [General]
        loglevel = notify

        [Proxy]
        ProxyHTTP = http, 1.2.3.4, 8080, user, pass
        ProxySS = ss, example.com, 8388, aes-128-gcm, secret, udp-relay=true

        [Proxy Group]
        Auto = url-test, ProxyHTTP, ProxySS, url=http://www.gstatic.com/generate_204

        [Rule]
        DOMAIN-SUFFIX, example.com, Auto
        IP-CIDR, 10.0.0.0/8, DIRECT
        FINAL, ProxyHTTP
        """
        let profile = ProfileParser.parse(source)

        XCTAssertEqual(profile.general["loglevel"], "notify")
        XCTAssertEqual(profile.proxies.count, 2)
        XCTAssertEqual(profile.proxies[0].name, "ProxyHTTP")
        XCTAssertEqual(profile.proxies[0].kind, .http)
        XCTAssertEqual(profile.proxies[0].port, 8080)
        XCTAssertEqual(profile.proxies[1].parameters["method"], "aes-128-gcm")
        XCTAssertEqual(profile.groups.first?.policies, ["ProxyHTTP", "ProxySS"])
        XCTAssertEqual(profile.rules.count, 3)
        XCTAssertTrue(profile.warnings.isEmpty)

        let summary = ProfileImportSummary(profile: profile, sourceText: source)
        XCTAssertEqual(summary.proxies, 2)
        XCTAssertEqual(summary.groups, 1)
        XCTAssertEqual(summary.rules, 3)
        XCTAssertEqual(summary.ruleSets, 0)
        XCTAssertEqual(summary.warnings, 0)
        XCTAssertEqual(summary.unsupportedSectionDescription, "None")
    }

    func testRuleEngineMatchesDomainCIDRAndFallback() throws {
        let profile = ProfileParser.parse("""
        [Proxy]
        Proxy = http, 1.2.3.4, 8080

        [Rule]
        DOMAIN-SUFFIX, apple.com, DIRECT
        DOMAIN-KEYWORD, example, Proxy
        DOMAIN-WILDCARD, *.internal.test, DIRECT
        URL-REGEX, ^https://api\\.regex\\.test/v[0-9]+/, Proxy
        IP-CIDR, 10.0.0.0/8, DIRECT
        IP-CIDR6, 2001:db8:abcd::/48, DIRECT
        DEST-PORT, 8443;9000-9002, Proxy
        FINAL, Proxy
        """)

        let engine = RuleEngine(rules: profile.rules)
        XCTAssertEqual(engine.firstMatch(for: "https://www.apple.com/store")?.rule.policy, "DIRECT")
        XCTAssertEqual(engine.firstMatch(for: "api.example.net")?.rule.policy, "Proxy")
        XCTAssertEqual(engine.firstMatch(for: "dev.internal.test")?.reason, "Domain wildcard")
        XCTAssertEqual(engine.firstMatch(for: "https://api.regex.test/v2/users")?.reason, "URL regex")
        XCTAssertEqual(engine.firstMatch(for: "10.2.3.4")?.rule.policy, "DIRECT")
        XCTAssertEqual(engine.firstMatch(for: "http://[2001:db8:abcd::42]/status")?.reason, "IPv6 CIDR")
        XCTAssertEqual(engine.firstMatch(for: "portonly.test:9001")?.reason, "Destination port")
        XCTAssertEqual(engine.firstMatch(for: "openai.com")?.rule.type, "FINAL")
    }

    func testGeneralBypassMatcherReadsSkipProxyAndBypassTun() throws {
        let profile = ProfileParser.parse("""
        [General]
        skip-proxy = 10.0.0.0/8, localhost, *.local
        bypass-tun = fc00::/7

        [Rule]
        FINAL,REJECT
        """)

        let matcher = GeneralBypassMatcher(profile: profile)
        XCTAssertEqual(matcher.firstMatch(for: "10.2.3.4")?.reason, "IPv4 bypass CIDR")
        XCTAssertEqual(matcher.firstMatch(for: "http://printer.local/status")?.reason, "Bypass domain wildcard")
        XCTAssertEqual(matcher.firstMatch(for: "localhost:8080")?.reason, "Bypass host")
        XCTAssertEqual(matcher.firstMatch(for: "http://[fd00::42]/status")?.reason, "IPv6 bypass CIDR")
        XCTAssertNil(matcher.firstMatch(for: "example.com"))
    }

    func testRouteProbeMatchesLocalProxyOrderAndExpandedRuleSets() throws {
        let profile = ProfileParser.parse("""
        [General]
        skip-proxy = localhost

        [Proxy]
        Proxy = http, 1.2.3.4, 8080

        [Rule]
        DOMAIN,localhost,REJECT
        RULE-SET,https://example.test/rules.list,Proxy
        FINAL,DIRECT
        """)
        let ruleSets = [
            "https://example.test/rules.list": [
                ProxyRule(type: "DOMAIN-SUFFIX", value: "expanded.test", policy: "Proxy", options: [], sourceLine: 20, rawLine: "DOMAIN-SUFFIX,expanded.test")
            ]
        ]

        let probe = RouteProbe(profile: profile, ruleSetsByURL: ruleSets)
        let bypass = probe.evaluate("localhost:8080")
        XCTAssertEqual(bypass.source, "General")
        XCTAssertEqual(bypass.policy, "DIRECT")

        let expanded = probe.evaluate("api.expanded.test")
        XCTAssertEqual(expanded.source, "Rule")
        XCTAssertEqual(expanded.policy, "Proxy")
        XCTAssertEqual(expanded.policyPath, "Proxy")
        XCTAssertEqual(expanded.outbound, "Proxy (HTTP, 1.2.3.4:8080)")
        XCTAssertEqual(expanded.rule, "DOMAIN-SUFFIX, expanded.test")

        let fallback = probe.evaluate("unmatched.example")
        XCTAssertEqual(fallback.source, "Rule")
        XCTAssertEqual(fallback.policy, "DIRECT")
        XCTAssertEqual(fallback.policyPath, "DIRECT")
        XCTAssertEqual(fallback.outbound, "DIRECT")
        XCTAssertEqual(fallback.rule, "FINAL")
    }

    func testPolicyResolverExplainsGroupPathToSelectedProxy() throws {
        let profile = ProfileParser.parse("""
        [Proxy]
        Fast = http, fast.example.test, 8080
        Slow = http, slow.example.test, 8080

        [Proxy Group]
        Proxies = select, Slow, Fast
        AI = select, Proxies, DIRECT

        [Rule]
        DOMAIN-SUFFIX,openai.com,AI
        FINAL,DIRECT
        """)

        let probe = RouteProbe(profile: profile, groupSelections: ["Proxies": "Fast", "AI": "Proxies"])
        let result = probe.evaluate("chat.openai.com")

        XCTAssertEqual(result.policy, "AI")
        XCTAssertEqual(result.policyPath, "AI -> Proxies -> Fast")
        XCTAssertEqual(result.outbound, "Fast (HTTP, fast.example.test:8080)")
    }

    func testParserDropsSubscriptionMetadataFromProxyGroups() throws {
        let profile = ProfileParser.parse("""
        [Proxy]
        31.41 G | 500.00 G = trojan, proxy.example.test, 18757, password=fake-password, sni=example.com
        Traffic Reset: 8 Days Left = trojan, proxy.example.test, 18757, password=fake-password, sni=example.com
        Expire Date: 2026/11/15 = trojan, proxy.example.test, 18757, password=fake-password, sni=example.com
        Hong Kong 01 = trojan, proxy.example.test, 18757, password=fake-password, sni=example.com
        Hong Kong 02 = trojan, proxy.example.test, 18758, password=fake-password, sni=example.com

        [Proxy Group]
        Proxies = select, icon-url=https://example.test/icon.png, 31.41 G | 500.00 G, Traffic Reset: 8 Days Left, Expire Date: 2026/11/15, Hong Kong 01, Hong Kong 02

        [Rule]
        FINAL,Proxies
        """)

        XCTAssertEqual(profile.groups.first?.policies, ["Hong Kong 01", "Hong Kong 02"])
        XCTAssertEqual(profile.groups.first?.parameters["icon-url"], "https://example.test/icon.png")
        XCTAssertTrue(profile.warnings.contains { $0.message.contains("31.41 G | 500.00 G") })

        let result = RouteProbe(profile: profile).evaluate("www.google.com")
        XCTAssertEqual(result.policyPath, "Proxies -> Hong Kong 01")
    }

    func testParserWarnsForRuleTypesNotMatchedLocally() throws {
        let profile = ProfileParser.parse("""
        [Proxy]
        Proxy = http, 1.2.3.4, 8080

        [Rule]
        PROCESS-NAME, Safari, Proxy
        URL-REGEX, [, Proxy
        RULE-SET,https://example.test/list.conf,Proxy
        FINAL,Proxy
        """)

        XCTAssertTrue(profile.warnings.contains { $0.message.contains("Rule type 'PROCESS-NAME'") })
        XCTAssertTrue(profile.warnings.contains { $0.message.contains("URL-REGEX pattern is invalid") })
        XCTAssertFalse(profile.warnings.contains { $0.message.contains("Rule type 'RULE-SET'") })
    }

    func testSanitizedExportRedactsSecrets() throws {
        let profile = ProfileParser.parse("""
        [General]
        http-api = password@127.0.0.1:6171

        [Proxy]
        ProxyHTTP = http, 1.2.3.4, 8080, user, secret, client-key=abc
        """)

        let json = ProfileExporter.sanitizedJSON(from: profile)
        XCTAssertTrue(json.contains("********"))
        XCTAssertFalse(json.contains("secret"))
        XCTAssertFalse(json.contains("client-key\\\" : \\\"abc"))
    }

    func testTrojanKeyValuePasswordAndQuotedGroups() throws {
        let profile = ProfileParser.parse("""
        [General]
        encrypted-dns-server = https://dns.example.test/dns-query/fake-token

        [Ponte]
        server-proxy-name = Hong Kong 01

        [Proxy]
        Hong Kong 01 = trojan, proxy.example.test, 18757, password=fake-password, tfo=true, skip-cert-verify=true, sni=example.com
        Usage 9 GB = trojan, proxy.example.test, 18758, fake-positional-password, tfo=true

        [Proxy Group]
        Proxies = select, "Usage 9 GB", "Hong Kong 01", DIRECT, icon-url=https://example.test/icon.png

        [Rule]
        RULE-SET,https://example.test/rules.list,Proxies,update-interval=86400
        GEOIP,CN,DIRECT
        FINAL,Proxies
        """)

        XCTAssertEqual(profile.proxies.count, 2)
        XCTAssertEqual(profile.proxies.first?.kind, .trojan)
        XCTAssertEqual(profile.proxies.first?.password, "fake-password")
        XCTAssertEqual(profile.proxies.first?.parameters["sni"], "example.com")
        XCTAssertEqual(profile.proxies.last?.password, "fake-positional-password")
        XCTAssertEqual(profile.groups.first?.policies, ["Usage 9 GB", "Hong Kong 01", "DIRECT"])
        XCTAssertEqual(profile.groups.first?.parameters["icon-url"], "https://example.test/icon.png")
        XCTAssertEqual(profile.rules.count, 3)
        XCTAssertTrue(profile.warnings.contains { $0.message.contains("[Ponte]") })
        XCTAssertTrue(profile.warnings.contains { $0.message.contains("Rule type 'GEOIP'") })

        let json = ProfileExporter.sanitizedJSON(from: profile)
        XCTAssertFalse(json.contains("fake-password"))
        XCTAssertFalse(json.contains("fake-positional-password"))
    }

    func testProfileSourceDecoderAcceptsPlainAndBase64Profiles() throws {
        let plain = """
        [Proxy]
        Direct = direct

        [Rule]
        FINAL,DIRECT
        """

        XCTAssertEqual(try ProfileSourceDecoder.decodedText(from: Data(plain.utf8)), plain)

        let encoded = Data(plain.utf8).base64EncodedString()
        XCTAssertEqual(try ProfileSourceDecoder.decodedText(from: Data(encoded.utf8)), plain)
    }
}
