import CommonCrypto
import Darwin
import Foundation
import Network
import Security

final class TrojanUpstreamConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let sendQueue: DispatchQueue
    private let requestHeader: Data
    private let headerLock = NSLock()
    private var didSendRequestHeader = false

    private init(connection: NWConnection, queue: DispatchQueue, requestHeader: Data) {
        self.connection = connection
        self.queue = queue
        self.sendQueue = DispatchQueue(label: "blaze.TrojanSend.\(UUID().uuidString)")
        self.requestHeader = requestHeader
    }

    static func connect(upstream: ProxyNode, destinationHost: String, destinationPort: Int) async throws -> TrojanUpstreamConnection {
        guard upstream.kind == .trojan else {
            throw ProxyServerError.trojan("Policy is not a Trojan node")
        }
        guard let upstreamPort = upstream.port else {
            throw ProxyServerError.invalidDestination
        }
        guard let port = NWEndpoint.Port(rawValue: UInt16(upstreamPort)) else {
            throw ProxyServerError.invalidDestination
        }
        guard let password = upstream.password, !password.isEmpty else {
            throw ProxyServerError.trojan("Trojan password is missing")
        }

        let tlsOptions = NWProtocolTLS.Options()
        let serverName = upstream.parameters["sni"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? upstream.parameters["server-name"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? upstream.host
        sec_protocol_options_set_tls_server_name(tlsOptions.securityProtocolOptions, serverName)
        for protocolName in upstream.tlsApplicationProtocols {
            sec_protocol_options_add_tls_application_protocol(tlsOptions.securityProtocolOptions, protocolName)
        }

        if upstream.parameters["skip-cert-verify"].isTruthy || upstream.parameters["allow-insecure"].isTruthy {
            sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions, { _, _, complete in
                complete(true)
            }, DispatchQueue(label: "blaze.TrojanTLSVerify.\(UUID().uuidString)"))
        }

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.noDelay = true
        let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        parameters.preferNoProxies = true
        let queue = DispatchQueue(label: "blaze.Trojan.\(UUID().uuidString)")
        let connection = NWConnection(host: NWEndpoint.Host(upstream.host), port: port, using: parameters)
        let requestHeader = try TrojanProtocol.requestHeader(password: password, host: destinationHost, port: destinationPort)
        let upstreamConnection = TrojanUpstreamConnection(connection: connection, queue: queue, requestHeader: requestHeader)

        try await upstreamConnection.start(timeout: .seconds(12))
        upstreamConnection.scheduleDeferredHeaderFlush()
        return upstreamConnection
    }

    func send(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        try await enqueueWrite(payload: data)
    }

    func flushHeaderIfNeeded() async throws {
        try await enqueueWrite(payload: nil)
    }

    private func scheduleDeferredHeaderFlush() {
        Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            try? await self?.flushHeaderIfNeeded()
        }
    }

    private func enqueueWrite(payload: Data?) async throws {
        let payload = payload ?? Data()
        let outboundData: Data? = headerLock.withLock { () -> Data? in
            let header: Data?
            if didSendRequestHeader {
                header = nil
            } else {
                didSendRequestHeader = true
                header = requestHeader
            }

            guard header != nil || !payload.isEmpty else { return nil }

            var data = Data()
            data.reserveCapacity((header?.count ?? 0) + payload.count)
            if let header {
                data.append(header)
            }
            data.append(payload)
            return data
        }

        guard let outboundData else { return }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sendQueue.async { [connection, outboundData] in
                connection.send(content: outboundData, completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: ProxyServerError.trojan(error.localizedDescription))
                    } else {
                        continuation.resume()
                    }
                })
            }
        }
    }

    func receive(maximumLength: Int = 16 * 1024) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: ProxyServerError.trojan(error.localizedDescription))
                    return
                }
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                    return
                }
                if isComplete {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: nil)
            }
        }
    }

    func cancel() {
        connection.cancel()
    }

    static func tunnel(clientFD: Int32, upstream: TrojanUpstreamConnection) async -> ProxyTunnelSummary {
        let clientToUpstream = Task.detached(priority: .utility) {
            let result = await relay(fromClientFD: clientFD, to: upstream)
            upstream.cancel()
            return result
        }
        let upstreamToClient = Task.detached(priority: .utility) {
            let result = await relay(from: upstream, toClientFD: clientFD)
            shutdown(clientFD, SHUT_WR)
            return result
        }

        let download = await upstreamToClient.value
        shutdown(clientFD, SHUT_RDWR)
        upstream.cancel()
        let upload = await clientToUpstream.value
        close(clientFD)
        return ProxyTunnelSummary(uploadBytes: upload.bytes, downloadBytes: download.bytes, uploadError: upload.error, downloadError: download.error)
    }

    private func start(timeout: DispatchTimeInterval) async throws {
        let state = ConnectionStartState()
        connection.stateUpdateHandler = { nwState in
            switch nwState {
            case .ready:
                state.complete(.success(()))
            case .failed(let error):
                state.complete(.failure(ProxyServerError.trojan(error.localizedDescription)))
            case .cancelled:
                state.complete(.failure(ProxyServerError.connectionClosed))
            default:
                break
            }
        }
        connection.start(queue: queue)

        guard state.wait(timeout: timeout) else {
            connection.cancel()
            let diagnostic = UpstreamDNSDiagnostic.fakeIPMessage(for: connection.endpointHost)
            throw ProxyServerError.trojan(["TLS connection timed out", diagnostic].compactMap(\.self).joined(separator: "; "))
        }
        try state.result.get()
    }

    private static func relay(fromClientFD fd: Int32, to upstream: TrojanUpstreamConnection) async -> ProxyRelayResult {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var bytes = 0
        while true {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count == 0 {
                return ProxyRelayResult(bytes: bytes, error: nil)
            }
            if count < 0 {
                return ProxyRelayResult(bytes: bytes, error: ProxySocketErrorDescription.posix("recv", errno))
            }
            do {
                try await upstream.send(Data(buffer.prefix(count)))
                bytes += count
            } catch {
                return ProxyRelayResult(bytes: bytes, error: String(describing: error))
            }
        }
    }

    private static func relay(from upstream: TrojanUpstreamConnection, toClientFD fd: Int32) async -> ProxyRelayResult {
        var bytes = 0
        while true {
            do {
                guard let data = try await upstream.receive(), !data.isEmpty else {
                    return ProxyRelayResult(bytes: bytes, error: nil)
                }
                try sendAll(data, to: fd)
                bytes += data.count
            } catch {
                return ProxyRelayResult(bytes: bytes, error: String(describing: error))
            }
        }
    }

    private static func sendAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let count = Darwin.send(fd, baseAddress.advanced(by: sent), data.count - sent, 0)
                guard count > 0 else {
                    throw ProxyServerError.posix("send", errno)
                }
                sent += count
            }
        }
    }
}

