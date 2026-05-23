import Foundation

public enum ProxyKind: String, CaseIterable, Codable, Hashable, Sendable {
    case direct
    case reject
    case http
    case https
    case socks5
    case socks5TLS = "socks5-tls"
    case ssh
    case shadowsocks = "ss"
    case snell
    case vmess
    case trojan
    case wireGuard = "wireguard"
    case hysteria2
    case tuic
    case unknown

    public init(profileValue: String) {
        let normalized = profileValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "direct": self = .direct
        case "reject", "reject-tinygif", "reject-drop": self = .reject
        case "http": self = .http
        case "https", "tls": self = .https
        case "socks", "socks5": self = .socks5
        case "socks5-tls", "socks5tls": self = .socks5TLS
        case "ssh": self = .ssh
        case "ss", "shadowsocks": self = .shadowsocks
        case "snell": self = .snell
        case "vmess": self = .vmess
        case "trojan": self = .trojan
        case "wireguard": self = .wireGuard
        case "hysteria2", "hysteria": self = .hysteria2
        case "tuic": self = .tuic
        default: self = .unknown
        }
    }

    public var displayName: String {
        switch self {
        case .socks5TLS: "SOCKS5 TLS"
        case .shadowsocks: "Shadowsocks"
        case .wireGuard: "WireGuard"
        case .hysteria2: "Hysteria2"
        case .unknown: "Unknown"
        default: rawValue.uppercased()
        }
    }

    public var isStandardTCPProbeable: Bool {
        switch self {
        case .http, .https, .socks5, .socks5TLS, .trojan, .shadowsocks, .snell, .vmess, .hysteria2, .tuic:
            true
        default:
            false
        }
    }
}

public struct ProxyNode: Identifiable, Codable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var kind: ProxyKind
    public var rawKind: String
    public var host: String
    public var port: Int?
    public var username: String?
    public var password: String?
    public var parameters: [String: String]
    public var sourceLine: Int

    public init(
        name: String,
        kind: ProxyKind,
        rawKind: String,
        host: String,
        port: Int?,
        username: String?,
        password: String?,
        parameters: [String: String],
        sourceLine: Int
    ) {
        self.name = name
        self.kind = kind
        self.rawKind = rawKind
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.parameters = parameters
        self.sourceLine = sourceLine
    }

    public var endpoint: String {
        guard !host.isEmpty else { return "-" }
        if let port {
            return "\(host):\(port)"
        }
        return host
    }

    public var redactedUsername: String {
        guard let username, !username.isEmpty else { return "" }
        return username
    }

    public var hasSecret: Bool {
        password?.isEmpty == false || parameters.contains { key, _ in Self.isSensitive(key) }
    }

    public var redactedPassword: String {
        guard let password, !password.isEmpty else { return "" }
        return String(repeating: "*", count: min(max(password.count, 4), 10))
    }

    public var redactedParameters: [String: String] {
        parameters.mapValues { value in
            value.isEmpty ? value : value
        }.mapSensitiveKeys()
    }

    public static func isSensitive(_ key: String) -> Bool {
        let lower = key.lowercased()
        return lower.contains("pass")
            || lower.contains("token")
            || lower.contains("secret")
            || lower.contains("key")
            || lower.contains("cert")
            || lower.contains("psk")
    }
}

public enum ProxyGroupKind: String, Codable, Hashable, Sendable {
    case select
    case urlTest = "url-test"
    case fallback
    case loadBalance = "load-balance"
    case smart
    case ssid
    case unknown

    public init(profileValue: String) {
        let normalized = profileValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "select": self = .select
        case "url-test": self = .urlTest
        case "fallback": self = .fallback
        case "load-balance", "loadbalance": self = .loadBalance
        case "smart": self = .smart
        case "ssid": self = .ssid
        default: self = .unknown
        }
    }

    public var displayName: String {
        switch self {
        case .urlTest: "URL Test"
        case .loadBalance: "Load Balance"
        case .unknown: "Unknown"
        default: rawValue.capitalized
        }
    }
}

public struct ProxyGroup: Identifiable, Codable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var kind: ProxyGroupKind
    public var rawKind: String
    public var policies: [String]
    public var parameters: [String: String]
    public var sourceLine: Int

    public init(
        name: String,
        kind: ProxyGroupKind,
        rawKind: String,
        policies: [String],
        parameters: [String: String],
        sourceLine: Int
    ) {
        self.name = name
        self.kind = kind
        self.rawKind = rawKind
        self.policies = policies
        self.parameters = parameters
        self.sourceLine = sourceLine
    }
}

public struct ProxyRule: Identifiable, Codable, Hashable, Sendable {
    public var id: String { "\(sourceLine)-\(type)-\(value)-\(policy)" }
    public var type: String
    public var value: String
    public var policy: String
    public var options: [String]
    public var sourceLine: Int
    public var rawLine: String

    public init(type: String, value: String, policy: String, options: [String], sourceLine: Int, rawLine: String) {
        self.type = type
        self.value = value
        self.policy = policy
        self.options = options
        self.sourceLine = sourceLine
        self.rawLine = rawLine
    }

    public var displayCondition: String {
        value.isEmpty ? type : "\(type), \(value)"
    }
}

public struct ProfileWarning: Identifiable, Codable, Hashable, Sendable {
    public var id: String { "\(line)-\(message)" }
    public var line: Int
    public var message: String

    public init(line: Int, message: String) {
        self.line = line
        self.message = message
    }
}

public struct ProxyProfile: Codable, Hashable, Sendable {
    public var general: [String: String]
    public var proxies: [ProxyNode]
    public var groups: [ProxyGroup]
    public var rules: [ProxyRule]
    public var rawSections: [String: [String]]
    public var warnings: [ProfileWarning]

    public init(
        general: [String: String] = [:],
        proxies: [ProxyNode] = [],
        groups: [ProxyGroup] = [],
        rules: [ProxyRule] = [],
        rawSections: [String: [String]] = [:],
        warnings: [ProfileWarning] = []
    ) {
        self.general = general
        self.proxies = proxies
        self.groups = groups
        self.rules = rules
        self.rawSections = rawSections
        self.warnings = warnings
    }

    public static let empty = ProxyProfile()

    public var policyNames: Set<String> {
        var names = Set(proxies.map(\.name))
        names.formUnion(groups.map(\.name))
        names.formUnion(["DIRECT", "REJECT", "REJECT-DROP", "REJECT-TINYGIF"])
        return names
    }

    public var unsupportedSectionNames: [String] {
        let supported: Set<String> = ["general", "proxy", "proxy group", "rule"]
        return rawSections.keys
            .filter { !supported.contains($0.lowercased()) }
            .sorted()
    }
}

private extension Dictionary where Key == String, Value == String {
    func mapSensitiveKeys() -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in self {
            result[key] = ProxyNode.isSensitive(key) && !value.isEmpty ? "********" : value
        }
        return result
    }
}

public struct SavedProfile: Identifiable, Codable, Equatable, Hashable {
    public var id: UUID
    public var name: String
    public var sourceText: String
    public var sourceURL: String?
    public var importedAt: Date
    public var lastUsedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        sourceText: String,
        sourceURL: String? = nil,
        importedAt: Date = Date(),
        lastUsedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.sourceText = sourceText
        self.sourceURL = sourceURL
        self.importedAt = importedAt
        self.lastUsedAt = lastUsedAt
    }

    public var displaySource: String {
        if let url = sourceURL, !url.isEmpty { return url }
        return "Local"
    }
}
