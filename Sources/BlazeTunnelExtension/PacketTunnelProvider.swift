import Foundation
import NetworkExtension
import os.log

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let logger = Logger(subsystem: "com.chenhuazhao.blaze.tunnel", category: "PacketTunnelProvider")
    private var engine: PacketTunnelRunning?
    private var packetReadInProgress = false

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let tunnelProtocol = protocolConfiguration as? NETunnelProviderProtocol
        let configuration = PacketTunnelRuntimeConfiguration(providerConfiguration: tunnelProtocol?.providerConfiguration)
        logger.info("Starting blaze packet tunnel: engine=\(configuration.engineKind.rawValue, privacy: .public), socks=\(configuration.socksHost, privacy: .public):\(configuration.socksPort, privacy: .public), http=\(configuration.httpHost, privacy: .public):\(configuration.httpPort, privacy: .public), excludedIPv4=\(configuration.excludedIPv4Addresses.count, privacy: .public), ipv6=\(configuration.ipv6Mode.rawValue, privacy: .public), udpRelay=\(configuration.enableUDPRelay, privacy: .public), hevUDPMode=\(configuration.hevUDPMode, privacy: .public)")

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "254.1.1.1")
        settings.mtu = NSNumber(value: configuration.tunnelMTU)

        let ipv4 = NEIPv4Settings(addresses: ["10.255.0.2"], subnetMasks: ["255.255.255.255"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        var excludedRoutes = [
            NEIPv4Route(destinationAddress: "10.0.0.0", subnetMask: "255.0.0.0"),
            NEIPv4Route(destinationAddress: "100.64.0.0", subnetMask: "255.192.0.0"),
            NEIPv4Route(destinationAddress: "169.254.0.0", subnetMask: "255.255.0.0"),
            NEIPv4Route(destinationAddress: "172.16.0.0", subnetMask: "255.240.0.0"),
            NEIPv4Route(destinationAddress: "192.168.0.0", subnetMask: "255.255.0.0"),
            NEIPv4Route(destinationAddress: "224.0.0.0", subnetMask: "240.0.0.0")
        ]
        for address in configuration.excludedIPv4Addresses {
            excludedRoutes.append(NEIPv4Route(destinationAddress: address, subnetMask: "255.255.255.255"))
        }
        ipv4.excludedRoutes = excludedRoutes
        settings.ipv4Settings = ipv4

        switch configuration.ipv6Mode {
        case .blackhole:
            let ipv6 = NEIPv6Settings(addresses: ["fd7a:626c:617a:6500::2"], networkPrefixLengths: [128])
            ipv6.includedRoutes = [NEIPv6Route.default()]
            ipv6.excludedRoutes = [
                NEIPv6Route(destinationAddress: "fe80::", networkPrefixLength: 10),
                NEIPv6Route(destinationAddress: "fc00::", networkPrefixLength: 7),
                NEIPv6Route(destinationAddress: "ff00::", networkPrefixLength: 8)
            ]
            settings.ipv6Settings = ipv6
        case .passthrough:
            // Intentionally do not install ipv6Settings — the OS keeps IPv6
            // on the physical interface so IPv6-only sites work. IPv6
            // destinations are not proxied; that's the trade-off.
            break
        }

        let dns = NEDNSSettings(servers: configuration.tunnelDNSServers)
        dns.matchDomains = [""]
        settings.dnsSettings = dns

        if configuration.enableProxySettings {
            let proxy = NEProxySettings()
            proxy.httpEnabled = true
            proxy.httpServer = NEProxyServer(address: configuration.httpHost, port: configuration.httpPort)
            proxy.httpsEnabled = true
            proxy.httpsServer = NEProxyServer(address: configuration.httpHost, port: configuration.httpPort)
            proxy.excludeSimpleHostnames = true
            proxy.exceptionList = [
                "localhost",
                "127.0.0.1",
                "*.local",
                "captive.apple.com"
            ]
            settings.proxySettings = proxy
        }

        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error {
                self?.logger.error("Failed to apply tunnel settings: \(String(describing: error), privacy: .public)")
                completionHandler(error)
                return
            }

            guard let self else { return }

            do {
                self.engine = try Self.makeEngine(packetFlow: self.packetFlow, configuration: configuration)
            } catch {
                self.logger.error("Failed to start packet tunnel engine: \(String(describing: error), privacy: .public)")
                completionHandler(error)
                return
            }

            self.startPacketReadLoop()
            self.logger.info("Blaze packet tunnel forwarding started")
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        logger.info("Stopping blaze packet tunnel: \(reason.rawValue, privacy: .public)")
        packetReadInProgress = false
        engine?.stop()
        engine = nil
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        let command = String(data: messageData, encoding: .utf8) ?? ""
        switch command {
        case "diagnostics":
            guard let engine else {
                completionHandler?(Data("{}".utf8))
                return
            }
            completionHandler?(try? JSONEncoder().encode(engine.diagnosticsSnapshot()))
        default:
            completionHandler?(Data("blaze-tunnel-ok".utf8))
        }
    }

    private func startPacketReadLoop() {
        guard !packetReadInProgress else { return }
        packetReadInProgress = true
        readPackets()
    }

    private func readPackets() {
        guard packetReadInProgress else { return }
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self else { return }
            self.engine?.handlePackets(packets, protocols: protocols)
            self.readPackets()
        }
    }

    private static func makeEngine(packetFlow: NEPacketTunnelFlow, configuration: PacketTunnelRuntimeConfiguration) throws -> PacketTunnelRunning {
        switch configuration.engineKind {
        case .native:
            return PacketTunnelEngine(packetFlow: packetFlow, configuration: configuration)
        case .hev:
            return try HevPacketTunnelEngine(packetFlow: packetFlow, configuration: configuration)
        }
    }
}