enum TrojanProtocol {
    static func requestHeader(password: String, host: String, port: Int) throws -> Data {
        guard !password.isEmpty else {
            throw ProxyServerError.trojan("Trojan password is missing")
        }
        guard !host.isEmpty, (1...65535).contains(port) else {
            throw ProxyServerError.invalidDestination
        }

        var result = Data(sha224Hex(password).utf8)
        result.append(contentsOf: [13, 10, 0x01])
        result.append(try addressBytes(host: host))
        var networkPort = UInt16(port).bigEndian
        withUnsafeBytes(of: &networkPort) { result.append(contentsOf: $0) }
        result.append(contentsOf: [13, 10])
        return result
    }

    private static func sha224Hex(_ value: String) -> String {
        let data = Data(value.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA224_DIGEST_LENGTH))
        data.withUnsafeBytes { rawBuffer in
            _ = CC_SHA224(rawBuffer.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func addressBytes(host: String) throws -> Data {
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
            throw ProxyServerError.trojan("Trojan destination host is too long")
        }
        var result = Data([0x03, UInt8(hostData.count)])
        result.append(hostData)
        return result
    }
}

private final class ConnectionStartState: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var storedResult: Result<Void, Error>?

    var result: Result<Void, Error> {
        lock.lock()
        defer { lock.unlock() }
        return storedResult ?? .failure(ProxyServerError.connectionClosed)
    }

    func complete(_ result: Result<Void, Error>) {
        lock.lock()
        guard storedResult == nil else {
            lock.unlock()
            return
        }
        storedResult = result
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeout: DispatchTimeInterval) -> Bool {
        semaphore.wait(timeout: .now() + timeout) == .success
    }
}

private extension Optional where Wrapped == String {
    var isTruthy: Bool {
        guard let self else { return false }
        switch self.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }
}

private extension ProxyNode {
    var tlsApplicationProtocols: [String] {
        let rawValue = parameters["alpn"] ?? parameters["tls-alpn"]
        let parsed = rawValue?
            .split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        return parsed.isEmpty ? ["h2", "http/1.1"] : parsed
    }
}

private extension NWConnection {
    var endpointHost: String {
        switch endpoint {
        case .hostPort(let host, _):
            return "\(host)"
        default:
            return ""
        }
    }
}

private enum UpstreamDNSDiagnostic {
    static func fakeIPMessage(for host: String) -> String? {
        guard !host.isEmpty, let addresses = resolvedIPv4Addresses(for: host), !addresses.isEmpty else {
            return nil
        }
        guard addresses.allSatisfy(isFakeIP) else {
            return nil
        }
        return "local DNS resolved upstream to 198.18.0.0/15 fake-IP; another proxy Network Extension may still be active"
    }

    private static func resolvedIPv4Addresses(for host: String) -> [UInt32]? {
        var hints = addrinfo(
            ai_flags: AI_NUMERICSERV,
            ai_family: AF_INET,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var info: UnsafeMutablePointer<addrinfo>?
        let lookup = getaddrinfo(host, "443", &hints, &info)
        guard lookup == 0, let first = info else {
            return nil
        }
        defer { freeaddrinfo(first) }

        var result: [UInt32] = []
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let address = current {
            if let socketAddress = address.pointee.ai_addr?.withMemoryRebound(to: sockaddr_in.self, capacity: 1, { $0.pointee }) {
                result.append(UInt32(bigEndian: socketAddress.sin_addr.s_addr))
            }
            current = address.pointee.ai_next
        }
        return result
    }

    private static func isFakeIP(_ address: UInt32) -> Bool {
        (address & 0xFFFE_0000) == 0xC612_0000
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
