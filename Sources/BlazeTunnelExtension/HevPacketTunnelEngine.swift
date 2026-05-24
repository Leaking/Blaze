import Darwin
import Foundation
@preconcurrency import NetworkExtension
import os.log

enum HevPacketTunnelError: Error, CustomStringConvertible, LocalizedError {
    case socketPairFailed(errno: Int32)
    case libraryNotFound([String])
    case libraryLoadFailed(path: String, message: String)
    case missingSymbol(String)
    case invalidConfiguration(String)

    var description: String {
        switch self {
        case .socketPairFailed(let errno):
            "socketpair failed: errno \(errno)"
        case .libraryNotFound(let candidates):
            "HEV library was not found. Checked: \(candidates.joined(separator: ", "))"
        case .libraryLoadFailed(let path, let message):
            "Failed to load HEV library at \(path): \(message)"
        case .missingSymbol(let symbol):
            "HEV library is missing required symbol: \(symbol)"
        case .invalidConfiguration(let message):
            "Invalid HEV configuration: \(message)"
        }
    }

    var errorDescription: String? {
        description
    }
}

final class HevPacketTunnelEngine: PacketTunnelRunning, @unchecked Sendable {
    private static let bridgeBufferSize: Int32 = 1 << 20
    private static let bridgeWriteTimeoutMilliseconds: Int32 = 250

    private let logger = Logger(subsystem: "com.chenhuazhao.blaze.tunnel", category: "HevPacketTunnelEngine")
    private let packetFlow: NEPacketTunnelFlow
    private let configuration: PacketTunnelRuntimeConfiguration
    private let library: HevSocks5TunnelLibrary
    private let bridgeFileDescriptor: Int32
    private let hevFileDescriptor: Int32
    private let hevConfigData: Data
    private let inputQueue = DispatchQueue(label: "com.chenhuazhao.blaze.tunnel.hev-input")
    private let outputQueue = DispatchQueue(label: "com.chenhuazhao.blaze.tunnel.hev-output")
    private let runQueue = DispatchQueue(label: "com.chenhuazhao.blaze.tunnel.hev-run")
    private let stateQueue = DispatchQueue(label: "com.chenhuazhao.blaze.tunnel.hev-state")
    private let diagnosticsQueue = DispatchQueue(label: "com.chenhuazhao.blaze.tunnel.hev-diagnostics")
    private var outputReadSource: DispatchSourceRead?
    private var diagnostics = PacketTunnelDiagnostics()
    private var stopped = false

    init(packetFlow: NEPacketTunnelFlow, configuration: PacketTunnelRuntimeConfiguration) throws {
        guard configuration.socksHost == "127.0.0.1", (1...65_535).contains(configuration.socksPort) else {
            throw HevPacketTunnelError.invalidConfiguration("HEV integration currently expects a local SOCKS5 listener on 127.0.0.1:1-65535")
        }

        var fileDescriptors: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &fileDescriptors) == 0 else {
            throw HevPacketTunnelError.socketPairFailed(errno: errno)
        }

