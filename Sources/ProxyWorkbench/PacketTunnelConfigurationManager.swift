import Foundation
@preconcurrency import NetworkExtension

enum PacketTunnelConfigurationError: Error, CustomStringConvertible {
    case missingProtocolConfiguration
    case managerNotFound
    case providerSessionUnavailable
    case emptyProviderResponse

    var description: String {
        switch self {
        case .missingProtocolConfiguration:
            "Packet tunnel protocol configuration is missing"
        case .managerNotFound:
            "Packet tunnel configuration was not found"
        case .providerSessionUnavailable:
            "Packet tunnel provider session is unavailable"
        case .emptyProviderResponse:
            "Packet tunnel provider returned no response"
        }
    }
}

struct PacketTunnelStatusSnapshot: Hashable, Sendable {
    var text: String
    var isConnected: Bool
    var isTransitioning: Bool
}

struct PacketTunnelDiagnosticsSnapshot: Codable, Hashable, Sendable {
    var packetsRead: UInt64
    var ipv4Packets: UInt64
    var ipv6Packets: UInt64
    var unknownPackets: UInt64
    var tcpPackets: UInt64
    var udpPackets: UInt64
    var dnsQueries: UInt64
    var fakeIPTCPDestinations: UInt64
    var fakeIPUDPDestinations: UInt64
    var udpRelayedPackets: UInt64
    var udpRejectedPackets: UInt64
    var ipv6BlackholedPackets: UInt64
    var activeTCPFlows: Int
    var activeUDPFlows: Int
    var fakeIPMappings: Int
    var tcpFlowsOpened: UInt64
    var tcpFlowsClosed: UInt64
    var tcpSocksConnectAttempts: UInt64
    var tcpSocksConnectSuccesses: UInt64
    var tcpSocksConnectFailures: UInt64
    var tcpClientBytesReceived: UInt64
    var tcpUpstreamBytesSent: UInt64
    var tcpUpstreamBytesReceived: UInt64
    var tcpClientBytesSent: UInt64
    var tcpPacketsWritten: UInt64
    var tcpRetransmittedPackets: UInt64
    var tcpResetsSent: UInt64
    var tcpPendingWriteOverflows: UInt64
    var tcpOutboundBufferOverflows: UInt64
    var tcpWindowStalls: UInt64
    var tcpUpstreamCloses: UInt64
    var hevPacketsSentToTunnel: UInt64
    var hevBytesSentToTunnel: UInt64
    var hevPacketsReceivedFromTunnel: UInt64
    var hevBytesReceivedFromTunnel: UInt64
    var hevBridgeWriteFailures: UInt64
    var hevTunnelTxPackets: UInt64
    var hevTunnelTxBytes: UInt64
    var hevTunnelRxPackets: UInt64
    var hevTunnelRxBytes: UInt64

    var summary: String {
        let base = "packets \(packetsRead), TCP \(tcpPackets), DNS \(dnsQueries), fake-IP TCP \(fakeIPTCPDestinations), active TCP \(activeTCPFlows), SOCKS \(tcpSocksConnectAttempts)/\(tcpSocksConnectSuccesses)/\(tcpSocksConnectFailures), bytes c>u \(tcpUpstreamBytesSent), u>c \(tcpClientBytesSent), writes \(tcpPacketsWritten), rtx \(tcpRetransmittedPackets), rst \(tcpResetsSent), closed \(tcpFlowsClosed)"
        let hasHevCounters = hevPacketsSentToTunnel > 0 || hevPacketsReceivedFromTunnel > 0 || hevBridgeWriteFailures > 0 || hevTunnelTxPackets > 0 || hevTunnelRxPackets > 0
        if hasHevCounters {
            return "\(base), HEV in/out \(hevPacketsSentToTunnel)/\(hevPacketsReceivedFromTunnel), HEV stats tx/rx \(hevTunnelTxPackets)/\(hevTunnelRxPackets), HEV bridge errors \(hevBridgeWriteFailures)"
        }
        return base
    }

