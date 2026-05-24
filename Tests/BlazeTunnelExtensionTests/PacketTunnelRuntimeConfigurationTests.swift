@testable import BlazeTunnelExtension
import XCTest

final class PacketTunnelRuntimeConfigurationTests: XCTestCase {
    func testDefaultsAreOptimisedForDailyUse() {
        let configuration = PacketTunnelRuntimeConfiguration(providerConfiguration: nil)

        XCTAssertFalse(configuration.enableProxySettings)
        XCTAssertFalse(configuration.enableDNSNetworkFallback)
        XCTAssertEqual(configuration.ipv6Mode, .passthrough)
        XCTAssertFalse(configuration.enableIPv6Blackhole, "blackhole derives from .blackhole mode only")
        XCTAssertFalse(configuration.suppressIPv6DNS, "AAAA suppression derives from .blackhole mode only")
        XCTAssertTrue(configuration.enableUDPRelay, "UDP relay must be on so QUIC / video / games can work")
        XCTAssertEqual(configuration.hevUDPMode, "udp", "hev needs SOCKS5 UDP ASSOCIATE, not TCP-only")
        XCTAssertEqual(configuration.engineKind, .native)
        XCTAssertEqual(configuration.tunnelMTU, 1_280)
        XCTAssertEqual(configuration.tunnelDNSServers, [PacketTunnelRuntimeConfiguration.nativeVirtualDNSServer])
    }

    func testExplicitOverridesAreHonored() {
        let configuration = PacketTunnelRuntimeConfiguration(providerConfiguration: [
            "packetEngine": "hev",
            "enableProxySettings": true,
            "enableDNSNetworkFallback": true,
            "ipv6Mode": "blackhole",
            "tunnelMTU": 1_360,
            "hevLibraryDirectory": "/tmp/hev",
            "hevUDPMode": "tcp",
            "enableUDPRelay": false
        ])

        XCTAssertTrue(configuration.enableProxySettings)
        XCTAssertTrue(configuration.enableDNSNetworkFallback)
        XCTAssertEqual(configuration.ipv6Mode, .blackhole)
        XCTAssertTrue(configuration.enableIPv6Blackhole)
        XCTAssertTrue(configuration.suppressIPv6DNS)
        XCTAssertFalse(configuration.enableUDPRelay)
        XCTAssertEqual(configuration.engineKind, .hev)
        XCTAssertEqual(configuration.tunnelMTU, 1_360)
        XCTAssertEqual(configuration.hevLibraryDirectory, "/tmp/hev")
        XCTAssertEqual(configuration.hevUDPMode, "tcp")
        XCTAssertEqual(configuration.tunnelDNSServers, [PacketTunnelRuntimeConfiguration.hevMapDNSServer])
    }

    func testLegacyEnableIPv6BlackholeKeyIsHonoredForBackwardCompat() {
        // A user who installed an older build still has providerConfiguration
        // carrying enableIPv6Blackhole=true. New code must resolve that to
        // .blackhole instead of silently flipping behavior on upgrade.
        let configuration = PacketTunnelRuntimeConfiguration(providerConfiguration: [
            "enableIPv6Blackhole": true
        ])

        XCTAssertEqual(configuration.ipv6Mode, .blackhole)
        XCTAssertTrue(configuration.enableIPv6Blackhole)
        XCTAssertTrue(configuration.suppressIPv6DNS)
    }

    func testNewIPv6ModeKeyOverridesLegacyKey() {
        // If a config has both keys (mid-migration window), the new one wins.
        let configuration = PacketTunnelRuntimeConfiguration(providerConfiguration: [
            "ipv6Mode": "passthrough",
            "enableIPv6Blackhole": true
        ])

        XCTAssertEqual(configuration.ipv6Mode, .passthrough)
    }

    func testFakeIPDNSCanBeDisabledForFallbackResolvers() {
        let configuration = PacketTunnelRuntimeConfiguration(providerConfiguration: [
            "enableFakeIPDNS": false
        ])

        XCTAssertEqual(configuration.tunnelDNSServers, PacketTunnelRuntimeConfiguration.fallbackDNSServers)
    }

    func testProviderConfigurationAcceptsNSNumberValues() {
        let configuration = PacketTunnelRuntimeConfiguration(providerConfiguration: [
            "httpPort": NSNumber(value: 29080),
            "socksPort": NSNumber(value: 29081),
            "enableFakeIPDNS": NSNumber(value: false),
            "enableProxySettings": NSNumber(value: true),
            "enableUDPRelay": NSNumber(value: false),
            "enableIPv6Blackhole": NSNumber(value: true)
        ])

        XCTAssertEqual(configuration.httpPort, 29080)
        XCTAssertEqual(configuration.socksPort, 29081)
        XCTAssertFalse(configuration.enableFakeIPDNS)
        XCTAssertTrue(configuration.enableProxySettings)
        XCTAssertFalse(configuration.enableUDPRelay)
        XCTAssertEqual(configuration.ipv6Mode, .blackhole)
    }

    func testTunnelMTUIsClampedToSafeRange() {
        XCTAssertEqual(PacketTunnelRuntimeConfiguration(providerConfiguration: ["tunnelMTU": 128]).tunnelMTU, 576)
        XCTAssertEqual(PacketTunnelRuntimeConfiguration(providerConfiguration: ["tunnelMTU": 9_000]).tunnelMTU, 1_500)
    }
}
