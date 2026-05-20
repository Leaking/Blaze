@testable import BlazeTunnelExtension
import XCTest

final class PacketTunnelRuntimeConfigurationTests: XCTestCase {
    func testProxySettingsAreDisabledByDefaultForTransparentTunnel() {
        let configuration = PacketTunnelRuntimeConfiguration(providerConfiguration: nil)

        XCTAssertFalse(configuration.enableProxySettings)
        XCTAssertFalse(configuration.enableDNSNetworkFallback)
        XCTAssertTrue(configuration.enableIPv6Blackhole)
    }

    func testProxySettingsCanBeExplicitlyEnabledForDiagnostics() {
        let configuration = PacketTunnelRuntimeConfiguration(providerConfiguration: [
            "enableProxySettings": true,
            "enableDNSNetworkFallback": true,
            "enableIPv6Blackhole": false
        ])

        XCTAssertTrue(configuration.enableProxySettings)
        XCTAssertTrue(configuration.enableDNSNetworkFallback)
        XCTAssertFalse(configuration.enableIPv6Blackhole)
    }
}