        do {
            self.packetFlow = packetFlow
            self.configuration = configuration
            library = try HevSocks5TunnelLibrary.load(configuredDirectory: configuration.hevLibraryDirectory)
            bridgeFileDescriptor = fileDescriptors[0]
            hevFileDescriptor = fileDescriptors[1]
            hevConfigData = try HevSocks5TunnelConfiguration(configuration: configuration).data()
            Self.setSocketBufferSize(fileDescriptor: bridgeFileDescriptor, option: SO_SNDBUF, size: Self.bridgeBufferSize)
            Self.setSocketBufferSize(fileDescriptor: bridgeFileDescriptor, option: SO_RCVBUF, size: Self.bridgeBufferSize)
            Self.setSocketBufferSize(fileDescriptor: hevFileDescriptor, option: SO_SNDBUF, size: Self.bridgeBufferSize)
            Self.setSocketBufferSize(fileDescriptor: hevFileDescriptor, option: SO_RCVBUF, size: Self.bridgeBufferSize)
            try Self.setNonBlocking(fileDescriptor: bridgeFileDescriptor)
            startOutputReadSource()
            startHevTunnel()
        } catch {
            close(fileDescriptors[0])
            close(fileDescriptors[1])
            throw error
        }
    }

    func handlePackets(_ packets: [Data], protocols: [NSNumber]) {
        guard !packets.isEmpty else { return }
        inputQueue.async { [weak self] in
            guard let self, !self.isStopped else { return }
            for (index, packet) in packets.enumerated() {
                let protocolNumber = index < protocols.count ? protocols[index].int32Value : Self.protocolFamily(for: packet)
                self.recordIngress(packet: packet, protocolNumber: protocolNumber)
                self.writePacketToHev(packet, protocolNumber: protocolNumber)
            }
        }
    }

    func stop() {
        let shouldStop = stateQueue.sync { () -> Bool in
            if stopped {
                return false
            }
            stopped = true
            return true
        }

        guard shouldStop else { return }
        outputReadSource?.cancel()
        outputReadSource = nil
        library.quit()
    }

    func diagnosticsSnapshot() -> PacketTunnelDiagnostics {
        diagnosticsQueue.sync {
            var snapshot = diagnostics
            var txPackets = 0
            var txBytes = 0
            var rxPackets = 0
            var rxBytes = 0
            library.stats(&txPackets, &txBytes, &rxPackets, &rxBytes)
            snapshot.hevTunnelTxPackets = UInt64(max(txPackets, 0))
            snapshot.hevTunnelTxBytes = UInt64(max(txBytes, 0))
            snapshot.hevTunnelRxPackets = UInt64(max(rxPackets, 0))
            snapshot.hevTunnelRxBytes = UInt64(max(rxBytes, 0))
            return snapshot
        }
    }

    deinit {
        stop()
    }

    private var isStopped: Bool {
        stateQueue.sync { stopped }
    }

    private func startOutputReadSource() {
        let source = DispatchSource.makeReadSource(fileDescriptor: bridgeFileDescriptor, queue: outputQueue)
        source.setEventHandler { [weak self] in
            self?.drainHevOutput()
        }
        source.setCancelHandler { [bridgeFileDescriptor] in
            close(bridgeFileDescriptor)
        }
        outputReadSource = source
        source.resume()
    }

    private func startHevTunnel() {
        runQueue.async { [weak self, library, hevConfigData, hevFileDescriptor] in
            let result = hevConfigData.withUnsafeBytes { rawBuffer -> Int32 in
                guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                    return -1
                }
                return library.mainFromString(baseAddress, UInt32(rawBuffer.count), hevFileDescriptor)
            }

            close(hevFileDescriptor)
            if result == 0 {
                self?.logger.info("HEV socks5 tunnel stopped")
            } else {
                self?.logger.error("HEV socks5 tunnel exited with result \(result, privacy: .public)")
            }
        }
    }

    private func drainHevOutput() {
        var buffer = [UInt8](repeating: 0, count: 65_540)

        while !isStopped {
            let byteCount = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                return recv(bridgeFileDescriptor, baseAddress, rawBuffer.count, 0)
            }

            if byteCount > 0 {
                handleHevFrame(buffer: buffer, byteCount: byteCount)
            } else if byteCount == 0 {
                return
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                logger.error("Failed reading HEV output bridge: errno \(errno, privacy: .public)")
                return
            }
        }
    }

    private func handleHevFrame(buffer: [UInt8], byteCount: Int) {
        guard byteCount > 4 else {
            recordBridgeWriteFailure()
            return
        }

        let family = (UInt32(buffer[0]) << 24)
            | (UInt32(buffer[1]) << 16)
            | (UInt32(buffer[2]) << 8)
            | UInt32(buffer[3])
        let protocolNumber: Int32
        switch Int32(family) {
        case AF_INET:
            protocolNumber = AF_INET
        case AF_INET6:
            protocolNumber = AF_INET6
        default:
            recordBridgeWriteFailure()
            return
        }

        let packet = Data(buffer[4..<byteCount])
        guard Self.protocolFamily(for: packet) == protocolNumber else {
            recordBridgeWriteFailure()
            return
        }

        diagnosticsQueue.async { [packetCount = UInt64(1), byteCount = UInt64(packet.count), weak self] in
            self?.diagnostics.hevPacketsReceivedFromTunnel &+= packetCount
            self?.diagnostics.hevBytesReceivedFromTunnel &+= byteCount
        }
        if !packetFlow.writePackets([packet], withProtocols: [NSNumber(value: protocolNumber)]) {
            recordBridgeWriteFailure()
        }
    }

    private func writePacketToHev(_ packet: Data, protocolNumber: Int32) {
        let family = protocolNumber == AF_INET || protocolNumber == AF_INET6
            ? protocolNumber
            : Self.protocolFamily(for: packet)
        guard family == AF_INET || family == AF_INET6 else {
            recordBridgeWriteFailure()
            return
        }

        var frame = Data(capacity: packet.count + 4)
        var familyHeader = UInt32(family).bigEndian
        withUnsafeBytes(of: &familyHeader) { rawBuffer in
            frame.append(rawBuffer.bindMemory(to: UInt8.self))
        }
        frame.append(packet)

        if sendFrameToHev(frame) {
            diagnosticsQueue.async { [packetBytes = UInt64(packet.count), weak self] in
                self?.diagnostics.hevPacketsSentToTunnel &+= 1
                self?.diagnostics.hevBytesSentToTunnel &+= packetBytes
            }
        } else {
            recordBridgeWriteFailure()
        }
    }

    private func sendFrameToHev(_ frame: Data) -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(Self.bridgeWriteTimeoutMilliseconds) * 1_000_000

        while !isStopped {
            let result = frame.withUnsafeBytes { rawBuffer -> (sent: Int, code: Int32) in
                guard let baseAddress = rawBuffer.baseAddress else { return (-1, EINVAL) }
                let sent = send(bridgeFileDescriptor, baseAddress, rawBuffer.count, 0)
                return (sent, sent < 0 ? errno : 0)
            }

            if result.sent == frame.count {
                return true
            }
            if result.sent >= 0 {
                logger.error("Partial HEV bridge datagram write: \(result.sent, privacy: .public)/\(frame.count, privacy: .public)")
                return false
            }

            switch result.code {
            case EINTR:
                continue
            case EAGAIN, EWOULDBLOCK:
                guard waitForBridgeWritable(until: deadline) else {
                    logger.error("Timed out waiting for HEV bridge write capacity")
                    return false
                }
            default:
                logger.error("Failed writing HEV input bridge: errno \(result.code, privacy: .public)")
                return false
            }
        }

        return false
    }

    private func waitForBridgeWritable(until deadline: UInt64) -> Bool {
        while !isStopped {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return false }
            let remainingMilliseconds = max(1, min(Int(Int32.max), Int((deadline - now) / 1_000_000)))
            var descriptor = pollfd(fd: bridgeFileDescriptor, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&descriptor, 1, Int32(remainingMilliseconds))

            if ready > 0 {
                if (descriptor.revents & Int16(POLLOUT)) != 0 {
                    return true
                }
                if (descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL)) != 0 {
                    return false
                }
            } else if ready == 0 {
                return false
            } else if errno != EINTR {
                return false
            }
        }

        return false
    }

    private func recordIngress(packet: Data, protocolNumber: Int32) {
        diagnosticsQueue.async { [weak self] in
            guard let self else { return }
            self.diagnostics.packetsRead &+= 1

            if let ipv4 = IPv4Packet.parse(packet) {
                self.diagnostics.ipv4Packets &+= 1
                switch ipv4.protocolNumber {
                case IPProtocolNumber.tcp:
                    self.diagnostics.tcpPackets &+= 1
                case IPProtocolNumber.udp:
                    self.diagnostics.udpPackets &+= 1
                    if let udp = UDPPacket.parse(ipv4: ipv4), udp.destinationPort == 53 {
                        self.diagnostics.dnsQueries &+= 1
                    }
                default:
                    break
                }
                return
            }

            if let ipv6 = IPv6Packet.parse(packet) {
                self.diagnostics.ipv6Packets &+= 1
                switch ipv6.nextHeader {
                case IPProtocolNumber.tcp:
                    self.diagnostics.tcpPackets &+= 1
                case IPProtocolNumber.udp:
                    self.diagnostics.udpPackets &+= 1
                default:
                    break
                }
                return
            }

            if protocolNumber == AF_INET {
                self.diagnostics.ipv4Packets &+= 1
            } else if protocolNumber == AF_INET6 {
                self.diagnostics.ipv6Packets &+= 1
            } else {
                self.diagnostics.unknownPackets &+= 1
            }
        }
    }

    private func recordBridgeWriteFailure() {
        diagnosticsQueue.async { [weak self] in
            self?.diagnostics.hevBridgeWriteFailures &+= 1
        }
    }

    private static func protocolFamily(for packet: Data) -> Int32 {
        guard let firstByte = packet.first else { return 0 }
        switch firstByte >> 4 {
        case 4:
            return AF_INET
        case 6:
            return AF_INET6
        default:
            return 0
        }
    }

    private static func setNonBlocking(fileDescriptor: Int32) throws {
        let flags = fcntl(fileDescriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw HevPacketTunnelError.socketPairFailed(errno: errno)
        }
    }

    private static func setSocketBufferSize(fileDescriptor: Int32, option: Int32, size: Int32) {
        var value = size
        _ = setsockopt(fileDescriptor, SOL_SOCKET, option, &value, socklen_t(MemoryLayout<Int32>.size))
    }
}

