import Darwin
import Foundation

public struct LatencyResult: Identifiable, Hashable, Sendable {
    public var id: String { proxyName }
    public var proxyName: String
    public var milliseconds: Int?
    public var status: String
    public var message: String

    public init(proxyName: String, milliseconds: Int?, status: String, message: String) {
        self.proxyName = proxyName
        self.milliseconds = milliseconds
        self.status = status
        self.message = message
    }
}

public final class LatencyProbe: Sendable {
    public init() {}

    public func measure(proxy: ProxyNode, timeout: TimeInterval = 4) async -> LatencyResult {
        guard proxy.kind.isStandardTCPProbeable else {
            return LatencyResult(proxyName: proxy.name, milliseconds: nil, status: "Skipped", message: "Protocol not TCP-probed")
        }

        guard !proxy.host.isEmpty, let portValue = proxy.port, (1...65535).contains(portValue) else {
            return LatencyResult(proxyName: proxy.name, milliseconds: nil, status: "Invalid", message: "Missing host or port")
        }

        return await Task.detached(priority: .utility) {
            Self.measureTCP(proxyName: proxy.name, host: proxy.host, port: portValue, timeout: timeout)
        }.value
    }

    private static func measureTCP(proxyName: String, host: String, port: Int, timeout: TimeInterval) -> LatencyResult {
        var hints = addrinfo(
            ai_flags: AI_NUMERICSERV,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var info: UnsafeMutablePointer<addrinfo>?
        let lookup = getaddrinfo(host, String(port), &hints, &info)
        guard lookup == 0, let first = info else {
            return LatencyResult(proxyName: proxyName, milliseconds: nil, status: "Failed", message: String(cString: gai_strerror(lookup)))
        }
        defer { freeaddrinfo(first) }

        var current: UnsafeMutablePointer<addrinfo>? = first
        var lastError = "Connection failed"

        while let address = current {
            let fd = socket(address.pointee.ai_family, address.pointee.ai_socktype, address.pointee.ai_protocol)
            if fd >= 0 {
                let started = Date()
                let flags = fcntl(fd, F_GETFL, 0)
                _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

                let connectResult = Darwin.connect(fd, address.pointee.ai_addr, address.pointee.ai_addrlen)
                if connectResult == 0 {
                    close(fd)
                    let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                    return LatencyResult(proxyName: proxyName, milliseconds: elapsed, status: "Reachable", message: "TCP connected")
                }

                if errno == EINPROGRESS {
                    var pollTarget = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    let pollResult = poll(&pollTarget, 1, Int32(timeout * 1000))
                    if pollResult > 0 {
                        var socketError: Int32 = 0
                        var length = socklen_t(MemoryLayout<Int32>.size)
                        getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length)
                        close(fd)
                        if socketError == 0 {
                            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                            return LatencyResult(proxyName: proxyName, milliseconds: elapsed, status: "Reachable", message: "TCP connected")
                        }
                        lastError = String(cString: strerror(socketError))
                    } else if pollResult == 0 {
                        close(fd)
                        return LatencyResult(proxyName: proxyName, milliseconds: nil, status: "Timeout", message: "\(Int(timeout))s timeout")
                    } else {
                        lastError = String(cString: strerror(errno))
                        close(fd)
                    }
                } else {
                    lastError = String(cString: strerror(errno))
                    close(fd)
                }
            }

            current = address.pointee.ai_next
        }

        return LatencyResult(proxyName: proxyName, milliseconds: nil, status: "Failed", message: lastError)
    }
}