    enum CodingKeys: String, CodingKey {
        case packetsRead
        case ipv4Packets
        case ipv6Packets
        case unknownPackets
        case tcpPackets
        case udpPackets
        case dnsQueries
        case fakeIPTCPDestinations
        case fakeIPUDPDestinations
        case udpRelayedPackets
        case udpRejectedPackets
        case ipv6BlackholedPackets
        case activeTCPFlows
        case activeUDPFlows
        case fakeIPMappings
        case tcpFlowsOpened
        case tcpFlowsClosed
        case tcpSocksConnectAttempts
        case tcpSocksConnectSuccesses
        case tcpSocksConnectFailures
        case tcpClientBytesReceived
        case tcpUpstreamBytesSent
        case tcpUpstreamBytesReceived
        case tcpClientBytesSent
        case tcpPacketsWritten
        case tcpRetransmittedPackets
        case tcpResetsSent
        case tcpPendingWriteOverflows
        case tcpOutboundBufferOverflows
        case tcpWindowStalls
        case tcpUpstreamCloses
        case hevPacketsSentToTunnel
        case hevBytesSentToTunnel
        case hevPacketsReceivedFromTunnel
        case hevBytesReceivedFromTunnel
        case hevBridgeWriteFailures
        case hevTunnelTxPackets
        case hevTunnelTxBytes
        case hevTunnelRxPackets
        case hevTunnelRxBytes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        packetsRead = try container.decodeIfPresent(UInt64.self, forKey: .packetsRead) ?? 0
        ipv4Packets = try container.decodeIfPresent(UInt64.self, forKey: .ipv4Packets) ?? 0
        ipv6Packets = try container.decodeIfPresent(UInt64.self, forKey: .ipv6Packets) ?? 0
        unknownPackets = try container.decodeIfPresent(UInt64.self, forKey: .unknownPackets) ?? 0
        tcpPackets = try container.decodeIfPresent(UInt64.self, forKey: .tcpPackets) ?? 0
        udpPackets = try container.decodeIfPresent(UInt64.self, forKey: .udpPackets) ?? 0
        dnsQueries = try container.decodeIfPresent(UInt64.self, forKey: .dnsQueries) ?? 0
        fakeIPTCPDestinations = try container.decodeIfPresent(UInt64.self, forKey: .fakeIPTCPDestinations) ?? 0
        fakeIPUDPDestinations = try container.decodeIfPresent(UInt64.self, forKey: .fakeIPUDPDestinations) ?? 0
        udpRelayedPackets = try container.decodeIfPresent(UInt64.self, forKey: .udpRelayedPackets) ?? 0
        udpRejectedPackets = try container.decodeIfPresent(UInt64.self, forKey: .udpRejectedPackets) ?? 0
        ipv6BlackholedPackets = try container.decodeIfPresent(UInt64.self, forKey: .ipv6BlackholedPackets) ?? 0
        activeTCPFlows = try container.decodeIfPresent(Int.self, forKey: .activeTCPFlows) ?? 0
        activeUDPFlows = try container.decodeIfPresent(Int.self, forKey: .activeUDPFlows) ?? 0
        fakeIPMappings = try container.decodeIfPresent(Int.self, forKey: .fakeIPMappings) ?? 0
        tcpFlowsOpened = try container.decodeIfPresent(UInt64.self, forKey: .tcpFlowsOpened) ?? 0
        tcpFlowsClosed = try container.decodeIfPresent(UInt64.self, forKey: .tcpFlowsClosed) ?? 0
        tcpSocksConnectAttempts = try container.decodeIfPresent(UInt64.self, forKey: .tcpSocksConnectAttempts) ?? 0
        tcpSocksConnectSuccesses = try container.decodeIfPresent(UInt64.self, forKey: .tcpSocksConnectSuccesses) ?? 0
        tcpSocksConnectFailures = try container.decodeIfPresent(UInt64.self, forKey: .tcpSocksConnectFailures) ?? 0
        tcpClientBytesReceived = try container.decodeIfPresent(UInt64.self, forKey: .tcpClientBytesReceived) ?? 0
        tcpUpstreamBytesSent = try container.decodeIfPresent(UInt64.self, forKey: .tcpUpstreamBytesSent) ?? 0
        tcpUpstreamBytesReceived = try container.decodeIfPresent(UInt64.self, forKey: .tcpUpstreamBytesReceived) ?? 0
        tcpClientBytesSent = try container.decodeIfPresent(UInt64.self, forKey: .tcpClientBytesSent) ?? 0
        tcpPacketsWritten = try container.decodeIfPresent(UInt64.self, forKey: .tcpPacketsWritten) ?? 0
        tcpRetransmittedPackets = try container.decodeIfPresent(UInt64.self, forKey: .tcpRetransmittedPackets) ?? 0
        tcpResetsSent = try container.decodeIfPresent(UInt64.self, forKey: .tcpResetsSent) ?? 0
        tcpPendingWriteOverflows = try container.decodeIfPresent(UInt64.self, forKey: .tcpPendingWriteOverflows) ?? 0
        tcpOutboundBufferOverflows = try container.decodeIfPresent(UInt64.self, forKey: .tcpOutboundBufferOverflows) ?? 0
        tcpWindowStalls = try container.decodeIfPresent(UInt64.self, forKey: .tcpWindowStalls) ?? 0
        tcpUpstreamCloses = try container.decodeIfPresent(UInt64.self, forKey: .tcpUpstreamCloses) ?? 0
        hevPacketsSentToTunnel = try container.decodeIfPresent(UInt64.self, forKey: .hevPacketsSentToTunnel) ?? 0
        hevBytesSentToTunnel = try container.decodeIfPresent(UInt64.self, forKey: .hevBytesSentToTunnel) ?? 0
        hevPacketsReceivedFromTunnel = try container.decodeIfPresent(UInt64.self, forKey: .hevPacketsReceivedFromTunnel) ?? 0
        hevBytesReceivedFromTunnel = try container.decodeIfPresent(UInt64.self, forKey: .hevBytesReceivedFromTunnel) ?? 0
        hevBridgeWriteFailures = try container.decodeIfPresent(UInt64.self, forKey: .hevBridgeWriteFailures) ?? 0
        hevTunnelTxPackets = try container.decodeIfPresent(UInt64.self, forKey: .hevTunnelTxPackets) ?? 0
        hevTunnelTxBytes = try container.decodeIfPresent(UInt64.self, forKey: .hevTunnelTxBytes) ?? 0
        hevTunnelRxPackets = try container.decodeIfPresent(UInt64.self, forKey: .hevTunnelRxPackets) ?? 0
        hevTunnelRxBytes = try container.decodeIfPresent(UInt64.self, forKey: .hevTunnelRxBytes) ?? 0
    }
}

