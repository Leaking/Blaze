import Darwin
import Foundation
@testable import ProxyWorkbenchCore
import XCTest

final class LocalHTTPProxyServerTests: XCTestCase {
    func testPlainHTTPForwardingToLocalServer() async throws {
        let origin = try TinyHTTPServer(responseBody: "proxy-ok")
        defer { origin.stop() }

        let logStore = ProxyEventStore()
        let proxy = LocalHTTPProxyServer(logStore: logStore)
        let proxyPort = try freeLoopbackPort()
        try await proxy.start(port: proxyPort)
        defer {
            Task { await proxy.stop() }
        }

        let clientFD = try connectLoopback(port: proxyPort)
        defer { close(clientFD) }

        let request = """
        GET http://127.0.0.1:\(origin.port)/hello?x=1 HTTP/1.1\r
        Host: 127.0.0.1:\(origin.port)\r
        Connection: close\r
        \r

        """
        try sendAll(request, to: clientFD)
        let response = readAll(from: clientFD)

        XCTAssertTrue(response.contains("200 OK"))
        XCTAssertTrue(response.contains("proxy-ok"))

        try? await Task.sleep(nanoseconds: 150_000_000)
        let events = await logStore.events()
        XCTAssertEqual(events.first?.method, "GET")
        XCTAssertEqual(events.first?.host, "127.0.0.1")
        XCTAssertEqual(events.first?.port, origin.port)
        XCTAssertEqual(events.first?.policy, "DIRECT")
        XCTAssertEqual(events.first?.status, "Connected")
    }

    func testProxyEventStoreAggregatesPolicyHits() async throws {
        let store = ProxyEventStore()
        await store.append(ProxyServerEvent(method: "GET", target: "http://a.test", host: "a.test", port: 80, policy: "Proxy", status: "Connected", rule: "DOMAIN-SUFFIX, test", note: "first"))
        await store.append(ProxyServerEvent(method: "GET", target: "http://b.test", host: "b.test", port: 80, policy: "Proxy", status: "Connected", rule: "DOMAIN-SUFFIX, test", note: "second"))
        await store.append(ProxyServerEvent(method: "GET", target: "http://c.test", host: "c.test", port: 80, policy: "DIRECT", status: "Rejected", rule: "FINAL", note: "third"))

        let stats = await store.policyHitStats()
        XCTAssertEqual(stats.first, ProxyPolicyHitStat(policy: "Proxy", status: "Connected", count: 2))
        XCTAssertTrue(stats.contains(ProxyPolicyHitStat(policy: "DIRECT", status: "Rejected", count: 1)))

        let ruleStats = await store.ruleHitStats()
        XCTAssertEqual(ruleStats.first, ProxyRuleHitStat(rule: "DOMAIN-SUFFIX, test", status: "Connected", count: 2))
        XCTAssertTrue(ruleStats.contains(ProxyRuleHitStat(rule: "FINAL", status: "Rejected", count: 1)))

        await store.clear()
        let clearedStats = await store.policyHitStats()
        let clearedRuleStats = await store.ruleHitStats()
        XCTAssertTrue(clearedStats.isEmpty)
        XCTAssertTrue(clearedRuleStats.isEmpty)
    }

    func testConnectionFailureLogPreservesRequestContext() async throws {
        let unreachablePort = try freeLoopbackPort()
        let logStore = ProxyEventStore()
        let proxy = LocalHTTPProxyServer(logStore: logStore)
        let proxyPort = try freeLoopbackPort()
        try await proxy.start(port: proxyPort)
        defer {
            Task { await proxy.stop() }
        }

        let clientFD = try connectLoopback(port: proxyPort)
        defer { close(clientFD) }

        let request = """
        GET http://127.0.0.1:\(unreachablePort)/unreachable HTTP/1.1\r
        Host: 127.0.0.1:\(unreachablePort)\r
        Connection: close\r
        \r

        """
        try sendAll(request, to: clientFD)
        let response = readAll(from: clientFD)

        XCTAssertTrue(response.contains("502 Bad Gateway"))

        try? await Task.sleep(nanoseconds: 150_000_000)
        let events = await logStore.events()
        XCTAssertEqual(events.first?.method, "GET")
        XCTAssertEqual(events.first?.host, "127.0.0.1")
        XCTAssertEqual(events.first?.port, unreachablePort)
        XCTAssertEqual(events.first?.policy, "DIRECT")
        XCTAssertEqual(events.first?.status, "Failed")
        XCTAssertTrue(events.first?.note.contains("connect failed") == true)
    }

