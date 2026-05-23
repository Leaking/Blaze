@testable import BlazeTunnelExtension
import XCTest

final class PacketTunnelRuntimeConfigurationTests: XCTestCase {
    func testProxySettingsAreDisabledByDefaultForTransparentTunnel() {
        let configuration = PacketTunnelRuntimeConfiguration(providerConfiguration: nil)

        XCTAssertFalse(configuration.enableProxySettings)
        XCTAssertFalse(configuration.enableDNSNetworkFallback)
        XCTAssertTrue(configuration.enableIPv6Blackhole)
        XCTAssertEqual(configuration.engineKind, .native)
        XCTAssertEqual(configuration.tunnelMTU, 1_280)
        XCTAssertEqual(configuration.tunnelDNSServers, [PacketTunnelRuntimeConfiguration.nativeVirtualDNSServer])
    }

    func testProxySettingsCanBeExplicitlyEnabledForDiagnostics() {
        let configuration = PacketTunnelRuntimeConfiguration(providerConfiguration: [
            "packetEngine": "hev",
            "enableProxySettings": true,
            "enableDNSNetworkFallback": true,
            "enableIPv6Blackhole": false,
            "tunnelMTU": 1_360,
            "hevLibraryDirectory": "/tmp/hev",
            "hevUDPMode": "tcp"
        ])

        XCTAssertTrue(configuration.enableProxySettings)
        XCTAssertTrue(configuration.enableDNSNetworkFallback)
        XCTAssertFalse(configuration.enableIPv6Blackhole)
        XCTAssertEqual(configuration.engineKind, .hev)
        XCTAssertEqual(configuration.tunnelMTU, 1_360)
        XCTAssertEqual(configuration.hevLibraryDirectory, "/tmp/hev")
        XCTAssertEqual(configuration.hevUDPMode, "tcp")
        XCTAssertEqual(configuration.tunnelDNSServers, [PacketTunnelRuntimeConfiguration.hevMapDNSServer])
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
            "enableProxySettings": NSNumber(value: true)
        ])

        XCTAssertEqual(configuration.httpPort, 29080)
        XCTAssertEqual(configuration.socksPort, 29081)
        XCTAssertFalse(configuration.enableFakeIPDNS)
        XCTAssertTrue(configuration.enableProxySettings)
    }

    func testTunnelMTUIsClampedToSafeRange() {
        XCTAssertEqual(PacketTunnelRuntimeConfiguration(providerConfiguration: ["tunnelMTU": 128]).tunnelMTU, 576)
        XCTAssertEqual(PacketTunnelRuntimeConfiguration(providerConfiguration: ["tunnelMTU": 9_000]).tunnelMTU, 1_500)
    }
}
