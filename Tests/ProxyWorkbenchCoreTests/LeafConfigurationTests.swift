import XCTest
@testable import ProxyWorkbenchCore

final class LeafConfigurationTests: XCTestCase {
    private func minimalConfig(proxies: [LeafConfiguration.Proxy] = [], rules: [LeafConfiguration.Rule] = []) -> LeafConfiguration {
        LeafConfiguration(
            httpPort: 19080,
            socksPort: 19081,
            dnsServers: ["1.1.1.1", "223.5.5.5"],
            boundInterface: "en1",
            logLevel: "info",
            proxies: proxies,
            rules: rules,
            defaultProxy: "DIRECT"
        )
    }

    func testRendersGeneralSectionWithListenPortsAndDns() {
        let conf = minimalConfig().renderConf()
        XCTAssertTrue(conf.contains("[General]"))
        XCTAssertTrue(conf.contains("loglevel = info"))
        XCTAssertTrue(conf.contains("dns-server = 1.1.1.1, 223.5.5.5"))
        XCTAssertTrue(conf.contains("http-interface = 127.0.0.1"))
        XCTAssertTrue(conf.contains("http-port = 19080"))
        XCTAssertTrue(conf.contains("socks-interface = 127.0.0.1"))
        XCTAssertTrue(conf.contains("socks-port = 19081"))
    }

    func testRendersDirectAndDropAsBareProtocols() {
        let conf = minimalConfig(proxies: [
            .init(tag: "DIRECT", protocolName: "direct"),
            .init(tag: "REJECT", protocolName: "drop")
        ]).renderConf()
        XCTAssertTrue(conf.contains("DIRECT = direct"))
        XCTAssertTrue(conf.contains("REJECT = drop"))
        XCTAssertFalse(conf.contains("DIRECT = direct, ")) // no trailing args
    }

    func testRendersTrojanWithSniAndTlsInsecure() {
        let proxy = LeafConfiguration.Proxy(
            tag: "🇭🇰 HK10",
            protocolName: "trojan",
            address: "example.com",
            port: 443,
            password: "secret-pass",
            sni: "cdn.example.com",
            tlsInsecure: true
        )
        let conf = minimalConfig(proxies: [proxy]).renderConf()
        // The tag should survive emoji+space verbatim
        XCTAssertTrue(conf.contains("🇭🇰 HK10 = trojan, example.com, 443"))
        XCTAssertTrue(conf.contains("password=secret-pass"))
        XCTAssertTrue(conf.contains("sni=cdn.example.com"))
        XCTAssertTrue(conf.contains("tls-insecure=true"))
    }

    func testRendersShadowsocks() {
        let proxy = LeafConfiguration.Proxy(
            tag: "SS1",
            protocolName: "shadowsocks",
            address: "1.2.3.4",
            port: 8388,
            password: "pw",
            encryptMethod: "aes-256-gcm"
        )
        let conf = minimalConfig(proxies: [proxy]).renderConf()
        XCTAssertTrue(conf.contains("SS1 = shadowsocks, 1.2.3.4, 8388"))
        XCTAssertTrue(conf.contains("password=pw"))
        XCTAssertTrue(conf.contains("encrypt-method=aes-256-gcm"))
    }

    func testRendersFinalRule() {
        let conf = minimalConfig(rules: [.final("🇭🇰 HK10")]).renderConf()
        XCTAssertTrue(conf.contains("[Rule]"))
        XCTAssertTrue(conf.contains("FINAL, 🇭🇰 HK10"))
    }

    func testRendersDomainSuffixRule() {
        let rule = LeafConfiguration.Rule(kind: "DOMAIN-SUFFIX", value: "example.com", target: "DIRECT")
        let conf = minimalConfig(rules: [rule, .final("DIRECT")]).renderConf()
        XCTAssertTrue(conf.contains("DOMAIN-SUFFIX, example.com, DIRECT"))
        XCTAssertTrue(conf.contains("FINAL, DIRECT"))
    }

    func testEqualityIgnoresOrderingOfExtraDict() {
        // Two configurations that differ only in the ordering of the `extra`
        // dictionary should still hash-equal, because Swift's auto-derived
        // Hashable treats Dictionary identically regardless of insertion order.
        let a = LeafConfiguration.Proxy(
            tag: "T",
            protocolName: "trojan",
            address: "h",
            port: 1,
            password: "p",
            extra: ["a": "1", "b": "2"]
        )
        let b = LeafConfiguration.Proxy(
            tag: "T",
            protocolName: "trojan",
            address: "h",
            port: 1,
            password: "p",
            extra: ["b": "2", "a": "1"]
        )
        XCTAssertEqual(a, b)
    }

    func testWsAndWsPathRender() {
        let proxy = LeafConfiguration.Proxy(
            tag: "T",
            protocolName: "trojan",
            address: "h",
            port: 443,
            password: "p",
            ws: true,
            wsPath: "/ws",
            wsHost: "edge.example.com"
        )
        let conf = minimalConfig(proxies: [proxy]).renderConf()
        XCTAssertTrue(conf.contains("ws=true"))
        XCTAssertTrue(conf.contains("ws-path=/ws"))
        XCTAssertTrue(conf.contains("ws-host=edge.example.com"))
    }
}