    func testRejectRuleBlocksRequestBeforeOriginConnection() async throws {
        let origin = try TinyHTTPServer(responseBody: "should-not-load")
        defer { origin.stop() }

        let logStore = ProxyEventStore()
        let proxy = LocalHTTPProxyServer(
            logStore: logStore,
            routingRules: [
                ProxyRule(type: "DOMAIN", value: "127.0.0.1", policy: "REJECT", options: [], sourceLine: 1, rawLine: "DOMAIN,127.0.0.1,REJECT"),
                ProxyRule(type: "FINAL", value: "", policy: "DIRECT", options: [], sourceLine: 2, rawLine: "FINAL,DIRECT")
            ]
        )
        let proxyPort = try freeLoopbackPort()
        try await proxy.start(port: proxyPort)
        defer {
            Task { await proxy.stop() }
        }

        let clientFD = try connectLoopback(port: proxyPort)
        defer { close(clientFD) }

        let request = """
        GET http://127.0.0.1:\(origin.port)/blocked HTTP/1.1\r
        Host: 127.0.0.1:\(origin.port)\r
        Connection: close\r
        \r

        """
        try sendAll(request, to: clientFD)
        let response = readAll(from: clientFD)

        XCTAssertTrue(response.contains("403 Forbidden"))
        XCTAssertFalse(response.contains("should-not-load"))

        try? await Task.sleep(nanoseconds: 150_000_000)
        let events = await logStore.events()
        XCTAssertEqual(events.first?.method, "GET")
        XCTAssertEqual(events.first?.policy, "REJECT")
        XCTAssertEqual(events.first?.status, "Rejected")
    }

    func testGeneralSkipProxyBypassesRejectRules() async throws {
        let origin = try TinyHTTPServer(responseBody: "skip-proxy-ok")
        defer { origin.stop() }

        let logStore = ProxyEventStore()
        let proxy = LocalHTTPProxyServer(
            logStore: logStore,
            routingProfile: ProxyProfile(
                general: ["skip-proxy": "127.0.0.0/8, localhost, *.local"],
                rules: [
                    ProxyRule(type: "DOMAIN", value: "127.0.0.1", policy: "REJECT", options: [], sourceLine: 1, rawLine: "DOMAIN,127.0.0.1,REJECT"),
                    ProxyRule(type: "FINAL", value: "", policy: "REJECT", options: [], sourceLine: 2, rawLine: "FINAL,REJECT")
                ]
            )
        )
        let proxyPort = try freeLoopbackPort()
        try await proxy.start(port: proxyPort)
        defer {
            Task { await proxy.stop() }
        }

        let clientFD = try connectLoopback(port: proxyPort)
        defer { close(clientFD) }

        let request = """
        GET http://127.0.0.1:\(origin.port)/bypass HTTP/1.1\r
        Host: 127.0.0.1:\(origin.port)\r
        Connection: close\r
        \r

        """
        try sendAll(request, to: clientFD)
        let response = readAll(from: clientFD)

        XCTAssertTrue(response.contains("200 OK"))
        XCTAssertTrue(response.contains("skip-proxy-ok"))

        try? await Task.sleep(nanoseconds: 150_000_000)
        let events = await logStore.events()
        XCTAssertEqual(events.first?.policy, "DIRECT")
        XCTAssertEqual(events.first?.status, "Connected")
        XCTAssertTrue(events.first?.note.contains("General skip-proxy") == true)
    }

    func testGroupPolicyResolvesDefaultDirect() async throws {
        let origin = try TinyHTTPServer(responseBody: "direct-group-ok")
        defer { origin.stop() }

        let logStore = ProxyEventStore()
        let proxy = LocalHTTPProxyServer(
            logStore: logStore,
            routingProfile: ProxyProfile(
                groups: [
                    ProxyGroup(name: "Direct Group", kind: .select, rawKind: "select", policies: ["DIRECT"], parameters: [:], sourceLine: 1)
                ],
                rules: [
                    ProxyRule(type: "DEST-PORT", value: "\(origin.port)", policy: "Direct Group", options: [], sourceLine: 2, rawLine: "DEST-PORT,\(origin.port),Direct Group"),
                    ProxyRule(type: "FINAL", value: "", policy: "REJECT", options: [], sourceLine: 3, rawLine: "FINAL,REJECT")
                ]
            )
        )
        let proxyPort = try freeLoopbackPort()
        try await proxy.start(port: proxyPort)
        defer {
            Task { await proxy.stop() }
        }

        let clientFD = try connectLoopback(port: proxyPort)
        defer { close(clientFD) }

        let request = """
        GET http://127.0.0.1:\(origin.port)/fallback HTTP/1.1\r
        Host: 127.0.0.1:\(origin.port)\r
        Connection: close\r
        \r

        """
        try sendAll(request, to: clientFD)
        let response = readAll(from: clientFD)

        XCTAssertTrue(response.contains("200 OK"))
        XCTAssertTrue(response.contains("direct-group-ok"))

        try? await Task.sleep(nanoseconds: 150_000_000)
        let events = await logStore.events()
        XCTAssertEqual(events.first?.policy, "Direct Group -> DIRECT")
        XCTAssertEqual(events.first?.status, "Connected")
    }

