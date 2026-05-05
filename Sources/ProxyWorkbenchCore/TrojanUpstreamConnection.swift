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
        try await connect(upstream: upstream, destination: .domainName(host: destinationHost, port: destinationPort))
    }

    static func connect(upstream: ProxyNode, destination: TrojanProtocol.Address) async throws -> TrojanUpstreamConnection {
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

        let tlsOptions = tlsOptions(for: upstream)
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.noDelay = true
        let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        parameters.preferNoProxies = true
        let queue = DispatchQueue(label: "blaze.Trojan.\(UUID().uuidString)")
        let connection = NWConnection(host: NWEndpoint.Host(upstream.host), port: port, using: parameters)
        let requestHeader = try TrojanProtocol.requestHeader(password: password, address: destination)
        let upstreamConnection = TrojanUpstreamConnection(connection: connection, queue: queue, requestHeader: requestHeader)

        try await upstreamConnection.start(timeout: .seconds(12))
        upstreamConnection.scheduleDeferredHeaderFlush()
        return upstreamConnection
    }

    private static func tlsOptions(for upstream: ProxyNode) -> NWProtocolTLS.Options {
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
        return tlsOptions
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
    enum Command: UInt8, Sendable, Equatable {
        case connect = 0x01
        case udpAssociate = 0x03
    }

    enum Address: Sendable, Equatable {
        case ipv4([UInt8], port: Int)
        case domainName(host: String, port: Int)
        case ipv6([UInt8], port: Int)

        var host: String {
            switch self {
            case .ipv4(let octets, _):
                guard octets.count == 4 else { return "" }
                return octets.map(String.init).joined(separator: ".")
            case .domainName(let host, _):
                return host
            case .ipv6(let bytes, _):
                guard bytes.count == 16 else { return "" }
                var storage = bytes
                var string = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                storage.withUnsafeMutableBytes { rawBuffer in
                    _ = inet_ntop(AF_INET6, rawBuffer.baseAddress, &string, socklen_t(INET6_ADDRSTRLEN))
                }
                let end = string.firstIndex(of: 0) ?? string.endIndex
                return String(decoding: string[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }

        var port: Int {
            switch self {
            case .ipv4(_, let port), .domainName(_, let port), .ipv6(_, let port):
                port
            }
        }

        var encodedBytes: Data {
            get throws {
                guard (1...65535).contains(port) else {
                    throw ProxyServerError.invalidDestination
                }

                var result = Data()
                switch self {
                case .ipv4(let octets, let port):
                    guard octets.count == 4 else {
                        throw ProxyServerError.invalidDestination
                    }
                    result.append(0x01)
                    result.append(contentsOf: octets)
                    result.appendPort(port)
                case .domainName(let host, let port):
                    let hostData = Data(host.utf8)
                    guard !hostData.isEmpty, hostData.count <= 255 else {
                        throw ProxyServerError.trojan("Trojan destination host is too long")
                    }
                    result.append(0x03)
                    result.append(UInt8(hostData.count))
                    result.append(hostData)
                    result.appendPort(port)
                case .ipv6(let bytes, let port):
                    guard bytes.count == 16 else {
                        throw ProxyServerError.invalidDestination
                    }
                    result.append(0x04)
                    result.append(contentsOf: bytes)
                    result.appendPort(port)
                }
                return result
            }
        }
    }

    struct Request: Sendable, Equatable {
        var passwordHash: String
        var command: Command
        var address: Address
        var payload: Data
    }

    static func requestHeader(password: String, host: String, port: Int) throws -> Data {
        try requestHeader(password: password, address: .domainName(host: host, port: port))
    }

    static func requestHeader(password: String, address: Address, command: Command = .connect) throws -> Data {
        guard !password.isEmpty else {
            throw ProxyServerError.trojan("Trojan password is missing")
        }

        var result = Data(sha224Hex(password).utf8)
        result.appendCRLF()
        result.append(command.rawValue)
        result.append(try address.encodedBytes)
        result.appendCRLF()
        return result
    }

    static func parseRequest(_ data: Data) throws -> Request {
        let bytes = Array(data)
        guard let passwordEnd = bytes.indices.dropLast().first(where: { bytes[$0] == 13 && bytes[$0 + 1] == 10 }) else {
            throw ProxyServerError.trojan("Trojan request is missing password delimiter")
        }

        let passwordHash = String(decoding: bytes[..<passwordEnd], as: UTF8.self)
        var offset = passwordEnd + 2
        guard offset < bytes.count, let command = Command(rawValue: bytes[offset]) else {
            throw ProxyServerError.trojan("Trojan request command is unsupported")
        }
        offset += 1

        let parsedAddress = try parseAddress(bytes, offset: offset)
        offset = parsedAddress.nextOffset
        guard bytes.count >= offset + 2, bytes[offset] == 13, bytes[offset + 1] == 10 else {
            throw ProxyServerError.trojan("Trojan request is missing payload delimiter")
        }

        let payloadStart = offset + 2
        let payload = payloadStart < bytes.count ? Data(bytes[payloadStart...]) : Data()
        return Request(passwordHash: passwordHash, command: command, address: parsedAddress.address, payload: payload)
    }

    private static func parseAddress(_ bytes: [UInt8], offset: Int) throws -> (address: Address, nextOffset: Int) {
        guard offset < bytes.count else {
            throw ProxyServerError.invalidDestination
        }

        switch bytes[offset] {
        case 0x01:
            let end = offset + 1 + 4 + 2
            guard bytes.count >= end else {
                throw ProxyServerError.invalidDestination
            }
            let portIndex = offset + 5
            let port = Int(UInt16(bytes[portIndex]) << 8 | UInt16(bytes[portIndex + 1]))
            return (.ipv4(Array(bytes[(offset + 1)..<(offset + 5)]), port: port), end)
        case 0x03:
            guard bytes.count >= offset + 2 else {
                throw ProxyServerError.invalidDestination
            }
            let length = Int(bytes[offset + 1])
            guard length > 0 else {
                throw ProxyServerError.invalidDestination
            }
            let hostStart = offset + 2
            let portIndex = hostStart + length
            guard bytes.count >= portIndex + 2 else {
                throw ProxyServerError.invalidDestination
            }
            let host = String(decoding: bytes[hostStart..<portIndex], as: UTF8.self)
            let port = Int(UInt16(bytes[portIndex]) << 8 | UInt16(bytes[portIndex + 1]))
            return (.domainName(host: host, port: port), portIndex + 2)
        case 0x04:
            let end = offset + 1 + 16 + 2
            guard bytes.count >= end else {
                throw ProxyServerError.invalidDestination
            }
            let portIndex = offset + 17
            let port = Int(UInt16(bytes[portIndex]) << 8 | UInt16(bytes[portIndex + 1]))
            return (.ipv6(Array(bytes[(offset + 1)..<(offset + 17)]), port: port), end)
        default:
            throw ProxyServerError.invalidDestination
        }
    }

    private static func sha224Hex(_ value: String) -> String {
        let data = Data(value.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA224_DIGEST_LENGTH))
        data.withUnsafeBytes { rawBuffer in
            _ = CC_SHA224(rawBuffer.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private extension Data {
    mutating func appendCRLF() {
        append(contentsOf: [13, 10])
    }

    mutating func appendPort(_ port: Int) {
        append(UInt8((port >> 8) & 0xFF))
        append(UInt8(port & 0xFF))
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
