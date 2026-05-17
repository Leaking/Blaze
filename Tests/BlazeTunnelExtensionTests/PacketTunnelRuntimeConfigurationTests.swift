@testable import BlazeTunnelExtension
import XCTest

final class PacketTunnelRuntimeConfigurationTests: XCTestCase {
    func testProxySettingsAreDisabledByDefaultForTransparentTunnel() {
        let configuration = PacketTunnelRuntimeConfiguration(providerConfiguration: nil)

        XCTAssertFalse(configuration.enableProxySettings)
        XCTAssertFalse(configuration.enableDNSNetworkFallback)
        XCTAssertTrue(configuration.enableIPv6Blackhole)
        XCTAssertEqual(configuration.engineKind, .native)
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
    }
}