    func testHTTPProxyPolicyUsesHTTPUpstream() async throws {
        let upstream = try TinyHTTPProxyServer()
        defer { upstream.stop() }

        let logStore = ProxyEventStore()
        let proxy = LocalHTTPProxyServer(
            logStore: logStore,
            routingProfile: ProxyProfile(
                proxies: [
                    ProxyNode(name: "HTTP Upstream", kind: .http, rawKind: "http", host: "127.0.0.1", port: upstream.port, username: nil, password: nil, parameters: [:], sourceLine: 1)
                ],
                rules: [
                    ProxyRule(type: "DOMAIN-SUFFIX", value: "upstream.test", policy: "HTTP Upstream", options: [], sourceLine: 2, rawLine: "DOMAIN-SUFFIX,upstream.test,HTTP Upstream"),
                    ProxyRule(type: "FINAL", value: "", policy: "REJECT", options: [], sourceLine: 3, rawLine: "FINAL,REJECT")
                ]
            )
        )
        let proxyPort = try freeLoopbackPort()
        try await proxy.start(port: proxyPort)
        defer {
            Task { await proxy.stop() }
        }

        let clientFD = try connectLoopback(port: proxyPort)
        defer { close(clientFD) }

        let request = """
        GET http://example.upstream.test/via-http HTTP/1.1\r
        Host: example.upstream.test\r
        Connection: close\r
        \r

        """
        try sendAll(request, to: clientFD)
        let response = readAll(from: clientFD)

        XCTAssertTrue(response.contains("200 OK"))
        XCTAssertTrue(response.contains("GET http://example.upstream.test/via-http HTTP/1.1"))

        try? await Task.sleep(nanoseconds: 150_000_000)
        let events = await logStore.events()
        XCTAssertEqual(events.first?.policy, "HTTP Upstream")
        XCTAssertEqual(events.first?.status, "Connected")
        XCTAssertTrue(events.first?.note.contains("HTTP upstream") == true)
    }

    func testSOCKS5ProxyPolicyUsesSOCKS5Upstream() async throws {
        let upstream = try TinySOCKS5ProxyServer()
        defer { upstream.stop() }

        let logStore = ProxyEventStore()
        let proxy = LocalHTTPProxyServer(
            logStore: logStore,
            routingProfile: ProxyProfile(
                proxies: [
                    ProxyNode(name: "SOCKS Upstream", kind: .socks5, rawKind: "socks5", host: "127.0.0.1", port: upstream.port, username: nil, password: nil, parameters: [:], sourceLine: 1)
                ],
                rules: [
                    ProxyRule(type: "DOMAIN-SUFFIX", value: "socks.test", policy: "SOCKS Upstream", options: [], sourceLine: 2, rawLine: "DOMAIN-SUFFIX,socks.test,SOCKS Upstream"),
                    ProxyRule(type: "FINAL", value: "", policy: "REJECT", options: [], sourceLine: 3, rawLine: "FINAL,REJECT")
                ]
            )
        )
        let proxyPort = try freeLoopbackPort()
        try await proxy.start(port: proxyPort)
        defer {
            Task { await proxy.stop() }
        }

        let clientFD = try connectLoopback(port: proxyPort)
        defer { close(clientFD) }

        let request = """
        GET http://example.socks.test/via-socks HTTP/1.1\r
        Host: example.socks.test\r
        Connection: close\r
        \r

        """
        try sendAll(request, to: clientFD)
        let response = readAll(from: clientFD)

        XCTAssertTrue(response.contains("200 OK"))
        XCTAssertTrue(response.contains("GET /via-socks HTTP/1.1"))

        try? await Task.sleep(nanoseconds: 150_000_000)
        let events = await logStore.events()
        XCTAssertEqual(events.first?.policy, "SOCKS Upstream")
        XCTAssertEqual(events.first?.status, "Connected")
        XCTAssertTrue(events.first?.note.contains("SOCKS5 upstream") == true)
    }

    func testUnsupportedProxyPolicyIsBlockedInsteadOfDirectLeaking() async throws {
        let origin = try TinyHTTPServer(responseBody: "should-not-leak")
        defer { origin.stop() }

        let logStore = ProxyEventStore()
        let proxy = LocalHTTPProxyServer(
            logStore: logStore,
            routingProfile: ProxyProfile(
                proxies: [
                    ProxyNode(
                        name: "VMess Node",
                        kind: .vmess,
                        rawKind: "vmess",
                        host: "127.0.0.1",
                        port: origin.port,
                        username: nil,
                        password: "secret",
                        parameters: [:],
                        sourceLine: 1
                    )
                ],
                groups: [
                    ProxyGroup(name: "Proxies", kind: .select, rawKind: "select", policies: ["VMess Node"], parameters: [:], sourceLine: 2)
                ],
                rules: [
                    ProxyRule(type: "DEST-PORT", value: "\(origin.port)", policy: "Proxies", options: [], sourceLine: 3, rawLine: "DEST-PORT,\(origin.port),Proxies"),
                    ProxyRule(type: "FINAL", value: "", policy: "DIRECT", options: [], sourceLine: 4, rawLine: "FINAL,DIRECT")
                ]
            )
        )
        let proxyPort = try freeLoopbackPort()
        try await proxy.start(port: proxyPort)
        defer {
            Task { await proxy.stop() }
        }

        let clientFD = try connectLoopback(port: proxyPort)
        defer { close(clientFD) }

        let request = """
        GET http://127.0.0.1:\(origin.port)/blocked-upstream HTTP/1.1\r
        Host: 127.0.0.1:\(origin.port)\r
        Connection: close\r
        \r

        """
        try sendAll(request, to: clientFD)
        let response = readAll(from: clientFD)

        XCTAssertTrue(response.contains("501 Not Implemented"))
        XCTAssertFalse(response.contains("should-not-leak"))

        try? await Task.sleep(nanoseconds: 150_000_000)
        let events = await logStore.events()
        XCTAssertEqual(events.first?.policy, "Proxies -> VMess Node -> VMESS upstream unsupported")
        XCTAssertEqual(events.first?.status, "Unsupported")
    }

