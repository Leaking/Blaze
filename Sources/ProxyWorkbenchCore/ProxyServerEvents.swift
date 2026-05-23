import Darwin
import Foundation

// Shared event/state types that survived the move from the in-process
// Swift listeners to the embedded `leaf` subprocess. Today they are
// produced by `LeafLogTailer` and consumed by `WorkbenchStore` + the UI.

public struct ProxyServerEvent: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var date: Date
    public var method: String
    public var target: String
    public var host: String
    public var port: Int
    public var policy: String
    public var status: String
    public var rule: String?
    public var note: String

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        method: String,
        target: String,
        host: String,
        port: Int,
        policy: String,
        status: String,
        rule: String? = nil,
        note: String
    ) {
        self.id = id
        self.date = date
        self.method = method
        self.target = target
        self.host = host
        self.port = port
        self.policy = policy
        self.status = status
        self.rule = rule
        self.note = note
    }
}

public struct ProxyPolicyHitStat: Identifiable, Hashable, Sendable {
    public var id: String { "\(policy)-\(status)" }
    public var policy: String
    public var status: String
    public var count: Int

    public init(policy: String, status: String, count: Int) {
        self.policy = policy
        self.status = status
        self.count = count
    }
}

public struct ProxyRuleHitStat: Identifiable, Hashable, Sendable {
    public var id: String { "\(rule)-\(status)" }
    public var rule: String
    public var status: String
    public var count: Int

    public init(rule: String, status: String, count: Int) {
        self.rule = rule
        self.status = status
        self.count = count
    }
}

public actor ProxyEventStore {
    private var storage: [ProxyServerEvent] = []
    private let limit: Int
    private let diskLogURL: URL?

    public init(limit: Int = 200, diskLogURL: URL? = nil) {
        self.limit = limit
        self.diskLogURL = diskLogURL
    }

    public func append(_ event: ProxyServerEvent) {
        storage.insert(event, at: 0)
        if storage.count > limit {
            storage.removeLast(storage.count - limit)
        }
        appendToDisk(event)
    }

    public func events() -> [ProxyServerEvent] {
        storage
    }

    public func policyHitStats() -> [ProxyPolicyHitStat] {
        let grouped = Dictionary(grouping: storage) { event in
            "\(event.policy)\u{1f}\(event.status)"
        }
        return grouped.map { _, events in
            let first = events[0]
            return ProxyPolicyHitStat(policy: first.policy, status: first.status, count: events.count)
        }
        .sorted { lhs, rhs in
            if lhs.count == rhs.count {
                if lhs.policy == rhs.policy {
                    return lhs.status < rhs.status
                }
                return lhs.policy < rhs.policy
            }
            return lhs.count > rhs.count
        }
    }

    public func ruleHitStats() -> [ProxyRuleHitStat] {
        let grouped = Dictionary(grouping: storage.compactMap { event -> ProxyServerEvent? in
            guard event.rule?.isEmpty == false else { return nil }
            return event
        }) { event in
            "\(event.rule ?? "")\u{1f}\(event.status)"
        }
        return grouped.map { _, events in
            let first = events[0]
            return ProxyRuleHitStat(rule: first.rule ?? "", status: first.status, count: events.count)
        }
        .sorted { lhs, rhs in
            if lhs.count == rhs.count {
                if lhs.rule == rhs.rule {
                    return lhs.status < rhs.status
                }
                return lhs.rule < rhs.rule
            }
            return lhs.count > rhs.count
        }
    }

    public func clear() {
        storage.removeAll()
    }

    public static func defaultDiskLogURL() -> URL? {
        guard let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return supportDirectory
            .appendingPathComponent("blaze", isDirectory: true)
            .appendingPathComponent("proxy-events.log", isDirectory: false)
    }

    private func appendToDisk(_ event: ProxyServerEvent) {
        guard let diskLogURL else { return }
        do {
            let directory = diskLogURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let line = Self.diskLine(for: event)
            let data = Data(line.utf8)
            if FileManager.default.fileExists(atPath: diskLogURL.path) {
                let handle = try FileHandle(forWritingTo: diskLogURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: diskLogURL, options: .atomic)
            }
        } catch {
            // Disk logging is diagnostic only; request handling must not depend on it.
        }
    }

    private static func diskLine(for event: ProxyServerEvent) -> String {
        let timestamp = ISO8601DateFormatter().string(from: event.date)
        let rule = event.rule ?? "-"
        return [
            timestamp,
            event.status,
            event.method,
            event.host == "-" ? event.target : "\(event.host):\(event.port)",
            "policy=\(event.policy)",
            "rule=\(rule)",
            "note=\(event.note)"
        ]
        .map { $0.replacingOccurrences(of: "\n", with: " ") }
        .joined(separator: " | ") + "\n"
    }
}

public enum ProxyServerError: Error, CustomStringConvertible, Sendable {
    case invalidPort
    case invalidRequest
    case invalidDestination
    case connectionClosed
    case headerTooLarge
    case lookup(String)
    case socks5(String)
    case trojan(String)
    case posix(String, Int32)

    public var description: String {
        switch self {
        case .invalidPort:
            "Invalid listen port"
        case .invalidRequest:
            "Invalid or unsupported HTTP proxy request"
        case .invalidDestination:
            "Invalid destination"
        case .connectionClosed:
            "Connection closed before headers were complete"
        case .headerTooLarge:
            "HTTP headers exceeded 64 KiB"
        case .lookup(let message):
            "DNS lookup failed: \(message)"
        case .socks5(let message):
            "SOCKS5 upstream failed: \(message)"
        case .trojan(let message):
            "Trojan upstream failed: \(message)"
        case .posix(let operation, let code):
            "\(operation) failed: \(String(cString: strerror(code)))"
        }
    }
}
