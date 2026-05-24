import Foundation

#if os(macOS)

// MacProxySetupCommands wraps `networksetup` / `scutil` invocations to flip
// the system-wide HTTP/SOCKS5 proxy on macOS. iOS has no system-wide proxy
// switch — the packet tunnel is the only way to take over traffic — so the
// whole file is mac-only.

public struct MacProxySetupCommands: Hashable, Sendable {
    public var networkService: String
    public var httpPort: Int
    public var socksPort: Int

    public init(networkService: String, httpPort: Int, socksPort: Int) {
        self.networkService = networkService
        self.httpPort = httpPort
        self.socksPort = socksPort
    }

    public var enableCommands: String {
        enableInvocations.map(\.displayCommand).joined(separator: "\n")
    }

    public var disableCommands: String {
        disableInvocations.map(\.displayCommand).joined(separator: "\n")
    }

    public var enableInvocations: [MacProxySetupCommandInvocation] {
        [
            MacProxySetupCommandInvocation(arguments: ["-setwebproxy", networkService, "127.0.0.1", "\(httpPort)"]),
            MacProxySetupCommandInvocation(arguments: ["-setsecurewebproxy", networkService, "127.0.0.1", "\(httpPort)"]),
            MacProxySetupCommandInvocation(arguments: ["-setsocksfirewallproxy", networkService, "127.0.0.1", "\(socksPort)"]),
            MacProxySetupCommandInvocation(arguments: ["-setwebproxystate", networkService, "on"]),
            MacProxySetupCommandInvocation(arguments: ["-setsecurewebproxystate", networkService, "on"]),
            MacProxySetupCommandInvocation(arguments: ["-setsocksfirewallproxystate", networkService, "on"])
        ]
    }

    public var disableInvocations: [MacProxySetupCommandInvocation] {
        [
            MacProxySetupCommandInvocation(arguments: ["-setwebproxystate", networkService, "off"]),
            MacProxySetupCommandInvocation(arguments: ["-setsecurewebproxystate", networkService, "off"]),
            MacProxySetupCommandInvocation(arguments: ["-setsocksfirewallproxystate", networkService, "off"])
        ]
    }

    public static let listNetworkServicesCommand = "networksetup -listallnetworkservices"

    public static func shellQuoted(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "''"
        }
        return "'" + trimmed.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func shellWord(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "''"
        }
        let safeCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._/:")
        if trimmed.unicodeScalars.allSatisfy({ safeCharacters.contains($0) }) {
            return trimmed
        }
        return shellQuoted(trimmed)
    }
}

public struct MacProxySetupCommandInvocation: Hashable, Sendable {
    public static let executablePath = "/usr/sbin/networksetup"

    public var arguments: [String]

    public init(arguments: [String]) {
        self.arguments = arguments
    }

    public var displayCommand: String {
        (["networksetup"] + arguments.map(MacProxySetupCommands.shellWord)).joined(separator: " ")
    }
}

public enum MacNetworkServiceList: Sendable {
    public static func parse(_ output: String) -> [String] {
        var seen = Set<String>()
        var services: [String] = []

        for rawLine in output.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("An asterisk") {
                continue
            }
            if line.hasPrefix("*") {
                line = String(line.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !line.isEmpty, !seen.contains(line) else { continue }
            seen.insert(line)
            services.append(line)
        }

        return services
    }
}

public struct MacProxyEndpointStatus: Hashable, Codable, Sendable {
    public var enabled: Bool
    public var server: String
    public var port: Int?

    public init(enabled: Bool, server: String, port: Int?) {
        self.enabled = enabled
        self.server = server
        self.port = port
    }

    public static func parse(_ output: String) -> MacProxyEndpointStatus {
        var enabled = false
        var server = ""
        var port: Int?

        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)

            switch key {
            case "enabled":
                enabled = ["yes", "true", "1", "on"].contains(value.lowercased())
            case "server":
                server = String(value)
            case "port":
                port = Int(value)
            default:
                continue
            }
        }