    func testTrojanRequestHeaderEncodesSHA224AndDomainDestination() throws {
        let header = try TrojanProtocol.requestHeader(password: "password", host: "example.com", port: 443)
        let expectedHash = "d63dc919e201d7bc4c825630d2cf25fdc93d4b2f0d46706d29038d01"
        var expected = Data(expectedHash.utf8)
        expected.append(contentsOf: [13, 10, 0x01, 0x03, 11])
        expected.append(Data("example.com".utf8))
        expected.append(contentsOf: [0x01, 0xbb, 13, 10])

        XCTAssertEqual(header, expected)
    }

    func testTrojanRequestHeaderEncodesIPv4Destination() throws {
        let header = try TrojanProtocol.requestHeader(password: "password", host: "127.0.0.1", port: 80)
        let expectedHash = "d63dc919e201d7bc4c825630d2cf25fdc93d4b2f0d46706d29038d01"
        var expected = Data(expectedHash.utf8)
        expected.append(contentsOf: [13, 10, 0x01, 0x03, 9])
        expected.append(Data("127.0.0.1".utf8))
        expected.append(contentsOf: [0, 80, 13, 10])

        XCTAssertEqual(header, expected)
    }

    func testTrojanRequestHeaderCanPreserveSOCKSIPv4AddressType() throws {
        let header = try TrojanProtocol.requestHeader(password: "password", address: .ipv4([127, 0, 0, 1], port: 80))
        let expectedHash = "d63dc919e201d7bc4c825630d2cf25fdc93d4b2f0d46706d29038d01"
        var expected = Data(expectedHash.utf8)
        expected.append(contentsOf: [13, 10, 0x01, 0x01, 127, 0, 0, 1, 0, 80, 13, 10])

        XCTAssertEqual(header, expected)
    }

    func testTrojanRequestParserExtractsPayload() throws {
        var request = try TrojanProtocol.requestHeader(password: "password", host: "example.com", port: 443)
        request.append(Data("GET / HTTP/1.1\r\n\r\n".utf8))

        let parsed = try TrojanProtocol.parseRequest(request)

        XCTAssertEqual(parsed.command, .connect)
        XCTAssertEqual(parsed.address, .domainName(host: "example.com", port: 443))
        XCTAssertEqual(parsed.payload, Data("GET / HTTP/1.1\r\n\r\n".utf8))
    }

    func testTLSClientHelloInspectorExtractsServerName() throws {
        let clientHello = makeTLSClientHello(serverName: "www.google.com")

        XCTAssertEqual(TLSClientHelloInspector.serverName(in: clientHello), "www.google.com")
    }

    func testFakeIPInspectorDetects19818Range() throws {
        XCTAssertTrue(ProxyIPv4AddressInspector.isFakeIP("198.18.1.87"))
        XCTAssertTrue(ProxyIPv4AddressInspector.isFakeIP("198.19.255.255"))
        XCTAssertFalse(ProxyIPv4AddressInspector.isFakeIP("198.20.0.1"))
        XCTAssertFalse(ProxyIPv4AddressInspector.isFakeIP("www.google.com"))
    }

    func testLocalSOCKS5ListenerConnectsDirect() async throws {
        let origin = try TinyHTTPServer(responseBody: "socks-listener-ok")
        defer { origin.stop() }

        let logStore = ProxyEventStore()
        let socks = LocalSOCKS5ProxyServer(
            logStore: logStore,
            routingProfile: ProxyProfile(
                rules: [
                    ProxyRule(type: "DEST-PORT", value: "\(origin.port)", policy: "DIRECT", options: [], sourceLine: 1, rawLine: "DEST-PORT,\(origin.port),DIRECT"),
                    ProxyRule(type: "FINAL", value: "", policy: "REJECT", options: [], sourceLine: 2, rawLine: "FINAL,REJECT")
                ]
            )
        )
        let socksPort = try freeLoopbackPort()
        try await socks.start(port: socksPort)
        defer {
            Task { await socks.stop() }
        }

        let clientFD = try connectLoopback(port: socksPort)
        defer { close(clientFD) }

        try sendAll(Data([0x05, 0x01, 0x00]), to: clientFD)
        XCTAssertEqual(try recvExact(2, from: clientFD), [0x05, 0x00])

        var request = Data([0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1])
        var networkPort = UInt16(origin.port).bigEndian
        withUnsafeBytes(of: &networkPort) { request.append(contentsOf: $0) }
        try sendAll(request, to: clientFD)

        let reply = try recvExact(10, from: clientFD)
        XCTAssertEqual(reply[0], 0x05)
        XCTAssertEqual(reply[1], 0x00)

        let httpRequest = """
        GET /from-socks-listener HTTP/1.1\r
        Host: 127.0.0.1:\(origin.port)\r
        Connection: close\r
        \r

        """
        try sendAll(httpRequest, to: clientFD)
        let response = readAll(from: clientFD)

        XCTAssertTrue(response.contains("200 OK"))
        XCTAssertTrue(response.contains("socks-listener-ok"))

        try? await Task.sleep(nanoseconds: 150_000_000)
        let events = await logStore.events()
        let connectedEvent = events.first { $0.status == "Connected" }
        XCTAssertEqual(connectedEvent?.method, "SOCKS5")
        XCTAssertEqual(connectedEvent?.policy, "DIRECT")
    }

