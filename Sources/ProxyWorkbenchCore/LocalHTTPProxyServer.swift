import Darwin
import Foundation

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
            .appendingPathComponent("ProxyWorkbench", isDirectory: true)
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

public actor LocalHTTPProxyServer {
    private var listenerFD: Int32 = -1
    private var acceptTask: Task<Void, Never>?
    private let logStore: ProxyEventStore
    private let routingProfile: ProxyProfile
    private let groupSelections: [String: String]

    public init(logStore: ProxyEventStore, routingRules: [ProxyRule] = []) {
        self.init(logStore: logStore, routingProfile: ProxyProfile(rules: routingRules))
    }

    public init(logStore: ProxyEventStore, routingProfile: ProxyProfile, groupSelections: [String: String] = [:]) {
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
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
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
        var failureContext = ProxyFailureContext()
        do {
            let header = try readHeader(from: clientFD)
            let request = try HTTPProxyRequest(headerText: header.headerText)

            let destination: Destination
            let initialPayload: Data?
            if request.method.uppercased() == "CONNECT" {
                destination = try Destination(authority: request.target, defaultPort: 443)
                initialPayload = nil
            } else {
                destination = try request.destinationForPlainHTTP()
                initialPayload = request.rewrittenHeader(for: destination).data(using: .utf8)! + header.extraData
            }

            failureContext.method = request.method
            failureContext.target = request.target
            failureContext.host = destination.host
            failureContext.port = destination.port

            let route = routeDecision(for: request.routeInput(destination: destination), profile: routingProfile, groupSelections: groupSelections)
            failureContext.policy = route.policy
            failureContext.rule = route.rule
            failureContext.note = route.note
            switch route.action {
            case .reject:
                await logStore.append(
                    ProxyServerEvent(
                        method: request.method,
                        target: request.target,
                        host: destination.host,
                        port: destination.port,
                        policy: route.policy,
                        status: "Rejected",
                        rule: route.rule,
                        note: route.note
                    )
                )
                _ = try? sendAll("HTTP/1.1 403 Forbidden\r\nConnection: close\r\nContent-Length: 0\r\n\r\n", to: clientFD)
                close(clientFD)
                return

            case .unsupported:
                await logStore.append(
                    ProxyServerEvent(
                        method: request.method,
                        target: request.target,
                        host: destination.host,
                        port: destination.port,
                        policy: route.policy,
                        status: "Unsupported",
                        rule: route.rule,
                        note: route.note
                    )
                )
                _ = try? sendAll("HTTP/1.1 501 Not Implemented\r\nConnection: close\r\nContent-Length: 0\r\n\r\n", to: clientFD)
                close(clientFD)
                return

            case .direct:
                let remoteFD = try connect(host: destination.host, port: destination.port)
                let connectedNote = route.note + "; " + (request.method.uppercased() == "CONNECT" ? "CONNECT tunnel" : "HTTP forward")
                await logStore.append(
                    ProxyServerEvent(
                        method: request.method,
                        target: request.target,
                        host: destination.host,
                        port: destination.port,
                        policy: route.policy,
                        status: "Connected",
                        rule: route.rule,
                        note: connectedNote
                    )
                )

                if request.method.uppercased() == "CONNECT" {
                    try sendAll("HTTP/1.1 200 Connection Established\r\nProxy-Agent: ProxyWorkbench\r\n\r\n", to: clientFD)
                } else if let initialPayload {
                    try sendAll(initialPayload, to: remoteFD)
                }

                let summary = await tunnel(clientFD, remoteFD)
                await appendTunnelSummary(summary, request: request, destination: destination, route: route, note: connectedNote, to: logStore)
                return

            case .httpProxy(let upstream):
                guard let upstreamPort = upstream.port else {
                    throw ProxyServerError.invalidDestination
                }
                let remoteFD = try connect(host: upstream.host, port: upstreamPort)
                let connectedNote = route.note + "; HTTP upstream \(upstream.endpoint)"
                await logStore.append(
                    ProxyServerEvent(
                        method: request.method,
                        target: request.target,
                        host: destination.host,
                        port: destination.port,
                        policy: route.policy,
                        status: "Connected",
                        rule: route.rule,
                        note: connectedNote
                    )
                )

                if request.method.uppercased() == "CONNECT" {
                    try sendAll(request.connectHeaderForHTTPProxy(destination: destination, upstream: upstream), to: remoteFD)
                } else {
                    try sendAll(request.forwardHeaderForHTTPProxy(upstream: upstream).data(using: .utf8)! + header.extraData, to: remoteFD)
                }

                let summary = await tunnel(clientFD, remoteFD)
                await appendTunnelSummary(summary, request: request, destination: destination, route: route, note: connectedNote, to: logStore)
                return

            case .socks5Proxy(let upstream):
                guard let upstreamPort = upstream.port else {
                    throw ProxyServerError.invalidDestination
                }
                let remoteFD = try connect(host: upstream.host, port: upstreamPort)
                try connectViaSOCKS5(remoteFD, destination: destination, upstream: upstream)
                let connectedNote = route.note + "; SOCKS5 upstream \(upstream.endpoint)"
                await logStore.append(
                    ProxyServerEvent(
                        method: request.method,
                        target: request.target,
                        host: destination.host,
                        port: destination.port,
                        policy: route.policy,
                        status: "Connected",
                        rule: route.rule,
                        note: connectedNote
                    )
                )

                if request.method.uppercased() == "CONNECT" {
                    try sendAll("HTTP/1.1 200 Connection Established\r\nProxy-Agent: ProxyWorkbench\r\n\r\n", to: clientFD)
                } else if let initialPayload {
                    try sendAll(initialPayload, to: remoteFD)
                }

                let summary = await tunnel(clientFD, remoteFD)
                await appendTunnelSummary(summary, request: request, destination: destination, route: route, note: connectedNote, to: logStore)
                return

            case .trojanProxy(let upstream):
                let connection = try await TrojanUpstreamConnection.connect(upstream: upstream, destinationHost: destination.host, destinationPort: destination.port)
                let connectedNote = route.note + "; Trojan upstream \(upstream.endpoint)"
                await logStore.append(
                    ProxyServerEvent(
                        method: request.method,
                        target: request.target,
                        host: destination.host,
                        port: destination.port,
                        policy: route.policy,
                        status: "Connected",
                        rule: route.rule,
                        note: connectedNote
                    )
                )

                if request.method.uppercased() == "CONNECT" {
                    try sendAll("HTTP/1.1 200 Connection Established\r\nProxy-Agent: ProxyWorkbench\r\n\r\n", to: clientFD)
                } else if let initialPayload {
                    try await connection.send(initialPayload)
                }

                let summary = await TrojanUpstreamConnection.tunnel(clientFD: clientFD, upstream: connection)
                await appendTunnelSummary(summary, request: request, destination: destination, route: route, note: connectedNote, to: logStore)
                return
            }
        } catch {
            await logStore.append(failureContext.failedEvent(error: error))
            _ = try? sendAll("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\nContent-Length: 0\r\n\r\n", to: clientFD)
            close(clientFD)
        }
    }

    private static func appendTunnelSummary(
        _ summary: ProxyTunnelSummary,
        request: HTTPProxyRequest,
        destination: Destination,
        route: ProxyRouteDecision,
        note: String,
        to logStore: ProxyEventStore
    ) async {
        guard summary.status == "Failed" else { return }
        await logStore.append(
            ProxyServerEvent(
                method: request.method,
                target: request.target,
                host: destination.host,
                port: destination.port,
                policy: route.policy,
                status: summary.status,
                rule: route.rule,
                note: "\(note); \(summary.note)"
            )
        )
    }

    private static func routeDecision(for input: String, profile: ProxyProfile, groupSelections: [String: String]) -> ProxyRouteDecision {
        if let bypass = GeneralBypassMatcher(profile: profile).firstMatch(for: input) {
            return ProxyRouteDecision(policy: "DIRECT", action: .direct, rule: "General \(bypass.sourceKey): \(bypass.entry)", note: "General \(bypass.sourceKey): \(bypass.reason) \(bypass.entry)")
        }

        guard let match = RuleEngine(rules: profile.rules).firstMatch(for: input) else {
            return ProxyRouteDecision(policy: "DIRECT", action: .direct, rule: "No rule matched", note: "No rule matched")
        }

        let resolution = resolve(policy: match.rule.policy, in: profile, groupSelections: groupSelections, visited: [])
        let policyPath = resolution.path.joined(separator: " -> ")
        let note = "\(match.reason): \(match.rule.displayCondition); policy path: \(policyPath)"

        return ProxyRouteDecision(policy: policyPath, action: resolution.action, rule: match.rule.displayCondition, note: note)
    }

    private static func resolve(policy: String, in profile: ProxyProfile, groupSelections: [String: String], visited: Set<String>) -> PolicyResolution {
        let normalized = policy.uppercased()
        if normalized.hasPrefix("REJECT") {
            return PolicyResolution(action: .reject, path: [policy])
        }

        if normalized == "DIRECT" {
            return PolicyResolution(action: .direct, path: [policy])
        }

        guard !visited.contains(policy) else {
            return PolicyResolution(action: .unsupported, path: [policy, "cycle"])
        }

        if let group = profile.groups.first(where: { $0.name == policy }) {
            let selected = groupSelections[policy].flatMap { group.policies.contains($0) ? $0 : nil } ?? group.policies.first
            guard let selected else {
                return PolicyResolution(action: .unsupported, path: [policy, "empty group"])
            }
            let next = resolve(policy: selected, in: profile, groupSelections: groupSelections, visited: visited.union([policy]))
            return PolicyResolution(action: next.action, path: [policy] + next.path)
        }

        if let node = profile.proxies.first(where: { $0.name == policy }) {
            switch node.kind {
            case .direct:
                return PolicyResolution(action: .direct, path: [policy])
            case .reject:
                return PolicyResolution(action: .reject, path: [policy])
            case .http:
                return PolicyResolution(action: .httpProxy(node), path: [policy])
            case .socks5:
                return PolicyResolution(action: .socks5Proxy(node), path: [policy])
            case .trojan:
                return PolicyResolution(action: .trojanProxy(node), path: [policy])
            default:
                return PolicyResolution(action: .unsupported, path: [policy, "\(node.kind.displayName) upstream unsupported"])
            }
        }

        return PolicyResolution(action: .unsupported, path: [policy, "unknown policy"])
    }

    private static func readHeader(from fd: Int32) throws -> HeaderRead {
        var data = Data()
        let terminator = Data([13, 10, 13, 10])
        var buffer = [UInt8](repeating: 0, count: 4096)

        while data.count < 64 * 1024 {
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else {
                throw ProxyServerError.connectionClosed
            }
            data.append(buffer, count: count)
            if let range = data.range(of: terminator) {
                let headerData = data[..<range.upperBound]
                let extra = data[range.upperBound...]
                guard let headerText = String(data: headerData, encoding: .isoLatin1) else {
                    throw ProxyServerError.invalidRequest
                }
                return HeaderRead(headerText: headerText, extraData: Data(extra))
            }
        }

        throw ProxyServerError.headerTooLarge
    }

    private static func connect(host: String, port: Int) throws -> Int32 {
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

    private static func connectViaSOCKS5(_ fd: Int32, destination: Destination, upstream: ProxyNode) throws {
        let hasCredentials = (upstream.username?.isEmpty == false) || (upstream.password?.isEmpty == false)
        let methods: [UInt8] = hasCredentials ? [0x00, 0x02] : [0x00]
        try sendAll(Data([0x05, UInt8(methods.count)] + methods), to: fd)

        let choice = try recvExact(2, from: fd)
        guard choice[0] == 0x05 else {
            throw ProxyServerError.socks5("Invalid greeting response")
        }
        switch choice[1] {
        case 0x00:
            break
        case 0x02:
            try authenticateSOCKS5(fd, upstream: upstream)
        case 0xFF:
            throw ProxyServerError.socks5("SOCKS5 server rejected authentication methods")
        default:
            throw ProxyServerError.socks5("Unsupported authentication method \(choice[1])")
        }

        var request = Data([0x05, 0x01, 0x00])
        request.append(try socks5AddressBytes(host: destination.host))
        var networkPort = UInt16(destination.port).bigEndian
        withUnsafeBytes(of: &networkPort) { request.append(contentsOf: $0) }
        try sendAll(request, to: fd)

        let head = try recvExact(4, from: fd)
        guard head[0] == 0x05 else {
            throw ProxyServerError.socks5("Invalid connect response")
        }
        guard head[1] == 0x00 else {
            throw ProxyServerError.socks5("Connect failed with status \(head[1])")
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
            throw ProxyServerError.socks5("Invalid bound address type")
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
            throw ProxyServerError.socks5("SOCKS5 destination host is too long")
        }
        var result = Data([0x03, UInt8(hostData.count)])
        result.append(hostData)
        return result
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
}

private struct HeaderRead: Sendable {
    var headerText: String
    var extraData: Data
}

private struct Destination: Sendable {
    var host: String
    var port: Int

    init(authority: String, defaultPort: Int) throws {
        let trimmed = authority.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("["),
           let end = trimmed.firstIndex(of: "]") {
            host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<end])
            let tail = trimmed[trimmed.index(after: end)...]
            port = tail.hasPrefix(":") ? Int(tail.dropFirst()) ?? defaultPort : defaultPort
            return
        }

        if let colon = trimmed.lastIndex(of: ":"),
           let parsedPort = Int(trimmed[trimmed.index(after: colon)...]) {
            host = String(trimmed[..<colon])
            port = parsedPort
        } else {
            host = trimmed
            port = defaultPort
        }

        if host.isEmpty || !(1...65535).contains(port) {
            throw ProxyServerError.invalidDestination
        }
    }
}