@MainActor
enum PacketTunnelConfigurationManager {
    static let localizedDescription = "blaze Packet Tunnel"

    static func installOrUpdateConfiguration(
        httpPort: Int,
        socksPort: Int,
        excludedIPv4Addresses: [String] = [],
        packetEngine: String = "native",
        hevLibraryDirectory: String? = nil,
        hevUDPMode: String = "udp"
    ) async throws {
        let manager = try await loadOrCreateManager()
        let tunnelProtocol = NETunnelProviderProtocol()
        tunnelProtocol.providerBundleIdentifier = SystemExtensionController.extensionIdentifier
        tunnelProtocol.serverAddress = "blaze"
        var providerConfiguration: [String: Any] = [
            "mode": "tun2socks",
            "packetEngine": packetEngine,
            "createdBy": "blaze",
            "httpHost": "127.0.0.1",
            "httpPort": httpPort,
            "socksHost": "127.0.0.1",
            "socksPort": socksPort,
            "dnsOverHTTPSURL": "https://1.1.1.1/dns-query",
            "excludedIPv4Addresses": excludedIPv4Addresses,
            "suppressIPv6DNS": true,
            "enableFakeIPDNS": true,
            "enableUDPRelay": false,
            "enableProxySettings": false,
            "enableDNSNetworkFallback": false,
            "enableIPv6Blackhole": true,
            "hevUDPMode": hevUDPMode
        ]
        if let hevLibraryDirectory {
            providerConfiguration["hevLibraryDirectory"] = hevLibraryDirectory
        }
        tunnelProtocol.providerConfiguration = providerConfiguration

        manager.localizedDescription = localizedDescription
        manager.protocolConfiguration = tunnelProtocol
        manager.isEnabled = true
        try await save(manager)
    }

