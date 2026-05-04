import CommonCrypto
import Darwin
import Foundation
import Network
import Security

final class TrojanUpstreamConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue

    private init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
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

        if upstream.parameters["skip-cert-verify"].isTruthy || upstream.parameters["allow-insecure"].isTruthy {
            sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions, { _, _, complete in
                complete(true)
            }, DispatchQueue(label: "ProxyWorkbench.TrojanTLSVerify.\(UUID().uuidString)"))
        }

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        parameters.preferNoProxies = true
        let queue = DispatchQueue(label: "ProxyWorkbench.Trojan.\(UUID().uuidString)")
        let connection = NWConnection(host: NWEndpoint.Host(upstream.host), port: port, using: parameters)
        let upstreamConnection = TrojanUpstreamConnection(connection: connection, queue: queue)

        try await upstreamConnection.start(timeout: .seconds(12))
        try await upstreamConnection.send(TrojanProtocol.requestHeader(password: password, host: destinationHost, port: destinationPort))
        return upstreamConnection
    }

    func send(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: ProxyServerError.trojan(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
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
            throw ProxyServerError.trojan("TLS connection timed out")
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

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
