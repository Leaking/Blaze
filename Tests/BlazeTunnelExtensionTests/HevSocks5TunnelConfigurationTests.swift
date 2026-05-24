@testable import BlazeTunnelExtension
import XCTest

final class HevSocks5TunnelConfigurationTests: XCTestCase {
    func testDefaultsRenderUDPModeUDP() throws {
        let runtime = PacketTunnelRuntimeConfiguration(providerConfiguration: [
            "packetEngine": "hev",
            "socksPort": 19081
        ])
        let yaml = try string(from: HevSocks5TunnelConfiguration(configuration: runtime))

        XCTAssertTrue(
            yaml.contains("udp: 'udp'"),
            "hev must enable SOCKS5 UDP ASSOCIATE by default so leaf can carry QUIC/UDP outbound. Got:\n\(yaml)"
        )
        XCTAssertTrue(yaml.contains("address: '127.0.0.1'"))
        XCTAssertTrue(yaml.contains("port: 19081"))
    }

    func testExplicitTCPModeRendersTCP() throws {
        let runtime = PacketTunnelRuntimeConfiguration(providerConfiguration: [
            "packetEngine": "hev",
            "hevUDPMode": "tcp"
        ])
        let yaml = try string(from: HevSocks5TunnelConfiguration(configuration: runtime))

        XCTAssertTrue(yaml.contains("udp: 'tcp'"), "explicit override must still work")
    }

    func testUnknownUDPModeFallsBackToUDP() throws {
        // Hardening: any value other than the literal "tcp" must render "udp",
        // never crash and never silently drop UDP.
        let runtime = PacketTunnelRuntimeConfiguration(providerConfiguration: [
            "packetEngine": "hev",
            "hevUDPMode": "wat"
        ])
        let yaml = try string(from: HevSocks5TunnelConfiguration(configuration: runtime))

        XCTAssertTrue(yaml.contains("udp: 'udp'"))
    }

    private func string(from configuration: HevSocks5TunnelConfiguration) throws -> String {
        let data = try configuration.data()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
