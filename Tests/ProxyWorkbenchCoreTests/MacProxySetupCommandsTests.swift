import ProxyWorkbenchCore
import XCTest

final class MacProxySetupCommandsTests: XCTestCase {
    func testEnableCommandsQuoteNetworkServiceAndUseCurrentPorts() {
        let commands = MacProxySetupCommands(networkService: "USB 10/100/1000 LAN", httpPort: 19080, socksPort: 19081)

        XCTAssertEqual(
            commands.enableCommands,
            """
            networksetup -setwebproxy 'USB 10/100/1000 LAN' 127.0.0.1 19080
            networksetup -setsecurewebproxy 'USB 10/100/1000 LAN' 127.0.0.1 19080
            networksetup -setsocksfirewallproxy 'USB 10/100/1000 LAN' 127.0.0.1 19081
            networksetup -setwebproxystate 'USB 10/100/1000 LAN' on
            networksetup -setsecurewebproxystate 'USB 10/100/1000 LAN' on
            networksetup -setsocksfirewallproxystate 'USB 10/100/1000 LAN' on
            """
        )
    }

    func testEnableInvocationsUseRawArgumentsForProcessExecution() {
        let commands = MacProxySetupCommands(networkService: "USB 10/100/1000 LAN", httpPort: 19080, socksPort: 19081)

        XCTAssertEqual(commands.enableInvocations.first?.arguments, ["-setwebproxy", "USB 10/100/1000 LAN", "127.0.0.1", "19080"])
        XCTAssertEqual(commands.enableInvocations.last?.arguments, ["-setsocksfirewallproxystate", "USB 10/100/1000 LAN", "on"])
        XCTAssertEqual(MacProxySetupCommandInvocation.executablePath, "/usr/sbin/networksetup")
    }

    func testDisableCommandsQuoteSingleQuotesSafely() {
        let commands = MacProxySetupCommands(networkService: "Bob's Wi-Fi", httpPort: 19080, socksPort: 19081)

        XCTAssertEqual(
            commands.disableCommands,
            """
            networksetup -setwebproxystate 'Bob'\\''s Wi-Fi' off
            networksetup -setsecurewebproxystate 'Bob'\\''s Wi-Fi' off
            networksetup -setsocksfirewallproxystate 'Bob'\\''s Wi-Fi' off
            """
        )
    }

    func testListNetworkServicesCommand() {
        XCTAssertEqual(MacProxySetupCommands.listNetworkServicesCommand, "networksetup -listallnetworkservices")
    }

    func testNetworkServiceListParserDropsHeaderAndNormalizesDisabledServices() {
        let output = """
        An asterisk (*) denotes that a network service is disabled.
        USB<->Serial Cable
        Ethernet
        *Legacy VPN
        Wi-Fi
        Wi-Fi

        """

        XCTAssertEqual(
            MacNetworkServiceList.parse(output),
            ["USB<->Serial Cable", "Ethernet", "Legacy VPN", "Wi-Fi"]
        )
    }

    func testSystemProxyStatusDetectsActiveAndInactivePorts() {
        let web = MacProxyEndpointStatus.parse(
            """
            Enabled: Yes
            Server: 127.0.0.1
            Port: 19080
            Authenticated Proxy Enabled: 0
            """
        )
        let secureWeb = MacProxyEndpointStatus.parse("Enabled: Yes\nServer: 127.0.0.1\nPort: 19080\n")
        let socks = MacProxyEndpointStatus.parse("Enabled: Yes\nServer: 127.0.0.1\nPort: 19081\n")

        let active = MacSystemProxyStatus(web: web, secureWeb: secureWeb, socks: socks, expectedHTTPPort: 19080, expectedSOCKSPort: 19081)
        XCTAssertEqual(active.activation, .active)
        XCTAssertTrue(active.isFullyManaged)
        XCTAssertFalse(active.isPartiallyManaged)
        XCTAssertEqual(active.summary, "Active: HTTP 19080, SOCKS5 19081")

        let inactive = MacSystemProxyStatus(web: web, secureWeb: secureWeb, socks: socks, expectedHTTPPort: 6152, expectedSOCKSPort: 6153)
        XCTAssertEqual(inactive.activation, .inactive)
        XCTAssertFalse(inactive.isFullyManaged)
        XCTAssertFalse(inactive.isPartiallyManaged)
        XCTAssertTrue(inactive.summary.contains("HTTP 127.0.0.1:19080"))
    }

    func testSystemProxyStatusDetectsPartialConfiguration() {
        let web = MacProxyEndpointStatus.parse("Enabled: Yes\nServer: 127.0.0.1\nPort: 19080\n")
        let secureWeb = MacProxyEndpointStatus.parse("Enabled: No\nServer: \nPort: 0\n")
        let socks = MacProxyEndpointStatus.parse("Enabled: Yes\nServer: 127.0.0.1\nPort: 19081\n")

        let status = MacSystemProxyStatus(web: web, secureWeb: secureWeb, socks: socks, expectedHTTPPort: 19080, expectedSOCKSPort: 19081)
        XCTAssertEqual(status.activation, .partial)
        XCTAssertFalse(status.isFullyManaged)
        XCTAssertTrue(status.isPartiallyManaged)
        XCTAssertTrue(status.summary.contains("HTTPS off"))
    }

    func testSystemProxyStatusBuildsRestoreInvocations() {
        let web = MacProxyEndpointStatus.parse("Enabled: Yes\nServer: 127.0.0.1\nPort: 6152\n")
        let secureWeb = MacProxyEndpointStatus.parse("Enabled: Yes\nServer: 127.0.0.1\nPort: 6152\n")
        let socks = MacProxyEndpointStatus.parse("Enabled: No\nServer: 127.0.0.1\nPort: 6153\n")
        let status = MacSystemProxyStatus(web: web, secureWeb: secureWeb, socks: socks, expectedHTTPPort: 19080, expectedSOCKSPort: 19081)

        XCTAssertEqual(
            status.restoreInvocations(networkService: "Wi-Fi").map(\.displayCommand).joined(separator: "\n"),
            """
            networksetup -setwebproxy Wi-Fi 127.0.0.1 6152
            networksetup -setwebproxystate Wi-Fi on
            networksetup -setsecurewebproxy Wi-Fi 127.0.0.1 6152
            networksetup -setsecurewebproxystate Wi-Fi on
            networksetup -setsocksfirewallproxy Wi-Fi 127.0.0.1 6153
            networksetup -setsocksfirewallproxystate Wi-Fi off
            """
        )
    }

    func testUnknownSystemProxyStatusHasNoRestoreInvocations() {
        let status = MacSystemProxyStatus.unknown(expectedHTTPPort: 19080, expectedSOCKSPort: 19081)

        XCTAssertTrue(status.restoreInvocations(networkService: "Wi-Fi").isEmpty)
    }

    func testSystemProxyStatusCodableRoundTrip() throws {
        let status = MacSystemProxyStatus(
            web: MacProxyEndpointStatus(enabled: true, server: "127.0.0.1", port: 6152),
            secureWeb: MacProxyEndpointStatus(enabled: true, server: "127.0.0.1", port: 6152),
            socks: MacProxyEndpointStatus(enabled: false, server: "127.0.0.1", port: 6153),
            expectedHTTPPort: 19080,
            expectedSOCKSPort: 19081
        )

        let data = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(MacSystemProxyStatus.self, from: data)

        XCTAssertEqual(decoded, status)
        XCTAssertEqual(decoded.restoreInvocations(networkService: "Wi-Fi").count, 6)
    }
}