        return MacProxyEndpointStatus(enabled: enabled, server: server, port: port)
    }

    public func matches(host: String, port expectedPort: Int) -> Bool {
        enabled && server == host && port == expectedPort
    }
}

public struct MacSystemProxyStatus: Hashable, Codable, Sendable {
    public enum Activation: String, Hashable, Codable, Sendable {
        case active = "Active"
        case partial = "Partial"
        case inactive = "Inactive"
        case unknown = "Unknown"
    }

    public var web: MacProxyEndpointStatus?
    public var secureWeb: MacProxyEndpointStatus?
    public var socks: MacProxyEndpointStatus?
    public var expectedHTTPPort: Int
    public var expectedSOCKSPort: Int

    public init(web: MacProxyEndpointStatus?, secureWeb: MacProxyEndpointStatus?, socks: MacProxyEndpointStatus?, expectedHTTPPort: Int, expectedSOCKSPort: Int) {
        self.web = web
        self.secureWeb = secureWeb
        self.socks = socks
        self.expectedHTTPPort = expectedHTTPPort
        self.expectedSOCKSPort = expectedSOCKSPort
    }

    public static func unknown(expectedHTTPPort: Int, expectedSOCKSPort: Int) -> MacSystemProxyStatus {
        MacSystemProxyStatus(web: nil, secureWeb: nil, socks: nil, expectedHTTPPort: expectedHTTPPort, expectedSOCKSPort: expectedSOCKSPort)
    }

    public var activation: Activation {
        guard !managedMatches.isEmpty else {
            return .unknown
        }
        if isFullyManaged {
            return .active
        }
        if isPartiallyManaged {
            return .partial
        }
        return .inactive
    }

    public var isFullyManaged: Bool {
        managedMatches.count == 3 && managedMatches.allSatisfy { $0 }
    }

    public var isPartiallyManaged: Bool {
        managedMatches.contains(true) && !isFullyManaged
    }

    public var summary: String {
        switch activation {
        case .active:
            "Active: HTTP \(expectedHTTPPort), SOCKS5 \(expectedSOCKSPort)"
        case .partial:
            "Partial: \(endpointSummary)"
        case .inactive:
            "Inactive: \(endpointSummary)"
        case .unknown:
            "Unknown"
        }
    }

    public func restoreInvocations(networkService: String) -> [MacProxySetupCommandInvocation] {
        guard let web, let secureWeb, let socks else {
            return []
        }

        return web.restoreInvocations(
            networkService: networkService,
            setCommand: "-setwebproxy",
            stateCommand: "-setwebproxystate"
        ) + secureWeb.restoreInvocations(
            networkService: networkService,
            setCommand: "-setsecurewebproxy",
            stateCommand: "-setsecurewebproxystate"
        ) + socks.restoreInvocations(
            networkService: networkService,
            setCommand: "-setsocksfirewallproxy",
            stateCommand: "-setsocksfirewallproxystate"
        )
    }

    private var endpointSummary: String {
        [
            "HTTP \(web?.displayValue ?? "-")",
            "HTTPS \(secureWeb?.displayValue ?? "-")",
            "SOCKS5 \(socks?.displayValue ?? "-")"
        ].joined(separator: ", ")
    }

    private var managedMatches: [Bool] {
        guard let web, let secureWeb, let socks else {
            return []
        }
        return [
            web.matches(host: "127.0.0.1", port: expectedHTTPPort),
            secureWeb.matches(host: "127.0.0.1", port: expectedHTTPPort),
            socks.matches(host: "127.0.0.1", port: expectedSOCKSPort)
        ]
    }
}

public struct MacEffectiveProxyStatus: Hashable, Sendable {
    public var web: MacProxyEndpointStatus?
    public var secureWeb: MacProxyEndpointStatus?
    public var socks: MacProxyEndpointStatus?
    public var expectedHTTPPort: Int
    public var expectedSOCKSPort: Int