    func testLocalSOCKS5UDPAssociateRelaysDirectDatagram() async throws {
        let origin = try TinyUDPEchoServer()
        defer { origin.stop() }

        let logStore = ProxyEventStore()
        let socks = LocalSOCKS5ProxyServer(
            logStore: logStore,
            routingProfile: ProxyProfile(
                rules: [
                    ProxyRule(type: "DEST-PORT", value: "\(origin.port)", policy: "DIRECT", options: [], sourceLine: 1, rawLine: "DEST-PORT,\(origin.port),DIRECT"),
                    ProxyRule(type: "FINAL", value: "", policy: "REJECT", options: [], sourceLine: 2, rawLine: "FINAL,REJECT")
                ]
            )
        )
        let socksPort = try freeLoopbackPort()
        try await socks.start(port: socksPort)
        defer {
            Task { await socks.stop() }
        }

        let controlFD = try connectLoopback(port: socksPort)
        defer { close(controlFD) }
        let relayPort = try openSOCKS5UDPAssociation(controlFD: controlFD)

        let udpFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        XCTAssertGreaterThanOrEqual(udpFD, 0)
        defer { close(udpFD) }

        let payload = Data("udp-associate-ok".utf8)
        let request = makeSOCKS5UDPDatagram(host: "127.0.0.1", port: origin.port, payload: payload)
        try sendUDPDatagram(request, from: udpFD, toLoopbackPort: relayPort)

        let response = try XCTUnwrap(recvUDPDatagram(from: udpFD, timeoutMS: 3_000))
        XCTAssertEqual(Array(response.prefix(10)), [0x00, 0x00, 0x00, 0x01, 127, 0, 0, 1, UInt8((origin.port >> 8) & 0xFF), UInt8(origin.port & 0xFF)])
        XCTAssertEqual(Data(response.dropFirst(10)), payload)

        try? await Task.sleep(nanoseconds: 150_000_000)
        let events = await logStore.events()
        XCTAssertTrue(events.contains { $0.method == "SOCKS5 UDP" && $0.status == "Connected" && $0.policy == "DIRECT" })
    }

    func testLocalSOCKS5UDPAssociateDoesNotRelayRejectedDatagram() async throws {
        let origin = try TinyUDPEchoServer()
        defer { origin.stop() }

        let logStore = ProxyEventStore()
        let socks = LocalSOCKS5ProxyServer(
            logStore: logStore,
            routingProfile: ProxyProfile(
                rules: [
                    ProxyRule(type: "FINAL", value: "", policy: "REJECT", options: [], sourceLine: 1, rawLine: "FINAL,REJECT")
                ]
            )
        )
        let socksPort = try freeLoopbackPort()
        try await socks.start(port: socksPort)
        defer {
            Task { await socks.stop() }
        }

        let controlFD = try connectLoopback(port: socksPort)
        defer { close(controlFD) }
        let relayPort = try openSOCKS5UDPAssociation(controlFD: controlFD)

        let udpFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        XCTAssertGreaterThanOrEqual(udpFD, 0)
        defer { close(udpFD) }

        let payload = Data("should-not-leak".utf8)
        let request = makeSOCKS5UDPDatagram(host: "127.0.0.1", port: origin.port, payload: payload)
        try sendUDPDatagram(request, from: udpFD, toLoopbackPort: relayPort)

        XCTAssertNil(try recvUDPDatagram(from: udpFD, timeoutMS: 300))

        try? await Task.sleep(nanoseconds: 150_000_000)
        let events = await logStore.events()
        XCTAssertTrue(events.contains { $0.method == "SOCKS5 UDP" && $0.status == "Rejected" && $0.policy == "REJECT" })
    }

