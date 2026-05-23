import Darwin
import Foundation
import Network
import Security
import os.log

// Diagnostics for "is the system DNS returning fake-IP for an upstream proxy
// host, and if so what's the real address?" Required to compute packet-tunnel
// bypass routes — without it, traffic to the upstream Trojan server can loop
// back into the tunnel and deadlock the connection.

public struct ProxyUpstreamResolutionDiagnostic: Hashable, Sendable {
    public var host: String
    public var systemIPv4Addresses: [String]
    public var fakeIPDetected: Bool
    public var bypassIPv4Address: String?

    public var canConnectWithoutFakeIP: Bool {
        !fakeIPDetected || bypassIPv4Address != nil
    }
}

public enum ProxyUpstreamResolutionDiagnostics {
    public static func evaluate(host: String) async -> ProxyUpstreamResolutionDiagnostic {
        let systemAddresses = UpstreamHostDNS.resolvedIPv4Addresses(for: host) ?? []
        let fakeIPDetected = !systemAddresses.isEmpty && systemAddresses.allSatisfy(UpstreamHostDNS.isFakeIP)
        let bypassAddress = fakeIPDetected ? await DNSOverHTTPSJSONResolver.resolveA(host).first : nil
        return ProxyUpstreamResolutionDiagnostic(
            host: host,
            systemIPv4Addresses: systemAddresses.map(UpstreamHostDNS.ipv4String),
            fakeIPDetected: fakeIPDetected,
            bypassIPv4Address: bypassAddress
        )
    }
}

// MARK: - System DNS helper

private enum UpstreamHostDNS {
    static func resolvedIPv4Addresses(for host: String) -> [UInt32]? {
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

    static func isFakeIP(_ address: UInt32) -> Bool {
        (address & 0xFFFE_0000) == 0xC612_0000
    }

    static func ipv4String(_ address: UInt32) -> String {
        var networkAddress = in_addr(s_addr: address.bigEndian)
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &networkAddress, &buffer, socklen_t(INET_ADDRSTRLEN))
        let endIndex = buffer.firstIndex(of: 0) ?? buffer.endIndex
        return String(decoding: buffer[..<endIndex].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

// MARK: - DNS-over-HTTPS resolver (fallback when system DNS returns fake-IP)

private enum DNSOverHTTPSJSONResolver {
    private struct Provider: Sendable {
        var name: String
        var host: String
        var address: String
        var path: String
    }

    private static let providers = [
        Provider(name: "AliDNS", host: "dns.alidns.com", address: "223.5.5.5", path: "/resolve"),
        Provider(name: "Cloudflare", host: "cloudflare-dns.com", address: "1.1.1.1", path: "/dns-query"),
        Provider(name: "Google", host: "dns.google", address: "8.8.8.8", path: "/resolve")
    ]

    static func resolveA(_ host: String) async -> [String] {
        for provider in providers {
            do {
                let addresses = try await withTimeout(seconds: 5) {
                    try await query(host, provider: provider)
                }
                let usable = addresses.filter { !$0.isEmpty && !$0.isFakeIPv4Literal }
                if !usable.isEmpty {
                    return usable
                }
            } catch {
                continue
            }
        }
        return []
    }

    private static func query(_ host: String, provider: Provider) async throws -> [String] {
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tlsOptions.securityProtocolOptions, provider.host)
        sec_protocol_options_add_tls_application_protocol(tlsOptions.securityProtocolOptions, "http/1.1")

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        parameters.preferNoProxies = true
        if let preferredInterface = await PhysicalInterfacePreference.shared.current() {
            parameters.requiredInterface = preferredInterface.interface
        }
        parameters.prohibitedInterfaceTypes = [.loopback, .other]
        parameters.allowFastOpen = false

        guard let port = NWEndpoint.Port(rawValue: 443) else {
            throw ProxyServerError.invalidDestination
        }

        let queue = DispatchQueue(label: "blaze.DoH.\(provider.name).\(UUID().uuidString)")
        let connection = NWConnection(host: NWEndpoint.Host(provider.address), port: port, using: parameters)
        defer { connection.cancel() }

        try start(connection, queue: queue)
        let encodedName = host.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? host
        let request = """
        GET \(provider.path)?name=\(encodedName)&type=A HTTP/1.1\r
        Host: \(provider.host)\r
        Accept: application/dns-json\r
        Connection: close\r
        User-Agent: blaze-doh\r
        \r

        """
        try await send(Data(request.utf8), to: connection)
        let response = try await receiveAll(from: connection)
        let body = try responseBody(from: response)
        return try parseAddresses(from: body)
    }

    private static func start(_ connection: NWConnection, queue: DispatchQueue) throws {
        let state = ConnectionStartState()
        connection.stateUpdateHandler = { nwState in
            switch nwState {
            case .ready:
                state.complete(.success(()))
            case .failed(let error):
                state.complete(.failure(ProxyServerError.lookup(error.localizedDescription)))
            case .cancelled:
                state.complete(.failure(ProxyServerError.connectionClosed))
            default:
                break
            }
        }
        connection.start(queue: queue)
        guard state.wait(timeout: .seconds(4)) else {
            connection.cancel()
            throw ProxyServerError.lookup("DoH connection timed out")
        }
        try state.result.get()
    }

    private static func send(_ data: Data, to connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: ProxyServerError.lookup(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private static func receiveAll(from connection: NWConnection) async throws -> Data {
        var response = Data()
        while response.count < 256 * 1024 {
            let chunk = try await receiveChunk(from: connection)
            if let data = chunk.data, !data.isEmpty {
                response.append(data)
            }
            if chunk.isComplete {
                return response
            }
            if chunk.data?.isEmpty != false {
                try await Task.sleep(nanoseconds: 25_000_000)
            }
        }
        throw ProxyServerError.lookup("DoH response exceeded 256 KiB")
    }

    private static func receiveChunk(from connection: NWConnection) async throws -> (data: Data?, isComplete: Bool) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: ProxyServerError.lookup(error.localizedDescription))
                } else {
                    continuation.resume(returning: (data, isComplete))
                }
            }
        }
    }

    private static func responseBody(from response: Data) throws -> Data {
        let separator = Data([13, 10, 13, 10])
        guard let headerEnd = response.range(of: separator) else {
            throw ProxyServerError.lookup("DoH response missing HTTP headers")
        }
        let headerData = response[..<headerEnd.lowerBound]
        guard let headerText = String(data: headerData, encoding: .isoLatin1),
              headerText.hasPrefix("HTTP/1.1 200") || headerText.hasPrefix("HTTP/1.0 200") else {
            throw ProxyServerError.lookup("DoH returned a non-200 response")
        }
        let body = Data(response[headerEnd.upperBound...])
        if headerText.lowercased().contains("transfer-encoding: chunked") {
            return try decodeChunkedBody(body)
        }
        return body
    }

    private static func decodeChunkedBody(_ data: Data) throws -> Data {
        var index = data.startIndex
        var decoded = Data()
        while index < data.endIndex {
            guard let lineEnd = data[index...].range(of: Data([13, 10])) else {
                throw ProxyServerError.lookup("Invalid chunked DoH response")
            }
            let sizeData = data[index..<lineEnd.lowerBound]
            let sizeText = String(data: sizeData, encoding: .ascii)?
                .split(separator: ";", maxSplits: 1)
                .first
                .map(String.init) ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespacesAndNewlines), radix: 16) else {
                throw ProxyServerError.lookup("Invalid DoH chunk size")
            }
            index = lineEnd.upperBound
            guard size > 0 else { return decoded }
            guard data.distance(from: index, to: data.endIndex) >= size + 2 else {
                throw ProxyServerError.lookup("Truncated chunked DoH response")
            }
            decoded.append(data[index..<data.index(index, offsetBy: size)])
            index = data.index(index, offsetBy: size + 2)
        }
        return decoded
    }

    private static func parseAddresses(from body: Data) throws -> [String] {
        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              (object["Status"] as? Int) == 0 else {
            return []
        }
        let answers = object["Answer"] as? [[String: Any]] ?? []
        return answers.compactMap { answer in
            guard (answer["type"] as? Int) == 1,
                  let data = answer["data"] as? String,
                  data.isIPv4Literal else {
                return nil
            }
            return data
        }
    }

    private static func withTimeout<T: Sendable>(seconds: UInt64, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                throw ProxyServerError.lookup("DoH query timed out")
            }
            guard let result = try await group.next() else {
                throw ProxyServerError.lookup("DoH query did not produce a result")
            }
            group.cancelAll()
            return result
        }
    }
}