private struct HTTPProxyRequest: Sendable {
    var method: String
    var target: String
    var version: String
    var headers: [(String, String)]

    init(headerText: String) throws {
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw ProxyServerError.invalidRequest
        }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3 else {
            throw ProxyServerError.invalidRequest
        }

        method = parts[0]
        target = parts[1]
        version = parts[2]
        headers = lines.dropFirst().compactMap { line in
            guard !line.isEmpty, let colon = line.firstIndex(of: ":") else { return nil }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return (name, value)
        }
    }

    func destinationForPlainHTTP() throws -> Destination {
        if target.lowercased().hasPrefix("http://") {
            guard let components = URLComponents(string: target),
                  let host = components.host else {
                throw ProxyServerError.invalidDestination
            }
            return try Destination(authority: "\(host):\(components.port ?? 80)", defaultPort: 80)
        }

        if target.lowercased().hasPrefix("https://") {
            throw ProxyServerError.invalidRequest
        }

        guard let hostHeader = headerValue("host") else {
            throw ProxyServerError.invalidDestination
        }
        return try Destination(authority: hostHeader, defaultPort: 80)
    }

    func rewrittenHeader(for destination: Destination) -> String {
        let path = originPath()
        var lines = ["\(method) \(path) \(version)"]
        var hasHost = false

        for (name, value) in headers {
            let lower = name.lowercased()
            if lower == "proxy-connection" || lower == "connection" {
                continue
            }
            if lower == "host" {
                hasHost = true
            }
            lines.append("\(name): \(value)")
        }

        if !hasHost {
            lines.append("Host: \(destination.host)")
        }
        lines.append("Connection: close")
        return lines.joined(separator: "\r\n") + "\r\n\r\n"
    }

    func forwardHeaderForHTTPProxy(upstream: ProxyNode) -> String {
        var lines = ["\(method) \(target) \(version)"]
        appendForwardedHeaders(to: &lines, upstream: upstream)
        return lines.joined(separator: "\r\n") + "\r\n\r\n"
    }

    func connectHeaderForHTTPProxy(destination: Destination, upstream: ProxyNode) -> String {
        var lines = ["CONNECT \(destination.host):\(destination.port) \(version)"]
        lines.append("Host: \(destination.host):\(destination.port)")
        if let authorization = proxyAuthorizationHeader(upstream: upstream) {
            lines.append(authorization)
        }
        lines.append("Connection: close")
        return lines.joined(separator: "\r\n") + "\r\n\r\n"
    }

    private func appendForwardedHeaders(to lines: inout [String], upstream: ProxyNode) {
        var hasHost = false
        var hasAuthorization = false

        for (name, value) in headers {
            let lower = name.lowercased()
            if lower == "proxy-connection" || lower == "connection" {
                continue
            }
            if lower == "host" {
                hasHost = true
            }
            if lower == "proxy-authorization" {
                hasAuthorization = true
            }
            lines.append("\(name): \(value)")
        }

        if !hasHost {
            lines.append("Host: \(target)")
        }
        if !hasAuthorization, let authorization = proxyAuthorizationHeader(upstream: upstream) {
            lines.append(authorization)
        }
        lines.append("Connection: close")
    }

    private func proxyAuthorizationHeader(upstream: ProxyNode) -> String? {
        guard let username = upstream.username, !username.isEmpty else {
            return nil
        }
        let password = upstream.password ?? ""
        let credentials = Data("\(username):\(password)".utf8).base64EncodedString()
        return "Proxy-Authorization: Basic \(credentials)"
    }

    private func headerValue(_ name: String) -> String? {
        headers.first { $0.0.lowercased() == name.lowercased() }?.1
    }

    private func originPath() -> String {
        guard target.lowercased().hasPrefix("http://"),
              let components = URLComponents(string: target) else {
            return target.isEmpty ? "/" : target
        }

        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery, !query.isEmpty {
            return "\(path)?\(query)"
        }
        return path
    }

    func routeInput(destination: Destination) -> String {
        if target.lowercased().hasPrefix("http://") || target.lowercased().hasPrefix("https://") {
            return target
        }
        return "\(destination.host):\(destination.port)"
    }
}

private enum ProxyRouteAction: Sendable {
    case direct
    case reject
    case unsupported
    case httpProxy(ProxyNode)
    case socks5Proxy(ProxyNode)
    case trojanProxy(ProxyNode)
}

private struct ProxyRouteDecision: Sendable {
    var policy: String
    var action: ProxyRouteAction
    var rule: String
    var note: String
}

private struct PolicyResolution: Sendable {
    var action: ProxyRouteAction
    var path: [String]
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
