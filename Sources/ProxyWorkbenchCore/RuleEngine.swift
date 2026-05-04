import Foundation
import Darwin

public struct RuleMatch: Identifiable, Hashable, Sendable {
    public var id: String { rule.id }
    public var rule: ProxyRule
    public var normalizedInput: String
    public var reason: String

    public init(rule: ProxyRule, normalizedInput: String, reason: String) {
        self.rule = rule
        self.normalizedInput = normalizedInput
        self.reason = reason
    }
}

public struct RuleEngine: Sendable {
    public static let supportedRuleTypes: Set<String> = [
        "DOMAIN",
        "DOMAIN-SUFFIX",
        "DOMAIN-KEYWORD",
        "DOMAIN-WILDCARD",
        "URL-REGEX",
        "IP-CIDR",
        "IP-CIDR6",
        "DEST-PORT",
        "FINAL",
        "MATCH"
    ]

    public static let externallyExpandedRuleTypes: Set<String> = [
        "RULE-SET"
    ]

    public var rules: [ProxyRule]

    public init(rules: [ProxyRule]) {
        self.rules = rules
    }

    public func firstMatch(for input: String) -> RuleMatch? {
        let target = NormalizedRuleTarget(input: input)
        for rule in rules {
            if let reason = match(rule: rule, target: target) {
                return RuleMatch(rule: rule, normalizedInput: target.hostOrInput, reason: reason)
            }
        }
        return nil
    }

    private func match(rule: ProxyRule, target: NormalizedRuleTarget) -> String? {
        switch rule.type {
        case "DOMAIN":
            return target.hostOrInput == rule.value.lowercased() ? "Exact domain" : nil
        case "DOMAIN-SUFFIX":
            let suffix = rule.value.lowercased()
            if target.hostOrInput == suffix || target.hostOrInput.hasSuffix(".\(suffix)") {
                return "Domain suffix"
            }
            return nil
        case "DOMAIN-KEYWORD":
            return target.hostOrInput.contains(rule.value.lowercased()) ? "Domain keyword" : nil
        case "DOMAIN-WILDCARD":
            return wildcard(pattern: rule.value.lowercased(), matches: target.hostOrInput) ? "Domain wildcard" : nil
        case "URL-REGEX":
            guard let regex = try? NSRegularExpression(pattern: rule.value, options: [.caseInsensitive]) else {
                return nil
            }
            let range = NSRange(target.original.startIndex..<target.original.endIndex, in: target.original)
            return regex.firstMatch(in: target.original, range: range) == nil ? nil : "URL regex"
        case "IP-CIDR":
            return ipv4CIDRContains(ip: target.hostOrInput, cidr: rule.value) ? "IPv4 CIDR" : nil
        case "IP-CIDR6":
            return ipv6CIDRContains(ip: target.hostOrInput, cidr: rule.value) ? "IPv6 CIDR" : nil
        case "DEST-PORT":
            guard let port = target.port else { return nil }
            return portSet(rule.value).contains(port) ? "Destination port" : nil
        case "FINAL", "MATCH":
            return "Fallback"
        default:
            return nil
        }
    }

    private func wildcard(pattern: String, matches value: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".")
        guard let regex = try? NSRegularExpression(pattern: "^\(escaped)$", options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.firstMatch(in: value, range: range) != nil
    }

    private func portSet(_ value: String) -> Set<Int> {
        var result = Set<Int>()
        for part in value.split(separator: ";") {
            if part.contains("-") {
                let bounds = part.split(separator: "-", maxSplits: 1)
                guard bounds.count == 2, let lower = Int(bounds[0]), let upper = Int(bounds[1]), lower <= upper else {
                    continue
                }
                result.formUnion(lower...upper)
            } else if let port = Int(part) {
                result.insert(port)
            }
        }
        return result
    }

    private func ipv4CIDRContains(ip: String, cidr: String) -> Bool {
        let parts = cidr.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let base = ipv4Number(parts[0]),
              let candidate = ipv4Number(ip),
              let prefix = Int(parts[1]),
              (0...32).contains(prefix)
        else {
            return false
        }

        let mask: UInt32 = prefix == 0 ? 0 : UInt32.max << UInt32(32 - prefix)
        return (base & mask) == (candidate & mask)
    }

    private func ipv4Number(_ value: String) -> UInt32? {
        let parts = value.split(separator: ".")
        guard parts.count == 4 else { return nil }

        var number: UInt32 = 0
        for part in parts {
            guard let byte = UInt8(part) else { return nil }
            number = (number << 8) | UInt32(byte)
        }
        return number
    }

    private func ipv6CIDRContains(ip: String, cidr: String) -> Bool {
        let parts = cidr.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let base = ipv6Bytes(parts[0]),
              let candidate = ipv6Bytes(ip),
              let prefix = Int(parts[1]),
              (0...128).contains(prefix)
        else {
            return false
        }

        let fullBytes = prefix / 8
        let remainingBits = prefix % 8

        if fullBytes > 0 && base[..<fullBytes] != candidate[..<fullBytes] {
            return false
        }

        guard remainingBits > 0 else {
            return true
        }

        let mask = UInt8.max << UInt8(8 - remainingBits)
        return (base[fullBytes] & mask) == (candidate[fullBytes] & mask)
    }

    private func ipv6Bytes(_ value: String) -> [UInt8]? {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("["), normalized.hasSuffix("]") {
            normalized.removeFirst()
            normalized.removeLast()
        }

        var address = in6_addr()
        let result = normalized.withCString { pointer in
            inet_pton(AF_INET6, pointer, &address)
        }
        guard result == 1 else { return nil }

        return withUnsafeBytes(of: address) { Array($0) }
    }
}

private struct NormalizedRuleTarget: Sendable {
    var original: String
    var hostOrInput: String
    var port: Int?

    init(input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        original = trimmed

        if let url = URLComponents(string: trimmed), let host = url.host {
            hostOrInput = host.lowercased()
            port = url.port ?? Self.defaultPort(for: url.scheme)
            return
        }

        if trimmed.hasPrefix("["),
           let end = trimmed.firstIndex(of: "]") {
            hostOrInput = String(trimmed[trimmed.index(after: trimmed.startIndex)..<end]).lowercased()
            let tail = trimmed[trimmed.index(after: end)...]
            port = tail.hasPrefix(":") ? Int(tail.dropFirst()) : nil
            return
        }

        if let colon = trimmed.lastIndex(of: ":"),
           trimmed[..<colon].contains("."),
           Int(trimmed[trimmed.index(after: colon)...]) != nil {
            hostOrInput = String(trimmed[..<colon]).lowercased()
            port = Int(trimmed[trimmed.index(after: colon)...])
            return
        }

        hostOrInput = trimmed.lowercased()
        port = nil
    }

    private static func defaultPort(for scheme: String?) -> Int? {
        switch scheme?.lowercased() {
        case "http": 80
        case "https": 443
        case "ws": 80
        case "wss": 443
        default: nil
        }
    }
}
