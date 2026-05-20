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

struct PacketTunnelConfigurationSnapshot: Hashable, Sendable {
    static let nativeVirtualDNSServer = "198.18.0.2"
    static let hevMapDNSServer = "198.19.0.1"
    static let fallbackDNSServers = ["9.9.9.9", "1.1.1.1"]
    static let defaultTunnelMTU = 1_280

    var packetEngine: String
    var tunnelMTU: Int
    var httpHost: String
    var httpPort: Int
    var socksHost: String
    var socksPort: Int
    var dnsOverHTTPSURL: String
    var excludedIPv4Addresses: [String]
    var suppressIPv6DNS: Bool
    var enableFakeIPDNS: Bool
    var enableUDPRelay: Bool
    var enableProxySettings: Bool
    var enableDNSNetworkFallback: Bool
    var enableIPv6Blackhole: Bool
    var hevLibraryDirectory: String?
    var hevUDPMode: String

    init(providerConfiguration: [String: Any]?) {
        packetEngine = Self.stringValue(providerConfiguration?["packetEngine"], defaultValue: "native")
        tunnelMTU = Self.mtuValue(providerConfiguration?["tunnelMTU"], defaultValue: Self.defaultTunnelMTU)
        httpHost = Self.stringValue(providerConfiguration?["httpHost"], defaultValue: "127.0.0.1")
        httpPort = Self.intValue(providerConfiguration?["httpPort"], defaultValue: 19080)
        socksHost = Self.stringValue(providerConfiguration?["socksHost"], defaultValue: "127.0.0.1")
        socksPort = Self.intValue(providerConfiguration?["socksPort"], defaultValue: 19081)
        dnsOverHTTPSURL = Self.stringValue(providerConfiguration?["dnsOverHTTPSURL"], defaultValue: "https://1.1.1.1/dns-query")
        excludedIPv4Addresses = Self.stringArrayValue(providerConfiguration?["excludedIPv4Addresses"])
        suppressIPv6DNS = Self.boolValue(providerConfiguration?["suppressIPv6DNS"], defaultValue: true)
        enableFakeIPDNS = Self.boolValue(providerConfiguration?["enableFakeIPDNS"], defaultValue: true)
        enableUDPRelay = Self.boolValue(providerConfiguration?["enableUDPRelay"], defaultValue: false)
        enableProxySettings = Self.boolValue(providerConfiguration?["enableProxySettings"], defaultValue: false)
        enableDNSNetworkFallback = Self.boolValue(providerConfiguration?["enableDNSNetworkFallback"], defaultValue: false)
        enableIPv6Blackhole = Self.boolValue(providerConfiguration?["enableIPv6Blackhole"], defaultValue: true)
        hevLibraryDirectory = Self.optionalStringValue(providerConfiguration?["hevLibraryDirectory"])
        hevUDPMode = Self.stringValue(providerConfiguration?["hevUDPMode"], defaultValue: "udp")
    }

    var tunnelDNSServers: [String] {
        guard enableFakeIPDNS else {
            return Self.fallbackDNSServers
        }
        return packetEngine == "hev" ? [Self.hevMapDNSServer] : [Self.nativeVirtualDNSServer]
    }

    var engineDescription: String {
        packetEngine == "hev" ? "HEV socks5 tunnel" : "Native TCP shim"
    }

    var listenerSummary: String {
        "HTTP \(httpHost):\(httpPort), SOCKS5 \(socksHost):\(socksPort)"
    }

    var dnsSummary: String {
        guard enableFakeIPDNS else {
            return "\(tunnelDNSServers.joined(separator: ", ")) system fallback; fake-IP DNS disabled"
        }
        return "\(tunnelDNSServers.joined(separator: ", ")) -> \(dnsOverHTTPSURL)"
    }

    var exclusionSummary: String {
        guard !excludedIPv4Addresses.isEmpty else {
            return "No upstream bypass addresses"
        }
        let preview = excludedIPv4Addresses.prefix(8).joined(separator: ", ")
        let suffix = excludedIPv4Addresses.count > 8 ? ", +\(excludedIPv4Addresses.count - 8) more" : ""
        return "\(excludedIPv4Addresses.count): \(preview)\(suffix)"
    }

    private static func stringValue(_ value: Any?, defaultValue: String) -> String {
        optionalStringValue(value) ?? defaultValue
    }

    private static func optionalStringValue(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    private static func intValue(_ value: Any?, defaultValue: Int) -> Int {
        if let int = value as? Int {
            return int
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        return defaultValue
    }

    private static func mtuValue(_ value: Any?, defaultValue: Int) -> Int {
        min(max(intValue(value, defaultValue: defaultValue), 576), 1_500)
    }

    private static func boolValue(_ value: Any?, defaultValue: Bool) -> Bool {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return defaultValue
    }

    private static func stringArrayValue(_ value: Any?) -> [String] {
        (value as? [String]) ?? []
    }
}

@MainActor
enum PacketTunnelConfigurationManager {
    static let localizedDescription = "blaze Packet Tunnel"

    static func installOrUpdateConfiguration(
        httpPort: Int,
        socksPort: Int,
        excludedIPv4Addresses: [String] = [],
        tunnelMTU: Int = PacketTunnelConfigurationSnapshot.defaultTunnelMTU,
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
            "tunnelMTU": min(max(tunnelMTU, 576), 1_500),
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

    static func configurationSnapshot() async throws -> PacketTunnelConfigurationSnapshot {
        let manager = try await loadExistingManager()
        try await loadFromPreferences(manager)
        guard let tunnelProtocol = manager.protocolConfiguration as? NETunnelProviderProtocol else {
            throw PacketTunnelConfigurationError.missingProtocolConfiguration
        }
        return PacketTunnelConfigurationSnapshot(providerConfiguration: tunnelProtocol.providerConfiguration)
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
