import Darwin
import Foundation

public actor LocalSOCKS5ProxyServer {
    private var listenerFD: Int32 = -1
    private var acceptTask: Task<Void, Never>?
    private let logStore: ProxyEventStore
    private let routingProfile: ProxyProfile
    private let groupSelections: [String: String]

    public init(logStore: ProxyEventStore, routingProfile: ProxyProfile = .empty, groupSelections: [String: String] = [:]) {
        self.logStore = logStore
        self.routingProfile = routingProfile
        self.groupSelections = groupSelections
    }

    public var isRunning: Bool {
        listenerFD >= 0
    }

    public func start(port: Int) throws {
        guard listenerFD < 0 else { return }
        guard (1...65535).contains(port) else {
            throw ProxyServerError.invalidPort
        }

        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else {
            throw ProxyServerError.posix("socket", errno)
        }
        ProxySocketOptions.prepare(fd)

        var enabled: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let saved = errno
            close(fd)
            throw ProxyServerError.posix("bind", saved)
        }

        guard listen(fd, 128) == 0 else {
            let saved = errno
            close(fd)
            throw ProxyServerError.posix("listen", saved)
        }

        listenerFD = fd
        let logStore = logStore
        let routingProfile = routingProfile
        let groupSelections = groupSelections
        acceptTask = Task.detached(priority: .utility) {
            await Self.acceptLoop(listenerFD: fd, logStore: logStore, routingProfile: routingProfile, groupSelections: groupSelections)
        }
    }

    public func stop() {
        acceptTask?.cancel()
        acceptTask = nil
        if listenerFD >= 0 {
            shutdown(listenerFD, SHUT_RDWR)
            close(listenerFD)
            listenerFD = -1
        }
    }

    private static func acceptLoop(listenerFD: Int32, logStore: ProxyEventStore, routingProfile: ProxyProfile, groupSelections: [String: String]) async {
        while !Task.isCancelled {
            let clientFD = accept(listenerFD, nil, nil)
            if clientFD >= 0 {
                ProxySocketOptions.prepare(clientFD)
                Task.detached(priority: .utility) {
                    await handleClient(clientFD, logStore: logStore, routingProfile: routingProfile, groupSelections: groupSelections)
                }
            } else if errno == EBADF || errno == EINVAL {
                break
            }
        }
    }

    private static func handleClient(_ clientFD: Int32, logStore: ProxyEventStore, routingProfile: ProxyProfile, groupSelections: [String: String]) async {
        var failureContext = ProxyFailureContext(method: "SOCKS5", target: "-", host: "-", port: 0, policy: "DIRECT", rule: nil, note: "Local SOCKS5 request")
        do {
            try acceptGreeting(from: clientFD)
            let request = try SOCKS5Request.read(from: clientFD)
            failureContext.target = request.authority
            failureContext.host = request.host
            failureContext.port = request.port
            guard request.command == 0x01 else {
                try sendSOCKSReply(0x07, to: clientFD)
                close(clientFD)
                return
            }

            let route = routeDecision(for: "\(request.host):\(request.port)", profile: routingProfile, groupSelections: groupSelections)
            failureContext.policy = route.policy
            failureContext.rule = route.rule
            failureContext.note = route.note
            switch route.action {
            case .reject:
                await logStore.append(
                    ProxyServerEvent(method: "SOCKS5", target: request.authority, host: request.host, port: request.port, policy: route.policy, status: "Rejected", rule: route.rule, note: route.note)
                )
                try sendSOCKSReply(0x02, to: clientFD)
                close(clientFD)
                return

            case .unsupported:
                await logStore.append(
                    ProxyServerEvent(method: "SOCKS5", target: request.authority, host: request.host, port: request.port, policy: route.policy, status: "Unsupported", rule: route.rule, note: route.note)
                )
                try sendSOCKSReply(0x01, to: clientFD)
                close(clientFD)
                return

            case .direct:
                let remoteFD = try connect(host: request.host, port: request.port)
                let connectedNote = route.note + "; SOCKS5 direct"
                await logStore.append(
                    ProxyServerEvent(method: "SOCKS5", target: request.authority, host: request.host, port: request.port, policy: route.policy, status: "Connected", rule: route.rule, note: connectedNote)
                )
                try sendSOCKSReply(0x00, to: clientFD)
                let summary = await tunnel(clientFD, remoteFD)
                await appendTunnelSummary(summary, request: request, route: route, note: connectedNote, to: logStore)
                return

            case .httpProxy(let upstream):
                guard let upstreamPort = upstream.port else {
                    throw ProxyServerError.invalidDestination
                }
                let remoteFD = try connect(host: upstream.host, port: upstreamPort)
                try connectViaHTTPProxy(remoteFD, destination: request.destination, upstream: upstream)
                let connectedNote = route.note + "; HTTP upstream \(upstream.endpoint)"
                await logStore.append(
                    ProxyServerEvent(method: "SOCKS5", target: request.authority, host: request.host, port: request.port, policy: route.policy, status: "Connected", rule: route.rule, note: connectedNote)
                )
                try sendSOCKSReply(0x00, to: clientFD)
                let summary = await tunnel(clientFD, remoteFD)
                await appendTunnelSummary(summary, request: request, route: route, note: connectedNote, to: logStore)
                return

            case .socks5Proxy(let upstream):
                guard let upstreamPort = upstream.port else {
                    throw ProxyServerError.invalidDestination
                }
                let remoteFD = try connect(host: upstream.host, port: upstreamPort)
                try connectViaSOCKS5(remoteFD, destination: request.destination, upstream: upstream)
                let connectedNote = route.note + "; SOCKS5 upstream \(upstream.endpoint)"
                await logStore.append(
                    ProxyServerEvent(method: "SOCKS5", target: request.authority, host: request.host, port: request.port, policy: route.policy, status: "Connected", rule: route.rule, note: connectedNote)
                )
                try sendSOCKSReply(0x00, to: clientFD)
                let summary = await tunnel(clientFD, remoteFD)
                await appendTunnelSummary(summary, request: request, route: route, note: connectedNote, to: logStore)
                return

            case .trojanProxy(let upstream):
                let connection = try await TrojanUpstreamConnection.connect(upstream: upstream, destinationHost: request.host, destinationPort: request.port)
                let connectedNote = route.note + "; Trojan upstream \(upstream.endpoint)"
                await logStore.append(
                    ProxyServerEvent(method: "SOCKS5", target: request.authority, host: request.host, port: request.port, policy: route.policy, status: "Connected", rule: route.rule, note: connectedNote)
                )
                try sendSOCKSReply(0x00, to: clientFD)
                let summary = await TrojanUpstreamConnection.tunnel(clientFD: clientFD, upstream: connection)
                await appendTunnelSummary(summary, request: request, route: route, note: connectedNote, to: logStore)
                return
            }
        } catch {
            await logStore.append(failureContext.failedEvent(error: error))
            _ = try? sendSOCKSReply(0x01, to: clientFD)
            close(clientFD)
        }
    }

    private static func appendTunnelSummary(
        _ summary: ProxyTunnelSummary,
        request: SOCKS5Request,
        route: SOCKSRouteDecision,
        note: String,
        to logStore: ProxyEventStore
    ) async {
        guard summary.status == "Failed" else { return }
        await logStore.append(
            ProxyServerEvent(
                method: "SOCKS5",
                target: request.authority,
                host: request.host,
                port: request.port,
                policy: route.policy,
                status: summary.status,
                rule: route.rule,
                note: "\(note); \(summary.note)"
            )
        )
    }

    private static func acceptGreeting(from fd: Int32) throws {
        let head = try recvExact(2, from: fd)
        guard head[0] == 0x05 else {
            throw ProxyServerError.socks5("Invalid SOCKS version")
        }
        let methods = try recvExact(Int(head[1]), from: fd)
        guard methods.contains(0x00) else {
            try sendAll(Data([0x05, 0xFF]), to: fd)
            throw ProxyServerError.socks5("Client did not offer no-auth method")
        }
        try sendAll(Data([0x05, 0x00]), to: fd)
    }

    private static func routeDecision(for input: String, profile: ProxyProfile, groupSelections: [String: String]) -> SOCKSRouteDecision {
        if let bypass = GeneralBypassMatcher(profile: profile).firstMatch(for: input) {
            return SOCKSRouteDecision(policy: "DIRECT", action: .direct, rule: "General \(bypass.sourceKey): \(bypass.entry)", note: "General \(bypass.sourceKey): \(bypass.reason) \(bypass.entry)")
        }

        guard let match = RuleEngine(rules: profile.rules).firstMatch(for: input) else {
            return SOCKSRouteDecision(policy: "DIRECT", action: .direct, rule: "No rule matched", note: "No rule matched")
        }

        let resolution = resolve(policy: match.rule.policy, in: profile, groupSelections: groupSelections, visited: [])
        let policyPath = resolution.path.joined(separator: " -> ")
        let note = "\(match.reason): \(match.rule.displayCondition); policy path: \(policyPath)"
        return SOCKSRouteDecision(policy: policyPath, action: resolution.action, rule: match.rule.displayCondition, note: note)
    }

    private static func resolve(policy: String, in profile: ProxyProfile, groupSelections: [String: String], visited: Set<String>) -> SOCKSPolicyResolution {
        let normalized = policy.uppercased()
        if normalized.hasPrefix("REJECT") {
            return SOCKSPolicyResolution(action: .reject, path: [policy])
        }
        if normalized == "DIRECT" {
            return SOCKSPolicyResolution(action: .direct, path: [policy])
        }
        guard !visited.contains(policy) else {
            return SOCKSPolicyResolution(action: .unsupported, path: [policy, "cycle"])
        }

        if let group = profile.groups.first(where: { $0.name == policy }) {
            let selected = groupSelections[policy].flatMap { group.policies.contains($0) ? $0 : nil } ?? group.policies.first
            guard let selected else {
                return SOCKSPolicyResolution(action: .unsupported, path: [policy, "empty group"])
            }
            let next = resolve(policy: selected, in: profile, groupSelections: groupSelections, visited: visited.union([policy]))
            return SOCKSPolicyResolution(action: next.action, path: [policy] + next.path)
        }

        if let node = profile.proxies.first(where: { $0.name == policy }) {
            switch node.kind {
            case .direct:
                return SOCKSPolicyResolution(action: .direct, path: [policy])
            case .reject:
                return SOCKSPolicyResolution(action: .reject, path: [policy])
            case .http:
                return SOCKSPolicyResolution(action: .httpProxy(node), path: [policy])
            case .socks5:
                return SOCKSPolicyResolution(action: .socks5Proxy(node), path: [policy])
            case .trojan:
                return SOCKSPolicyResolution(action: .trojanProxy(node), path: [policy])
            default:
                return SOCKSPolicyResolution(action: .unsupported, path: [policy, "\(node.kind.displayName) upstream unsupported"])
            }
        }

        return SOCKSPolicyResolution(action: .unsupported, path: [policy, "unknown policy"])
    }

    private static func connect(host: String, port: Int) throws -> Int32 {
        var hints = addrinfo(ai_flags: AI_NUMERICSERV, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        let lookup = getaddrinfo(host, String(port), &hints, &info)
        guard lookup == 0, let first = info else {
            throw ProxyServerError.lookup(String(cString: gai_strerror(lookup)))
        }
        defer { freeaddrinfo(first) }

        var current: UnsafeMutablePointer<addrinfo>? = first
        var savedErrno: Int32 = 0
        while let address = current {
            let fd = socket(address.pointee.ai_family, address.pointee.ai_socktype, address.pointee.ai_protocol)
            if fd >= 0 {
                ProxySocketOptions.prepare(fd)
                if Darwin.connect(fd, address.pointee.ai_addr, address.pointee.ai_addrlen) == 0 {
                    return fd
                }
                savedErrno = errno
                close(fd)
            }
            current = address.pointee.ai_next
        }
        throw ProxyServerError.posix("connect", savedErrno)
    }

    private static func connectViaHTTPProxy(_ fd: Int32, destination: SOCKSDestination, upstream: ProxyNode) throws {
        var lines = ["CONNECT \(destination.host):\(destination.port) HTTP/1.1", "Host: \(destination.host):\(destination.port)"]
        if let username = upstream.username, !username.isEmpty {
            let password = upstream.password ?? ""
            let credentials = Data("\(username):\(password)".utf8).base64EncodedString()
            lines.append("Proxy-Authorization: Basic \(credentials)")
        }
        lines.append("Connection: close")
        try sendAll(lines.joined(separator: "\r\n") + "\r\n\r\n", to: fd)

        let header = try readHTTPHeader(from: fd)
        guard header.hasPrefix("HTTP/1.1 2") || header.hasPrefix("HTTP/1.0 2") else {
            throw ProxyServerError.invalidRequest
        }
    }

    private static func connectViaSOCKS5(_ fd: Int32, destination: SOCKSDestination, upstream: ProxyNode) throws {
        let hasCredentials = (upstream.username?.isEmpty == false) || (upstream.password?.isEmpty == false)
        let methods: [UInt8] = hasCredentials ? [0x00, 0x02] : [0x00]
        try sendAll(Data([0x05, UInt8(methods.count)] + methods), to: fd)

        let choice = try recvExact(2, from: fd)
        guard choice[0] == 0x05 else {
            throw ProxyServerError.socks5("Invalid upstream greeting response")
        }
        if choice[1] == 0x02 {
            try authenticateSOCKS5(fd, upstream: upstream)
        } else if choice[1] != 0x00 {
            throw ProxyServerError.socks5("Unsupported upstream authentication method")
        }

        var request = Data([0x05, 0x01, 0x00])
        request.append(try socks5AddressBytes(host: destination.host))
        var networkPort = UInt16(destination.port).bigEndian
        withUnsafeBytes(of: &networkPort) { request.append(contentsOf: $0) }
        try sendAll(request, to: fd)

        let head = try recvExact(4, from: fd)
        guard head[0] == 0x05, head[1] == 0x00 else {
            throw ProxyServerError.socks5("Upstream connect failed")
        }
        switch head[3] {
        case 0x01:
            _ = try recvExact(4, from: fd)
        case 0x03:
            let length = try recvExact(1, from: fd)[0]
            _ = try recvExact(Int(length), from: fd)
        case 0x04:
            _ = try recvExact(16, from: fd)
        default:
            throw ProxyServerError.socks5("Invalid upstream bound address type")
        }
        _ = try recvExact(2, from: fd)
    }

    private static func authenticateSOCKS5(_ fd: Int32, upstream: ProxyNode) throws {
        let username = Data((upstream.username ?? "").utf8)
        let password = Data((upstream.password ?? "").utf8)
        guard username.count <= 255, password.count <= 255 else {
            throw ProxyServerError.socks5("SOCKS5 username/password is too long")
        }
        var auth = Data([0x01, UInt8(username.count)])
        auth.append(username)
        auth.append(UInt8(password.count))
        auth.append(password)
        try sendAll(auth, to: fd)
        let response = try recvExact(2, from: fd)
        guard response[0] == 0x01, response[1] == 0x00 else {
            throw ProxyServerError.socks5("SOCKS5 username/password authentication failed")
        }
    }

    private static func socks5AddressBytes(host: String) throws -> Data {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            var result = Data([0x01])
            withUnsafeBytes(of: &ipv4.s_addr) { result.append(contentsOf: $0) }
            return result
        }

        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, host, &ipv6) == 1 {
            var result = Data([0x04])
            withUnsafeBytes(of: &ipv6) { result.append(contentsOf: $0) }
            return result
        }

        let hostData = Data(host.utf8)
        guard hostData.count <= 255 else {
            throw ProxyServerError.socks5("Destination host is too long")
        }
        var result = Data([0x03, UInt8(hostData.count)])
        result.append(hostData)
        return result
    }

    private static func sendSOCKSReply(_ code: UInt8, to fd: Int32) throws {
        try sendAll(Data([0x05, code, 0x00, 0x01, 0, 0, 0, 0, 0, 0]), to: fd)
    }

    private static func readHTTPHeader(from fd: Int32) throws -> String {
        var data = Data()
        let terminator = Data([13, 10, 13, 10])
        var buffer = [UInt8](repeating: 0, count: 1024)
        while data.count < 64 * 1024 {
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else {
                throw ProxyServerError.connectionClosed
            }
            data.append(buffer, count: count)
            if data.range(of: terminator) != nil {
                return String(data: data, encoding: .isoLatin1) ?? ""
            }
        }
        throw ProxyServerError.headerTooLarge
    }

    private static func recvExact(_ byteCount: Int, from fd: Int32) throws -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(byteCount)
        while result.count < byteCount {
            var buffer = [UInt8](repeating: 0, count: byteCount - result.count)
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else {
                throw ProxyServerError.connectionClosed
            }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }

    private static func sendAll(_ string: String, to fd: Int32) throws {
        try sendAll(Data(string.utf8), to: fd)
    }

    private static func sendAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let count = send(fd, baseAddress.advanced(by: sent), data.count - sent, 0)
                guard count > 0 else {
                    throw ProxyServerError.posix("send", errno)
                }
                sent += count
            }
        }
    }

    private static func tunnel(_ leftFD: Int32, _ rightFD: Int32) async -> ProxyTunnelSummary {
        let leftToRight = Task.detached(priority: .utility) {
            let result = relay(from: leftFD, to: rightFD)
            shutdown(rightFD, SHUT_WR)
            return result
        }
        let rightToLeft = Task.detached(priority: .utility) {
            let result = relay(from: rightFD, to: leftFD)
            shutdown(leftFD, SHUT_WR)
            return result
        }

        let download = await rightToLeft.value
        shutdown(leftFD, SHUT_RDWR)
        shutdown(rightFD, SHUT_RDWR)
        let upload = await leftToRight.value
        close(leftFD)
        close(rightFD)
        return ProxyTunnelSummary(uploadBytes: upload.bytes, downloadBytes: download.bytes, uploadError: upload.error, downloadError: download.error)
    }

    private static func relay(from sourceFD: Int32, to destinationFD: Int32) -> ProxyRelayResult {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var bytes = 0
        while true {
            let readCount = recv(sourceFD, &buffer, buffer.count, 0)
            if readCount == 0 {
                return ProxyRelayResult(bytes: bytes, error: nil)
            }
            if readCount < 0 {
                return ProxyRelayResult(bytes: bytes, error: ProxySocketErrorDescription.posix("recv", errno))
            }
            var sent = 0
            while sent < readCount {
                let writeCount = buffer.withUnsafeBytes { rawBuffer in
                    send(destinationFD, rawBuffer.baseAddress!.advanced(by: sent), readCount - sent, 0)
                }
                guard writeCount > 0 else {
                    return ProxyRelayResult(bytes: bytes, error: ProxySocketErrorDescription.posix("send", errno))
                }
                sent += writeCount
                bytes += writeCount
            }
        }
    }
}