    static func startTunnel() async throws {
        let manager = try await loadExistingManager()
        try await loadFromPreferences(manager)
        guard manager.protocolConfiguration != nil else {
            throw PacketTunnelConfigurationError.missingProtocolConfiguration
        }
        if manager.connection.status == .connected || manager.connection.status == .connecting || manager.connection.status == .reasserting {
            return
        }
        try manager.connection.startVPNTunnel()
    }

    static func stopTunnel() async throws {
        let manager = try await loadExistingManager()
        manager.connection.stopVPNTunnel()
    }

    static func statusSnapshot() async throws -> PacketTunnelStatusSnapshot {
        let manager = try await loadExistingManager()
        try await loadFromPreferences(manager)
        let status = manager.connection.status
        return PacketTunnelStatusSnapshot(
            text: status.displayText,
            isConnected: status == .connected,
            isTransitioning: status == .connecting || status == .reasserting || status == .disconnecting
        )
    }

    static func diagnosticsSnapshot() async throws -> PacketTunnelDiagnosticsSnapshot {
        let manager = try await loadExistingManager()
        try await loadFromPreferences(manager)
        guard let session = manager.connection as? NETunnelProviderSession else {
            throw PacketTunnelConfigurationError.providerSessionUnavailable
        }

        let response = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            do {
                try session.sendProviderMessage(Data("diagnostics".utf8)) { responseData in
                    guard let responseData, !responseData.isEmpty else {
                        continuation.resume(throwing: PacketTunnelConfigurationError.emptyProviderResponse)
                        return
                    }
                    continuation.resume(returning: responseData)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
        return try JSONDecoder().decode(PacketTunnelDiagnosticsSnapshot.self, from: response)
    }

    private static func loadOrCreateManager() async throws -> NETunnelProviderManager {
        if let existing = try await loadManagers().first(where: { $0.localizedDescription == localizedDescription }) {
            return existing
        }
        return NETunnelProviderManager()
    }

    private static func loadExistingManager() async throws -> NETunnelProviderManager {
        guard let manager = try await loadManagers().first(where: { $0.localizedDescription == localizedDescription }) else {
            throw PacketTunnelConfigurationError.managerNotFound
        }
        return manager
    }

    private static func loadManagers() async throws -> [NETunnelProviderManager] {
        let list: ManagerList = try await withCheckedThrowingContinuation { continuation in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ManagerList(managers: managers ?? []))
                }
            }
        }
        return list.managers
    }

    private static func save(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private static func loadFromPreferences(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.loadFromPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

private struct ManagerList: @unchecked Sendable {
    var managers: [NETunnelProviderManager]
}

private extension NEVPNStatus {
    var displayText: String {
        switch self {
        case .invalid:
            return "Invalid"
        case .disconnected:
            return "Disconnected"
        case .connecting:
            return "Connecting"
        case .connected:
            return "Connected"
        case .reasserting:
            return "Reasserting"
        case .disconnecting:
            return "Disconnecting"
        @unknown default:
            return "Unknown"
        }
    }
}
