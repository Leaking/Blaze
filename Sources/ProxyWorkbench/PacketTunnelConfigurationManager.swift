import Foundation
@preconcurrency import NetworkExtension

enum PacketTunnelConfigurationError: Error, CustomStringConvertible {
    case missingProtocolConfiguration
    case managerNotFound

    var description: String {
        switch self {
        case .missingProtocolConfiguration:
            "Packet tunnel protocol configuration is missing"
        case .managerNotFound:
            "Packet tunnel configuration was not found"
        }
    }
}

struct PacketTunnelStatusSnapshot: Hashable, Sendable {
    var text: String
    var isConnected: Bool
    var isTransitioning: Bool
}

@MainActor
enum PacketTunnelConfigurationManager {
    static let localizedDescription = "blaze Packet Tunnel"

    static func installOrUpdateConfiguration(httpPort: Int, socksPort: Int, excludedIPv4Addresses: [String] = []) async throws {
        let manager = try await loadOrCreateManager()
        let tunnelProtocol = NETunnelProviderProtocol()
        tunnelProtocol.providerBundleIdentifier = SystemExtensionController.extensionIdentifier
        tunnelProtocol.serverAddress = "blaze"
        tunnelProtocol.providerConfiguration = [
            "mode": "tun2socks",
            "createdBy": "blaze",
            "httpHost": "127.0.0.1",
            "httpPort": httpPort,
            "socksHost": "127.0.0.1",
            "socksPort": socksPort,
            "dnsOverHTTPSURL": "https://1.1.1.1/dns-query",
            "excludedIPv4Addresses": excludedIPv4Addresses,
            "suppressIPv6DNS": true,
            "enableFakeIPDNS": true,
            "enableUDPRelay": false
        ]

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