    func testSelectedGroupPolicyOverridesDefaultMember() async throws {
        let origin = try TinyHTTPServer(responseBody: "selected-direct-ok")
        defer { origin.stop() }

        let logStore = ProxyEventStore()
        let proxy = LocalHTTPProxyServer(
            logStore: logStore,
            routingProfile: ProxyProfile(
                proxies: [
                    ProxyNode(
                        name: "Unsupported First",
                        kind: .trojan,
                        rawKind: "trojan",
                        host: "127.0.0.1",
                        port: origin.port,
                        username: nil,
                        password: "secret",
                        parameters: [:],
                        sourceLine: 1
                    )
                ],
                groups: [
                    ProxyGroup(name: "Manual", kind: .select, rawKind: "select", policies: ["Unsupported First", "DIRECT"], parameters: [:], sourceLine: 2)
                ],
                rules: [
                    ProxyRule(type: "DEST-PORT", value: "\(origin.port)", policy: "Manual", options: [], sourceLine: 3, rawLine: "DEST-PORT,\(origin.port),Manual"),
                    ProxyRule(type: "FINAL", value: "", policy: "REJECT", options: [], sourceLine: 4, rawLine: "FINAL,REJECT")
                ]
            ),
            groupSelections: ["Manual": "DIRECT"]
        )
        let proxyPort = try freeLoopbackPort()
        try await proxy.start(port: proxyPort)
        defer {
            Task { await proxy.stop() }
        }

        let clientFD = try connectLoopback(port: proxyPort)
        defer { close(clientFD) }

        let request = """
        GET http://127.0.0.1:\(origin.port)/selected HTTP/1.1\r
        Host: 127.0.0.1:\(origin.port)\r
        Connection: close\r
        \r

        """
        try sendAll(request, to: clientFD)
        let response = readAll(from: clientFD)

        XCTAssertTrue(response.contains("200 OK"))
        XCTAssertTrue(response.contains("selected-direct-ok"))

        try? await Task.sleep(nanoseconds: 150_000_000)
        let events = await logStore.events()
        XCTAssertEqual(events.first?.policy, "Manual -> DIRECT")
        XCTAssertEqual(events.first?.status, "Connected")
    }
}

private final class TinyHTTPServer: @unchecked Sendable {
    let port: Int
    private let fd: Int32
    private var task: Task<Void, Never>?

    init(responseBody: String) throws {
        let socketFD = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard socketFD >= 0 else {
            throw ProxyServerError.posix("socket", errno)
        }

        var enabled: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let saved = errno
            close(socketFD)
            throw ProxyServerError.posix("bind", saved)
        }

        guard listen(socketFD, 16) == 0 else {
            let saved = errno
            close(socketFD)
            throw ProxyServerError.posix("listen", saved)
        }

        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &length)
            }
        }
        guard nameResult == 0 else {
            let saved = errno
            close(socketFD)
            throw ProxyServerError.posix("getsockname", saved)
        }
        fd = socketFD
        port = Int(in_port_t(bigEndian: bound.sin_port))

        task = Task.detached(priority: .utility) { [socketFD] in
            let clientFD = accept(socketFD, nil, nil)
            guard clientFD >= 0 else { return }
            _ = readHeaderOnly(from: clientFD)
            let response = """
            HTTP/1.1 200 OK\r
            Content-Length: \(responseBody.utf8.count)\r
            Connection: close\r
            \r
            \(responseBody)
            """
            try? sendAll(response, to: clientFD)
            close(clientFD)
        }
    }

    func stop() {
        task?.cancel()
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }
}

private final class TinyUDPEchoServer: @unchecked Sendable {
    let port: Int
    private let fd: Int32
    private var task: Task<Void, Never>?

    init() throws {
        let socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketFD >= 0 else {
            throw ProxyServerError.posix("socket", errno)
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let saved = errno
            close(socketFD)
            throw ProxyServerError.posix("bind", saved)
        }

        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &length)
            }
        }
        guard nameResult == 0 else {
            let saved = errno
            close(socketFD)
            throw ProxyServerError.posix("getsockname", saved)
        }

        fd = socketFD
        port = Int(in_port_t(bigEndian: bound.sin_port))

        task = Task.detached(priority: .utility) { [socketFD] in
            var buffer = [UInt8](repeating: 0, count: 4096)
            while !Task.isCancelled {
                var clientAddress = sockaddr_storage()
                var clientLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let count = withUnsafeMutablePointer(to: &clientAddress) { addressPointer in
                    addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                        buffer.withUnsafeMutableBytes { rawBuffer in
                            recvfrom(socketFD, rawBuffer.baseAddress, rawBuffer.count, 0, sockaddrPointer, &clientLength)
                        }
                    }
                }
                guard count > 0 else { break }
                _ = withUnsafePointer(to: &clientAddress) { addressPointer in
                    addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                        buffer.withUnsafeBytes { rawBuffer in
                            sendto(socketFD, rawBuffer.baseAddress, count, 0, sockaddrPointer, clientLength)
                        }
                    }
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        close(fd)
    }
}

private final class TinyHTTPProxyServer: @unchecked Sendable {
    let port: Int
    private let fd: Int32
    private var task: Task<Void, Never>?

    init() throws {
        let socketFD = try listenLoopbackSocket()
        fd = socketFD.fd
        port = socketFD.port

        task = Task.detached(priority: .utility) { [socketFD] in
            let clientFD = accept(socketFD.fd, nil, nil)
            guard clientFD >= 0 else { return }
            let header = readHeaderOnly(from: clientFD)
            let requestLine = header.components(separatedBy: "\r\n").first ?? ""
            let response = """
            HTTP/1.1 200 OK\r
            Content-Length: \(requestLine.utf8.count)\r
            Connection: close\r
            \r
            \(requestLine)
            """
            try? sendAll(response, to: clientFD)
            close(clientFD)
        }
    }

