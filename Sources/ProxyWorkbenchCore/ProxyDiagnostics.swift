import Foundation

struct ProxyFailureContext: Sendable {
    var method: String = "-"
    var target: String = "-"
    var host: String = "-"
    var port: Int = 0
    var policy: String = "DIRECT"
    var rule: String?
    var note: String = "Local proxy request"

    func failedEvent(error: Error) -> ProxyServerEvent {
        ProxyServerEvent(
            method: method,
            target: target,
            host: host,
            port: port,
            policy: policy,
            status: "Failed",
            rule: rule,
            note: "\(note); error: \(String(describing: error))"
        )
    }
}

struct ProxyRelayResult: Sendable {
    var bytes: Int
    var error: String?
}

struct ProxyTunnelSummary: Sendable {
    var uploadBytes: Int
    var downloadBytes: Int
    var uploadError: String?
    var downloadError: String?

    var status: String {
        if downloadBytes == 0 {
            return "Failed"
        }
        return "Closed"
    }

    var note: String {
        var parts = [
            "tunnel \(Self.formatBytes(uploadBytes)) up / \(Self.formatBytes(downloadBytes)) down"
        ]
        if let uploadError {
            parts.append("upload \(uploadError)")
        }
        if let downloadError {
            parts.append("download \(downloadError)")
        }
        if downloadBytes == 0 {
            parts.append("no upstream response bytes")
        }
        return parts.joined(separator: "; ")
    }

    private static func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        }
        let kib = Double(bytes) / 1024.0
        if kib < 1024 {
            return String(format: "%.1f KiB", kib)
        }
        return String(format: "%.1f MiB", kib / 1024.0)
    }
}

enum ProxySocketErrorDescription {
    static func posix(_ operation: String, _ code: Int32) -> String {
        "\(operation) failed: \(String(cString: strerror(code)))"
    }
}
