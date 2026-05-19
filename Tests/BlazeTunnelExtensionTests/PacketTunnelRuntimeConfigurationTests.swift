@testable import BlazeTunnelExtension
import XCTest

final class PacketTunnelRuntimeConfigurationTests: XCTestCase {
    func testProxySettingsAreDisabledByDefaultForTransparentTunnel() {
        let configuration = PacketTunnelRuntimeConfiguration(providerConfiguration: nil)

        XCTAssertFalse(configuration.enableProxySettings)
        XCTAssertFalse(configuration.enableDNSNetworkFallback)
        XCTAssertTrue(configuration.enableIPv6Blackhole)
        XCTAssertEqual(configuration.engineKind, .native)
        XCTAssertEqual(configuration.tunnelDNSServers, [PacketTunnelRuntimeConfiguration.nativeVirtualDNSServer])
    }

    func testProxySettingsCanBeExplicitlyEnabledForDiagnostics() {
        let configuration = PacketTunnelRuntimeConfiguration(providerConfiguration: [
            "packetEngine": "hev",
            "enableProxySettings": true,
            "enableDNSNetworkFallback": true,
            "enableIPv6Blackhole": false,
            "hevLibraryDirectory": "/tmp/hev",
            "hevUDPMode": "tcp"
        ])

        XCTAssertTrue(configuration.enableProxySettings)
        XCTAssertTrue(configuration.enableDNSNetworkFallback)
        XCTAssertFalse(configuration.enableIPv6Blackhole)
        XCTAssertEqual(configuration.engineKind, .hev)
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
}