    func stop() {
        task?.cancel()
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }
}

private final class TinySOCKS5ProxyServer: @unchecked Sendable {
    let port: Int
    private let fd: Int32
    private var task: Task<Void, Never>?

    init() throws {
        let socketFD = try listenLoopbackSocket()
        fd = socketFD.fd
        port = socketFD.port

        task = Task.detached(priority: .utility) { [socketFD] in
            let clientFD = accept(socketFD.fd, nil, nil)
            guard clientFD >= 0 else { return }
            do {
                let greeting = try recvExact(2, from: clientFD)
                guard greeting[0] == 0x05 else {
                    close(clientFD)
                    return
                }
                _ = try recvExact(Int(greeting[1]), from: clientFD)
                try sendAll(Data([0x05, 0x00]), to: clientFD)

                let head = try recvExact(4, from: clientFD)
                guard head[0] == 0x05, head[1] == 0x01 else {
                    close(clientFD)
                    return
                }
                switch head[3] {
                case 0x01:
                    _ = try recvExact(4, from: clientFD)
                case 0x03:
                    let length = try recvExact(1, from: clientFD)[0]
                    _ = try recvExact(Int(length), from: clientFD)
                case 0x04:
                    _ = try recvExact(16, from: clientFD)
                default:
                    close(clientFD)
                    return
                }
                _ = try recvExact(2, from: clientFD)
                try sendAll(Data([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]), to: clientFD)

                let header = readHeaderOnly(from: clientFD)
                let requestLine = header.components(separatedBy: "\r\n").first ?? ""
                let response = """
                HTTP/1.1 200 OK\r
                Content-Length: \(requestLine.utf8.count)\r
                Connection: close\r
                \r
                \(requestLine)
                """
                try sendAll(response, to: clientFD)
            } catch {
                _ = try? sendAll(Data([0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0]), to: clientFD)
            }
            close(clientFD)
        }
    }

    func stop() {
        task?.cancel()
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }
}

private struct BoundSocket: Sendable {
    var fd: Int32
    var port: Int
}

private func listenLoopbackSocket() throws -> BoundSocket {
    let socketFD = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    guard socketFD >= 0 else {
        throw ProxyServerError.posix("socket", errno)
    }

    var enabled: Int32 = 1
    setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout<Int32>.size))

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

    let bindResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0 else {
        let saved = errno
        close(socketFD)
        throw ProxyServerError.posix("bind", saved)
    }

    guard listen(socketFD, 16) == 0 else {
        let saved = errno
        close(socketFD)
        throw ProxyServerError.posix("listen", saved)
    }

    var bound = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(socketFD, $0, &length)
        }
    }
    guard nameResult == 0 else {
        let saved = errno
        close(socketFD)
        throw ProxyServerError.posix("getsockname", saved)
    }

    return BoundSocket(fd: socketFD, port: Int(in_port_t(bigEndian: bound.sin_port)))
}

private func freeLoopbackPort() throws -> Int {
    let socketFD = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    guard socketFD >= 0 else {
        throw ProxyServerError.posix("socket", errno)
    }
    defer { close(socketFD) }

    var enabled: Int32 = 1
    setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout<Int32>.size))

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

    let bindResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0 else {
        throw ProxyServerError.posix("bind", errno)
    }

    var bound = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(socketFD, $0, &length)
        }
    }
    guard nameResult == 0 else {
        throw ProxyServerError.posix("getsockname", errno)
    }

    return Int(in_port_t(bigEndian: bound.sin_port))
}

private func connectLoopback(port: Int) throws -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    guard fd >= 0 else {
        throw ProxyServerError.posix("socket", errno)
    }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard result == 0 else {
        let saved = errno
        close(fd)
        throw ProxyServerError.posix("connect", saved)
    }
    return fd
}

private func openSOCKS5UDPAssociation(controlFD: Int32) throws -> Int {
    try sendAll(Data([0x05, 0x01, 0x00]), to: controlFD)
    XCTAssertEqual(try recvExact(2, from: controlFD), [0x05, 0x00])

    let request = Data([0x05, 0x03, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
    try sendAll(request, to: controlFD)

    let reply = try recvExact(10, from: controlFD)
    XCTAssertEqual(reply[0], 0x05)
    XCTAssertEqual(reply[1], 0x00)
    XCTAssertEqual(reply[3], 0x01)
    XCTAssertEqual(Array(reply[4..<8]), [127, 0, 0, 1])
    return Int(UInt16(reply[8]) << 8 | UInt16(reply[9]))
}

private func sendAll(_ string: String, to fd: Int32) throws {
    try sendAll(Data(string.utf8), to: fd)
}

private func sendAll(_ data: Data, to fd: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return }
        var sent = 0
        while sent < data.count {
            let count = send(fd, baseAddress.advanced(by: sent), data.count - sent, 0)
            guard count > 0 else {
                throw ProxyServerError.posix("send", errno)
            }
            sent += count
        }
    }
}