    public init(web: MacProxyEndpointStatus?, secureWeb: MacProxyEndpointStatus?, socks: MacProxyEndpointStatus?, expectedHTTPPort: Int, expectedSOCKSPort: Int) {
        self.web = web
        self.secureWeb = secureWeb
        self.socks = socks
        self.expectedHTTPPort = expectedHTTPPort
        self.expectedSOCKSPort = expectedSOCKSPort
    }

    public static func unknown(expectedHTTPPort: Int, expectedSOCKSPort: Int) -> MacEffectiveProxyStatus {
        MacEffectiveProxyStatus(web: nil, secureWeb: nil, socks: nil, expectedHTTPPort: expectedHTTPPort, expectedSOCKSPort: expectedSOCKSPort)
    }

    public static func parseScutilProxy(_ output: String, expectedHTTPPort: Int, expectedSOCKSPort: Int) -> MacEffectiveProxyStatus {
        var values: [String: String] = [:]
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            values[String(key)] = String(value)
        }

        return MacEffectiveProxyStatus(
            web: endpoint(enableKey: "HTTPEnable", proxyKey: "HTTPProxy", portKey: "HTTPPort", values: values),
            secureWeb: endpoint(enableKey: "HTTPSEnable", proxyKey: "HTTPSProxy", portKey: "HTTPSPort", values: values),
            socks: endpoint(enableKey: "SOCKSEnable", proxyKey: "SOCKSProxy", portKey: "SOCKSPort", values: values),
            expectedHTTPPort: expectedHTTPPort,
            expectedSOCKSPort: expectedSOCKSPort
        )
    }

    public var matchesBlaze: Bool {
        web?.matches(host: "127.0.0.1", port: expectedHTTPPort) == true
            && secureWeb?.matches(host: "127.0.0.1", port: expectedHTTPPort) == true
            && socks?.matches(host: "127.0.0.1", port: expectedSOCKSPort) == true
    }

    public var anyProxyEnabled: Bool {
        [web, secureWeb, socks].contains { endpoint in
            endpoint?.enabled == true
        }
    }

    public var summary: String {
        if matchesBlaze {
            return "Blaze: HTTP \(expectedHTTPPort), SOCKS5 \(expectedSOCKSPort)"
        }
        if anyProxyEnabled {
            return "Elsewhere: \(endpointSummary)"
        }
        if web == nil && secureWeb == nil && socks == nil {
            return "Unknown"
        }
        return "Off"
    }

    private var endpointSummary: String {
        [
            "HTTP \(web?.displayValue ?? "-")",
            "HTTPS \(secureWeb?.displayValue ?? "-")",
            "SOCKS5 \(socks?.displayValue ?? "-")"
        ].joined(separator: ", ")
    }

    private static func endpoint(enableKey: String, proxyKey: String, portKey: String, values: [String: String]) -> MacProxyEndpointStatus {
        let enabled = ["1", "yes", "true", "on"].contains(values[enableKey]?.lowercased() ?? "")
        let server = values[proxyKey] ?? ""
        let port = values[portKey].flatMap(Int.init)
        return MacProxyEndpointStatus(enabled: enabled, server: server, port: port)
    }
}

private extension MacProxyEndpointStatus {
    var displayValue: String {
        guard enabled else { return "off" }
        if let port {
            return "\(server):\(port)"
        }
        return server.isEmpty ? "on" : server
    }

    func restoreInvocations(networkService: String, setCommand: String, stateCommand: String) -> [MacProxySetupCommandInvocation] {
        let trimmedServer = server.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasValidEndpoint = !trimmedServer.isEmpty && port.map { (1...65535).contains($0) } == true
        var invocations: [MacProxySetupCommandInvocation] = []

        if hasValidEndpoint, let port {
            invocations.append(MacProxySetupCommandInvocation(arguments: [setCommand, networkService, trimmedServer, "\(port)"]))
        }

        invocations.append(MacProxySetupCommandInvocation(arguments: [stateCommand, networkService, enabled && hasValidEndpoint ? "on" : "off"]))
        return invocations
    }
}

#endif // os(macOS)
