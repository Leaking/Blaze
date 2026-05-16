import Foundation
import NetworkExtension
import os.log

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let logger = Logger(subsystem: "com.chenhuazhao.blaze.tunnel", category: "PacketTunnelProvider")
    private var engine: PacketTunnelEngine?
    private var packetReadInProgress = false

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let tunnelProtocol = protocolConfiguration as? NETunnelProviderProtocol
        let configuration = PacketTunnelRuntimeConfiguration(providerConfiguration: tunnelProtocol?.providerConfiguration)
        logger.info("Starting blaze packet tunnel: socks=\(configuration.socksHost, privacy: .public):\(configuration.socksPort, privacy: .public), http=\(configuration.httpHost, privacy: .public):\(configuration.httpPort, privacy: .public), excludedIPv4=\(configuration.excludedIPv4Addresses.count, privacy: .public), suppressIPv6DNS=\(configuration.suppressIPv6DNS, privacy: .public)")

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "254.1.1.1")
        settings.mtu = 1500

        let ipv4 = NEIPv4Settings(addresses: ["10.255.0.2"], subnetMasks: ["255.255.255.255"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        var excludedRoutes = [
            NEIPv4Route(destinationAddress: "10.0.0.0", subnetMask: "255.0.0.0"),
            NEIPv4Route(destinationAddress: "100.64.0.0", subnetMask: "255.192.0.0"),
            NEIPv4Route(destinationAddress: "127.0.0.0", subnetMask: "255.0.0.0"),
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

        let dns = NEDNSSettings(servers: ["9.9.9.9", "1.1.1.1"])
        dns.matchDomains = [""]
        settings.dnsSettings = dns

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

        let engine = PacketTunnelEngine(packetFlow: packetFlow, configuration: configuration)
        self.engine = engine

        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error {
                self?.logger.error("Failed to apply tunnel settings: \(String(describing: error), privacy: .public)")
                completionHandler(error)
                return
            }

            self?.startPacketReadLoop()
            self?.logger.info("Blaze packet tunnel forwarding started")
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
        completionHandler?(Data("blaze-tunnel-ok".utf8))
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
}