struct HevSocks5TunnelConfiguration {
    private static let mapDNSAddress = PacketTunnelRuntimeConfiguration.hevMapDNSServer
    private static let mapDNSNetwork = "198.18.0.0"
    private static let mapDNSNetmask = "255.255.0.0"
    private let configuration: PacketTunnelRuntimeConfiguration

    init(configuration: PacketTunnelRuntimeConfiguration) {
        self.configuration = configuration
    }

    func data() throws -> Data {
        guard (1...65_535).contains(configuration.socksPort) else {
            throw HevPacketTunnelError.invalidConfiguration("socksPort must be in 1...65535")
        }

        let udpMode = configuration.hevUDPMode == "tcp" ? "tcp" : "udp"
        let config = """
        tunnel:
          mtu: \(configuration.tunnelMTU)
        socks5:
          address: \(Self.yamlSingleQuoted(configuration.socksHost))
          port: \(configuration.socksPort)
          udp: \(Self.yamlSingleQuoted(udpMode))
        mapdns:
          address: \(Self.yamlSingleQuoted(Self.mapDNSAddress))
          port: 53
          network: \(Self.yamlSingleQuoted(Self.mapDNSNetwork))
          netmask: \(Self.yamlSingleQuoted(Self.mapDNSNetmask))
          cache-size: 10000
        misc:
          task-stack-size: 86016
          tcp-buffer-size: 65536
          udp-recv-buffer-size: 524288
          udp-copy-buffer-nums: 10
          connect-timeout: 10000
          tcp-read-write-timeout: 300000
          udp-read-write-timeout: 60000
          log-file: stderr
          log-level: warn
        """

        guard let data = config.data(using: .utf8) else {
            throw HevPacketTunnelError.invalidConfiguration("config is not valid UTF-8")
        }
        return data
    }