// MARK: - Network interface preference (DoH connects on the physical interface)

private actor PhysicalInterfacePreference {
    static let shared = PhysicalInterfacePreference()

    struct Preference: Sendable {
        var interface: NWInterface
    }

    private var cachedPreference: Preference?
    private var lastCheck = Date.distantPast

    func current() async -> Preference? {
        if Date().timeIntervalSince(lastCheck) < 30 {
            return cachedPreference
        }
        for type in [NWInterface.InterfaceType.wifi, .wiredEthernet] {
            if let interface = await satisfiedInterface(type) {
                cachedPreference = Preference(interface: interface)
                lastCheck = Date()
                return cachedPreference
            }
        }
        cachedPreference = nil
        lastCheck = Date()
        return nil
    }

    private func satisfiedInterface(_ type: NWInterface.InterfaceType) async -> NWInterface? {
        await withCheckedContinuation { (continuation: CheckedContinuation<NWInterface?, Never>) in
            let queue = DispatchQueue(label: "blaze.PhysicalInterfacePreference.\(type)")
            let monitor = NWPathMonitor(requiredInterfaceType: type)
            let result = PathMonitorResult(continuation: continuation, monitor: monitor)
            monitor.pathUpdateHandler = { path in
                if path.status == .satisfied {
                    result.finish(path.availableInterfaces.first { $0.type == type })
                }
            }
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + .milliseconds(250)) {
                result.finish(nil)
            }
        }
    }
}

private final class PathMonitorResult: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: CheckedContinuation<NWInterface?, Never>
    private let monitor: NWPathMonitor
    private var didResume = false

    init(continuation: CheckedContinuation<NWInterface?, Never>, monitor: NWPathMonitor) {
        self.continuation = continuation
        self.monitor = monitor
    }

    func finish(_ result: NWInterface?) {
        lock.lock()
        guard !didResume else { lock.unlock(); return }
        didResume = true
        lock.unlock()
        monitor.cancel()
        continuation.resume(returning: result)
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
        guard storedResult == nil else { lock.unlock(); return }
        storedResult = result
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeout: DispatchTimeInterval) -> Bool {
        semaphore.wait(timeout: .now() + timeout) == .success
    }
}

// MARK: - String helpers

extension String {
    var isIPv4Literal: Bool {
        var address = in_addr()
        return withCString { inet_pton(AF_INET, $0, &address) == 1 }
    }

    var isIPAddressLiteral: Bool {
        if isIPv4Literal { return true }
        var address = in6_addr()
        return withCString { inet_pton(AF_INET6, $0, &address) == 1 }
    }

    var isFakeIPv4Literal: Bool {
        var address = in_addr()
        guard withCString({ inet_pton(AF_INET, $0, &address) == 1 }) else { return false }
        return UpstreamHostDNS.isFakeIP(UInt32(bigEndian: address.s_addr))
    }
}
