import Darwin
import Foundation

public struct GeneralBypassMatch: Hashable, Sendable {
    public var sourceKey: String
    public var entry: String
    public var reason: String

    public init(sourceKey: String, entry: String, reason: String) {
        self.sourceKey = sourceKey
        self.entry = entry
        self.reason = reason
    }
}

public struct GeneralBypassMatcher: Sendable {
    private var entries: [Entry]

    public init(profile: ProxyProfile) {
        entries = profile.general.flatMap { key, value -> [Entry] in
            let normalizedKey = key.lowercased()
            guard normalizedKey == "skip-proxy" || normalizedKey == "bypass-tun" else {
                return []
            }
            return ValueListParser.split(value)
                .filter { !$0.isEmpty }
                .map { Entry(sourceKey: key, rawValue: $0) }
        }
    }

    public func firstMatch(for input: String) -> GeneralBypassMatch? {
        guard !entries.isEmpty else { return nil }
        let target = BypassTarget(input: input)
        for entry in entries {
            if let reason = entry.matches(target: target) {
                return GeneralBypassMatch(sourceKey: entry.sourceKey, entry: entry.rawValue, reason: reason)
            }
        }
        return nil
    }
}

private struct Entry: Sendable {
    var sourceKey: String
    var rawValue: String

    func matches(target: BypassTarget) -> String? {
        let entry = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !entry.isEmpty else { return nil }

        if entry == "*" {
            return "Wildcard bypass"
        }

        if entry.contains("/") {
            if ipv4CIDRContains(ip: target.host, cidr: entry) {
                return "IPv4 bypass CIDR"
            }
            if ipv6CIDRContains(ip: target.host, cidr: entry) {
                return "IPv6 bypass CIDR"
            }
        }

        if entry.hasPrefix("*.") {
            let suffix = String(entry.dropFirst(2))
            if target.host == suffix || target.host.hasSuffix(".\(suffix)") {
                return "Bypass domain wildcard"
            }
            return nil
        }

        if entry.hasPrefix(".") {
            let suffix = String(entry.dropFirst())
            if target.host == suffix || target.host.hasSuffix(".\(suffix)") {
                return "Bypass domain suffix"
            }
            return nil
        }

        if target.host == entry {
            return "Bypass host"
        }

        return nil
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

private struct BypassTarget: Sendable {
    var host: String

    init(input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        if let url = URLComponents(string: trimmed), let host = url.host {
            self.host = Self.normalize(host)
            return
        }

        if trimmed.hasPrefix("["),
           let end = trimmed.firstIndex(of: "]") {
            self.host = Self.normalize(String(trimmed[trimmed.index(after: trimmed.startIndex)..<end]))
            return
        }

        if let colon = trimmed.lastIndex(of: ":"),
           Int(trimmed[trimmed.index(after: colon)...]) != nil {
            self.host = Self.normalize(String(trimmed[..<colon]))
            return
        }

        self.host = Self.normalize(trimmed)
    }

    private static func normalize(_ value: String) -> String {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("["), normalized.hasSuffix("]") {
            normalized.removeFirst()
            normalized.removeLast()
        }
        return normalized
    }
}