    private static func yamlSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }
}

private final class HevSocks5TunnelLibrary: @unchecked Sendable {
    typealias MainFromString = @convention(c) (UnsafePointer<UInt8>, UInt32, Int32) -> Int32
    typealias Quit = @convention(c) () -> Void
    typealias Stats = @convention(c) (UnsafeMutablePointer<Int>, UnsafeMutablePointer<Int>, UnsafeMutablePointer<Int>, UnsafeMutablePointer<Int>) -> Void

    let mainFromString: MainFromString
    let quit: Quit
    let stats: Stats
    private let handle: UnsafeMutableRawPointer

    private init(handle: UnsafeMutableRawPointer, mainFromString: @escaping MainFromString, quit: @escaping Quit, stats: @escaping Stats) {
        self.handle = handle
        self.mainFromString = mainFromString
        self.quit = quit
        self.stats = stats
    }

    static func load(configuredDirectory: String?) throws -> HevSocks5TunnelLibrary {
        let candidates = libraryCandidates(configuredDirectory: configuredDirectory)
        var lastLoadError: (path: String, message: String)?

        for candidate in candidates {
            guard FileManager.default.fileExists(atPath: candidate) else {
                continue
            }

            guard let handle = dlopen(candidate, RTLD_NOW | RTLD_LOCAL) else {
                let message = dlerror().map { String(cString: $0) } ?? "unknown dlopen error"
                lastLoadError = (candidate, message)
                continue
            }

            do {
                return try HevSocks5TunnelLibrary(
                    handle: handle,
                    mainFromString: symbol("hev_socks5_tunnel_main_from_str", in: handle, as: MainFromString.self),
                    quit: symbol("hev_socks5_tunnel_quit", in: handle, as: Quit.self),
                    stats: symbol("hev_socks5_tunnel_stats", in: handle, as: Stats.self)
                )
            } catch {
                dlclose(handle)
                throw error
            }
        }

        if let lastLoadError {
            throw HevPacketTunnelError.libraryLoadFailed(path: lastLoadError.path, message: lastLoadError.message)
        }
        throw HevPacketTunnelError.libraryNotFound(candidates)
    }

    private static func symbol<T>(_ name: String, in handle: UnsafeMutableRawPointer, as type: T.Type) throws -> T {
        guard let symbol = dlsym(handle, name) else {
            throw HevPacketTunnelError.missingSymbol(name)
        }
        return unsafeBitCast(symbol, to: type)
    }

    private static func libraryCandidates(configuredDirectory: String?) -> [String] {
        var directories: [String] = []
        if let configuredDirectory, !configuredDirectory.isEmpty {
            directories.append(configuredDirectory)
        }
        if let privateFrameworksPath = Bundle.main.privateFrameworksURL?.path {
            directories.append(privateFrameworksPath)
        }
        if let resourcePath = Bundle.main.resourceURL?.appendingPathComponent("HevSocks5Tunnel").path {
            directories.append(resourcePath)
        }
        if let executablePath = Bundle.main.executableURL?.deletingLastPathComponent().path {
            directories.append(executablePath)
        }

        return Array(NSOrderedSet(array: directories).array.compactMap { $0 as? String })
            .flatMap { directory in
                [
                    "\(directory)/libhev-socks5-tunnel.dylib",
                    "\(directory)/libhev-socks5-tunnel.so"
                ]
            }
    }
}