private struct SOCKS5Request: Sendable {
    var command: UInt8
    var destination: SOCKSDestination

    var host: String { destination.host }
    var port: Int { destination.port }
    var authority: String { "\(host):\(port)" }

    static func read(from fd: Int32) throws -> SOCKS5Request {
        let head = try LocalSOCKS5ProxyServer_recvExact(4, from: fd)
        guard head[0] == 0x05 else {
            throw ProxyServerError.socks5("Invalid SOCKS request version")
        }

        let host: String
        switch head[3] {
        case 0x01:
            let bytes = try LocalSOCKS5ProxyServer_recvExact(4, from: fd)
            host = bytes.map(String.init).joined(separator: ".")
        case 0x03:
            let length = try LocalSOCKS5ProxyServer_recvExact(1, from: fd)[0]
            let bytes = try LocalSOCKS5ProxyServer_recvExact(Int(length), from: fd)
            host = String(bytes: bytes, encoding: .utf8) ?? ""
        case 0x04:
            let bytes = try LocalSOCKS5ProxyServer_recvExact(16, from: fd)
            var storage = bytes
            var string = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            storage.withUnsafeMutableBytes { rawBuffer in
                _ = inet_ntop(AF_INET6, rawBuffer.baseAddress, &string, socklen_t(INET6_ADDRSTRLEN))
            }
            let end = string.firstIndex(of: 0) ?? string.endIndex
            host = String(decoding: string[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        default:
            throw ProxyServerError.socks5("Unsupported address type")
        }

        let portBytes = try LocalSOCKS5ProxyServer_recvExact(2, from: fd)
        let port = Int(UInt16(portBytes[0]) << 8 | UInt16(portBytes[1]))
        guard !host.isEmpty, (1...65535).contains(port) else {
            throw ProxyServerError.invalidDestination
        }

        return SOCKS5Request(command: head[1], destination: SOCKSDestination(host: host, port: port))
    }
}

private struct SOCKSDestination: Sendable {
    var host: String
    var port: Int
}

private enum SOCKSRouteAction: Sendable {
    case direct
    case reject
    case unsupported
    case httpProxy(ProxyNode)
    case socks5Proxy(ProxyNode)
    case trojanProxy(ProxyNode)
}

private struct SOCKSRouteDecision: Sendable {
    var policy: String
    var action: SOCKSRouteAction
    var rule: String
    var note: String
}

private struct SOCKSPolicyResolution: Sendable {
    var action: SOCKSRouteAction
    var path: [String]
}

private func LocalSOCKS5ProxyServer_recvExact(_ byteCount: Int, from fd: Int32) throws -> [UInt8] {
    var result: [UInt8] = []
    result.reserveCapacity(byteCount)
    while result.count < byteCount {
        var buffer = [UInt8](repeating: 0, count: byteCount - result.count)
        let count = recv(fd, &buffer, buffer.count, 0)
        guard count > 0 else {
            throw ProxyServerError.connectionClosed
        }
        result.append(contentsOf: buffer.prefix(count))
    }
    return result
}