private func recvExact(_ byteCount: Int, from fd: Int32) throws -> [UInt8] {
    var result: [UInt8] = []
    result.reserveCapacity(byteCount)
    while result.count < byteCount {
        var buffer = [UInt8](repeating: 0, count: byteCount - result.count)
        let count = recv(fd, &buffer, buffer.count, 0)
        guard count > 0 else {
            throw ProxyServerError.connectionClosed
        }
        result.append(contentsOf: buffer.prefix(count))
    }
    return result
}

private func readAll(from fd: Int32) -> String {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = recv(fd, &buffer, buffer.count, 0)
        guard count > 0 else { break }
        data.append(buffer, count: count)
    }
    return String(data: data, encoding: .utf8) ?? ""
}

private func readHeaderOnly(from fd: Int32) -> String {
    var data = Data()
    let terminator = Data([13, 10, 13, 10])
    var buffer = [UInt8](repeating: 0, count: 1024)
    while data.count < 64 * 1024 {
        let count = recv(fd, &buffer, buffer.count, 0)
        guard count > 0 else { break }
        data.append(buffer, count: count)
        if data.range(of: terminator) != nil { break }
    }
    return String(data: data, encoding: .utf8) ?? ""
}

private func makeSOCKS5UDPDatagram(host: String, port: Int, payload: Data) -> Data {
    var result = Data([0x00, 0x00, 0x00])
    var ipv4 = in_addr()
    if inet_pton(AF_INET, host, &ipv4) == 1 {
        result.append(0x01)
        withUnsafeBytes(of: &ipv4.s_addr) { result.append(contentsOf: $0) }
    } else {
        let hostData = Data(host.utf8)
        result.append(0x03)
        result.append(UInt8(hostData.count))
        result.append(hostData)
    }
    result.append(UInt8((port >> 8) & 0xFF))
    result.append(UInt8(port & 0xFF))
    result.append(payload)
    return result
}

private func sendUDPDatagram(_ data: Data, from fd: Int32, toLoopbackPort port: Int) throws {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

    let count = data.withUnsafeBytes { rawBuffer in
        withUnsafePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                sendto(fd, rawBuffer.baseAddress, data.count, 0, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
    guard count == data.count else {
        throw ProxyServerError.posix("sendto", errno)
    }
}

private func recvUDPDatagram(from fd: Int32, timeoutMS: Int32) throws -> Data? {
    var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    let pollResult = poll(&pollFD, 1, timeoutMS)
    if pollResult < 0 {
        throw ProxyServerError.posix("poll", errno)
    }
    guard pollResult > 0, (pollFD.revents & Int16(POLLIN)) != 0 else {
        return nil
    }

    var buffer = [UInt8](repeating: 0, count: 65_535)
    let count = buffer.withUnsafeMutableBytes { rawBuffer in
        recv(fd, rawBuffer.baseAddress, rawBuffer.count, 0)
    }
    if count < 0 {
        throw ProxyServerError.posix("recv", errno)
    }
    return Data(buffer.prefix(count))
}

private func makeTLSClientHello(serverName: String) -> Data {
    let serverNameData = Data(serverName.utf8)
    var serverNameExtension = Data()
    serverNameExtension.append(contentsOf: [0x00, UInt8(serverNameData.count + 3)])
    serverNameExtension.append(0x00)
    serverNameExtension.append(UInt8((serverNameData.count >> 8) & 0xFF))
    serverNameExtension.append(UInt8(serverNameData.count & 0xFF))
    serverNameExtension.append(serverNameData)

    var extensions = Data()
    extensions.append(contentsOf: [0x00, 0x00])
    extensions.append(UInt8((serverNameExtension.count >> 8) & 0xFF))
    extensions.append(UInt8(serverNameExtension.count & 0xFF))
    extensions.append(serverNameExtension)

    var handshakeBody = Data()
    handshakeBody.append(contentsOf: [0x03, 0x03])
    handshakeBody.append(Data(repeating: 0x11, count: 32))
    handshakeBody.append(0x00)
    handshakeBody.append(contentsOf: [0x00, 0x02, 0x13, 0x01])
    handshakeBody.append(contentsOf: [0x01, 0x00])
    handshakeBody.append(UInt8((extensions.count >> 8) & 0xFF))
    handshakeBody.append(UInt8(extensions.count & 0xFF))
    handshakeBody.append(extensions)

    var handshake = Data([0x01])
    handshake.append(UInt8((handshakeBody.count >> 16) & 0xFF))
    handshake.append(UInt8((handshakeBody.count >> 8) & 0xFF))
    handshake.append(UInt8(handshakeBody.count & 0xFF))
    handshake.append(handshakeBody)

    var record = Data([0x16, 0x03, 0x01])
    record.append(UInt8((handshake.count >> 8) & 0xFF))
    record.append(UInt8(handshake.count & 0xFF))
    record.append(handshake)
    return record
}
