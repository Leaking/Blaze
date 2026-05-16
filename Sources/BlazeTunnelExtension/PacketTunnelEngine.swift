import CFNetwork
import Darwin
import Foundation
import NetworkExtension
import os.log

struct PacketTunnelRuntimeConfiguration {
    var httpHost: String
    var httpPort: Int
    var socksHost: String
    var socksPort: Int
    var dnsOverHTTPSURL: URL
    var excludedIPv4Addresses: [String]
    var suppressIPv6DNS: Bool

    init(providerConfiguration: [String: Any]?) {
        httpHost = providerConfiguration?["httpHost"] as? String ?? "127.0.0.1"
        httpPort = providerConfiguration?["httpPort"] as? Int ?? 19080
        socksHost = providerConfiguration?["socksHost"] as? String ?? "127.0.0.1"
        socksPort = providerConfiguration?["socksPort"] as? Int ?? 19081
        let dnsURL = providerConfiguration?["dnsOverHTTPSURL"] as? String ?? "https://1.1.1.1/dns-query"
        dnsOverHTTPSURL = URL(string: dnsURL) ?? URL(string: "https://1.1.1.1/dns-query")!
        excludedIPv4Addresses = providerConfiguration?["excludedIPv4Addresses"] as? [String] ?? []
        suppressIPv6DNS = providerConfiguration?["suppressIPv6DNS"] as? Bool ?? true
    }
}

final class PacketTunnelEngine: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.chenhuazhao.blaze.tunnel", category: "PacketTunnelEngine")
    private let packetFlow: NEPacketTunnelFlow
    private let configuration: PacketTunnelRuntimeConfiguration
    private let queue = DispatchQueue(label: "com.chenhuazhao.blaze.tunnel.engine")
    private let dnsProxy: DNSOverHTTPSProxy
    private var flows: [TCPFlowKey: TCPForwarder] = [:]
    private var stopped = false

    init(packetFlow: NEPacketTunnelFlow, configuration: PacketTunnelRuntimeConfiguration) {
        self.packetFlow = packetFlow
        self.configuration = configuration
        dnsProxy = DNSOverHTTPSProxy(
            url: configuration.dnsOverHTTPSURL,
            httpProxyHost: configuration.httpHost,
            httpProxyPort: configuration.httpPort,
            suppressIPv6DNS: configuration.suppressIPv6DNS
        )
    }

    func handlePackets(_ packets: [Data], protocols: [NSNumber]) {
        guard !packets.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            for packet in packets {
                self.handlePacket(packet)
            }
        }
    }

    func stop() {
        queue.sync {
            stopped = true
            let activeFlows = flows.values
            flows.removeAll()
            activeFlows.forEach { $0.stop() }
        }
    }

    private func handlePacket(_ packet: Data) {
        guard let ipv4 = IPv4Packet.parse(packet) else { return }

        switch ipv4.protocolNumber {
        case IPProtocolNumber.tcp:
            guard let tcp = TCPPacket.parse(ipv4: ipv4) else { return }
            handleTCP(ipv4: ipv4, tcp: tcp)
        case IPProtocolNumber.udp:
            guard let udp = UDPPacket.parse(ipv4: ipv4) else { return }
            handleUDP(ipv4: ipv4, udp: udp)
        default:
            return
        }
    }

    private func handleTCP(ipv4: IPv4Packet, tcp: TCPPacket) {
        let key = TCPFlowKey(
            sourceAddress: ipv4.sourceAddress,
            sourcePort: tcp.sourcePort,
            destinationAddress: ipv4.destinationAddress,
            destinationPort: tcp.destinationPort
        )

        if tcp.flags.contains(.reset) {
            flows.removeValue(forKey: key)?.stop()
            return
        }

        let flow: TCPForwarder
        if let existing = flows[key] {
            flow = existing
        } else if tcp.flags.contains(.syn) {
            flow = TCPForwarder(
                key: key,
                socksHost: configuration.socksHost,
                socksPort: configuration.socksPort,
                packetWriter: { [weak self] packet in
                    self?.writeIPv4Packet(packet)
                },
                onClose: { [weak self] flowKey in
                    self?.removeFlow(flowKey)
                }
            )
            flows[key] = flow
        } else {
            return
        }

        flow.handle(tcp)
    }

    private func handleUDP(ipv4: IPv4Packet, udp: UDPPacket) {
        if udp.destinationPort == 53 {
            dnsProxy.handleQuery(ipv4: ipv4, udp: udp) { [weak self] packet in
                self?.writeIPv4Packet(packet)
            }
            return
        }

        logger.debug("Rejecting unsupported UDP \(IPv4AddressFormatter.string(from: ipv4.sourceAddress), privacy: .public):\(udp.sourcePort, privacy: .public) -> \(IPv4AddressFormatter.string(from: ipv4.destinationAddress), privacy: .public):\(udp.destinationPort, privacy: .public)")
        writeIPv4Packet(IPv4PacketFactory.icmpDestinationUnreachable(for: ipv4, code: 3))
    }

    private func writeIPv4Packet(_ packet: Data) {
        packetFlow.writePackets([packet], withProtocols: [NSNumber(value: AF_INET)])
    }

    private func removeFlow(_ key: TCPFlowKey) {
        queue.async { [weak self] in
            self?.flows.removeValue(forKey: key)
        }
    }
}

private enum IPProtocolNumber {
    static let icmp: UInt8 = 1
    static let tcp: UInt8 = 6
    static let udp: UInt8 = 17
}

private struct TCPFlowKey: Hashable, Sendable {
    var sourceAddress: UInt32
    var sourcePort: UInt16
    var destinationAddress: UInt32
    var destinationPort: UInt16

    var destinationAddressString: String {
        IPv4AddressFormatter.string(from: destinationAddress)
    }
}

private struct IPv4Packet: Sendable {
    var sourceAddress: UInt32
    var destinationAddress: UInt32
    var protocolNumber: UInt8
    var header: Data
    var payload: Data

    static func parse(_ data: Data) -> IPv4Packet? {
        guard data.count >= 20 else { return nil }
        let first = data[0]
        guard first >> 4 == 4 else { return nil }
        let headerLength = Int(first & 0x0f) * 4
        guard headerLength >= 20, data.count >= headerLength else { return nil }
        guard let totalLength = data.uint16(at: 2) else { return nil }
        let packetLength = min(Int(totalLength), data.count)
        guard packetLength >= headerLength else { return nil }
        guard let sourceAddress = data.uint32(at: 12), let destinationAddress = data.uint32(at: 16) else { return nil }
        return IPv4Packet(
            sourceAddress: sourceAddress,
            destinationAddress: destinationAddress,
            protocolNumber: data[9],
            header: data.subdata(in: 0..<headerLength),
            payload: data.subdata(in: headerLength..<packetLength)
        )
    }

    var icmpQuote: Data {
        var quote = Data()
        quote.append(header)
        quote.append(payload.prefix(8))
        return quote
    }
}

private struct TCPFlags: OptionSet, Sendable {
    let rawValue: UInt8

    static let fin = TCPFlags(rawValue: 0x01)
    static let syn = TCPFlags(rawValue: 0x02)
    static let reset = TCPFlags(rawValue: 0x04)
    static let push = TCPFlags(rawValue: 0x08)
    static let ack = TCPFlags(rawValue: 0x10)
}

private struct TCPPacket: Sendable {
    var sourcePort: UInt16
    var destinationPort: UInt16
    var sequenceNumber: UInt32
    var acknowledgmentNumber: UInt32
    var flags: TCPFlags
    var window: UInt16
    var payload: Data

    static func parse(ipv4: IPv4Packet) -> TCPPacket? {
        let data = ipv4.payload
        guard data.count >= 20 else { return nil }
        guard let sourcePort = data.uint16(at: 0),
              let destinationPort = data.uint16(at: 2),
              let sequenceNumber = data.uint32(at: 4),
              let acknowledgmentNumber = data.uint32(at: 8),
              let window = data.uint16(at: 14) else {
            return nil
        }
        let headerLength = Int(data[12] >> 4) * 4
        guard headerLength >= 20, data.count >= headerLength else { return nil }
        return TCPPacket(
            sourcePort: sourcePort,
            destinationPort: destinationPort,
            sequenceNumber: sequenceNumber,
            acknowledgmentNumber: acknowledgmentNumber,
            flags: TCPFlags(rawValue: data[13]),
            window: window,
            payload: data.subdata(in: headerLength..<data.count)
        )
    }
}

private struct UDPPacket: Sendable {
    var sourcePort: UInt16
    var destinationPort: UInt16
    var payload: Data

    static func parse(ipv4: IPv4Packet) -> UDPPacket? {
        let data = ipv4.payload
        guard data.count >= 8 else { return nil }
        guard let sourcePort = data.uint16(at: 0),
              let destinationPort = data.uint16(at: 2),
              let length = data.uint16(at: 4) else {
            return nil
        }
        let payloadEnd = min(data.count, Int(length))
        guard payloadEnd >= 8 else { return nil }
        return UDPPacket(
            sourcePort: sourcePort,
            destinationPort: destinationPort,
            payload: data.subdata(in: 8..<payloadEnd)
        )
    }
}

private final class TCPForwarder: @unchecked Sendable {
    private enum State {
        case new
        case synReceived
        case established
        case closing
        case closed
    }

    private let key: TCPFlowKey
    private let socksHost: String
    private let socksPort: Int
    private let packetWriter: @Sendable (Data) -> Void
    private let onClose: @Sendable (TCPFlowKey) -> Void
    private let queue: DispatchQueue
    private var state: State = .new
    private var socketFD: Int32 = -1
    private var connecting = false
    private var clientNextSequence: UInt32 = 0
    private var serverSequence: UInt32 = UInt32.random(in: 1...UInt32.max)
    private var clientWindow: UInt16 = 65_535
    private var pendingPayloads: [Data] = []

    init(
        key: TCPFlowKey,
        socksHost: String,
        socksPort: Int,
        packetWriter: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable (TCPFlowKey) -> Void
    ) {
        self.key = key
        self.socksHost = socksHost
        self.socksPort = socksPort
        self.packetWriter = packetWriter
        self.onClose = onClose
        queue = DispatchQueue(label: "com.chenhuazhao.blaze.tunnel.flow.\(key.sourcePort).\(key.destinationPort)")
    }

    func handle(_ packet: TCPPacket) {
        queue.async { [weak self] in
            self?.handleLocked(packet)
        }
    }

    func stop() {
        queue.sync {
            closeLocked(notify: false)
        }
    }

    private func handleLocked(_ packet: TCPPacket) {
        guard state != .closed else { return }
        clientWindow = packet.window

        if packet.flags.contains(.reset) {
            closeLocked(notify: true)
            return
        }

        if packet.flags.contains(.syn) {
            handleSYN(packet)
            return
        }

        guard state != .new else { return }

        if !packet.payload.isEmpty {
            let expectedEnd = packet.sequenceNumber &+ UInt32(packet.payload.count)
            if packet.sequenceNumber == clientNextSequence {
                clientNextSequence = expectedEnd
                sendACKLocked()
                writeOrBufferLocked(packet.payload)
            } else if packet.sequenceNumber &+ UInt32(packet.payload.count) <= clientNextSequence {
                sendACKLocked()
            } else {
                sendACKLocked()
            }
        }

        if packet.flags.contains(.fin) {
            clientNextSequence = clientNextSequence &+ 1
            sendACKLocked()
            if socketFD >= 0 {
                shutdown(socketFD, SHUT_WR)
            }
            state = .closing
        }
    }

    private func handleSYN(_ packet: TCPPacket) {
        switch state {
        case .new:
            clientNextSequence = packet.sequenceNumber &+ 1
            state = .synReceived
            sendSegmentLocked(flags: [.syn, .ack], payload: Data())
            startUpstreamLocked()
        case .synReceived, .established:
            sendSegmentLocked(flags: [.syn, .ack], payload: Data(), advanceSequence: false)
        case .closing, .closed:
            break
        }
    }

    private func startUpstreamLocked() {
        guard !connecting, socketFD < 0 else { return }
        connecting = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let fd = try SOCKS5Connector.connect(
                    socksHost: self.socksHost,
                    socksPort: self.socksPort,
                    destinationIPv4: self.key.destinationAddress,
                    destinationPort: self.key.destinationPort
                )
                self.queue.async {
                    self.finishUpstreamConnectLocked(fd: fd)
                }
            } catch {
                self.queue.async {
                    self.sendSegmentLocked(flags: [.reset, .ack], payload: Data(), advanceSequence: false)
                    self.closeLocked(notify: true)
                }
            }
        }
    }

    private func finishUpstreamConnectLocked(fd: Int32) {
        guard state != .closed else {
            Darwin.close(fd)
            return
        }
        socketFD = fd
        connecting = false
        if state == .synReceived {
            state = .established
        }

        let buffered = pendingPayloads
        pendingPayloads.removeAll()
        for payload in buffered {
            guard writeSocketLocked(payload) else { return }
        }
        startReadLoop(fd: fd)
    }

    private func writeOrBufferLocked(_ payload: Data) {
        guard !payload.isEmpty else { return }
        if socketFD >= 0 {
            _ = writeSocketLocked(payload)
        } else {
            pendingPayloads.append(payload)
            startUpstreamLocked()
        }
    }

    @discardableResult
    private func writeSocketLocked(_ payload: Data) -> Bool {
        guard socketFD >= 0 else { return false }
        let ok = payload.withUnsafeBytes { rawBuffer -> Bool in
            guard let base = rawBuffer.baseAddress else { return true }
            var sent = 0
            while sent < rawBuffer.count {
                let result = Darwin.send(socketFD, base.advanced(by: sent), rawBuffer.count - sent, 0)
                if result <= 0 {
                    return false
                }
                sent += result
            }
            return true
        }

        if !ok {
            sendSegmentLocked(flags: [.reset, .ack], payload: Data(), advanceSequence: false)
            closeLocked(notify: true)
        }
        return ok
    }

    private func startReadLoop(fd: Int32) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let count = Darwin.recv(fd, &buffer, buffer.count, 0)
                if count > 0 {
                    self?.handleUpstreamData(Data(buffer[0..<count]))
                } else {
                    self?.handleUpstreamClosed()
                    return
                }
            }
        }
    }

    private func handleUpstreamData(_ data: Data) {
        queue.async { [weak self] in
            guard let self, self.state != .closed else { return }
            var offset = 0
            let bytes = [UInt8](data)
            while offset < bytes.count {
                let chunkSize = min(1360, bytes.count - offset)
                let chunk = Data(bytes[offset..<(offset + chunkSize)])
                self.sendSegmentLocked(flags: [.push, .ack], payload: chunk)
                offset += chunkSize
            }
        }
    }

    private func handleUpstreamClosed() {
        queue.async { [weak self] in
            guard let self, self.state != .closed else { return }
            self.sendSegmentLocked(flags: [.fin, .ack], payload: Data())
            self.closeLocked(notify: true)
        }
    }

    private func sendACKLocked() {
        sendSegmentLocked(flags: [.ack], payload: Data(), advanceSequence: false)
    }

    private func sendSegmentLocked(flags: TCPFlags, payload: Data, advanceSequence: Bool = true) {
        let packet = IPv4PacketFactory.tcp(
            sourceAddress: key.destinationAddress,
            destinationAddress: key.sourceAddress,
            sourcePort: key.destinationPort,
            destinationPort: key.sourcePort,
            sequenceNumber: serverSequence,
            acknowledgmentNumber: clientNextSequence,
            flags: flags,
            window: clientWindow == 0 ? 65_535 : clientWindow,
            payload: payload
        )
        packetWriter(packet)

        guard advanceSequence else { return }
        var increment = UInt32(payload.count)
        if flags.contains(.syn) {
            increment = increment &+ 1
        }
        if flags.contains(.fin) {
            increment = increment &+ 1
        }
        serverSequence = serverSequence &+ increment
    }

    private func closeLocked(notify: Bool) {
        guard state != .closed else { return }
        state = .closed
        if socketFD >= 0 {
            Darwin.close(socketFD)
            socketFD = -1
        }
        pendingPayloads.removeAll()
        if notify {
            onClose(key)
        }
    }
}

private enum SOCKS5Connector {
    enum ConnectorError: Error {
        case invalidSocksEndpoint
        case connectFailed(Int32)
        case handshakeFailed
        case connectRejected(UInt8)
    }

    static func connect(socksHost: String, socksPort: Int, destinationIPv4: UInt32, destinationPort: UInt16) throws -> Int32 {
        guard socksHost == "127.0.0.1", (1...65_535).contains(socksPort) else {
            throw ConnectorError.invalidSocksEndpoint
        }

        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else {
            throw ConnectorError.connectFailed(errno)
        }

        var timeout = timeval(tv_sec: 12, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(socksPort).bigEndian
        address.sin_addr = in_addr(s_addr: UInt32(0x7f000001).bigEndian)

        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            let code = errno
            Darwin.close(fd)
            throw ConnectorError.connectFailed(code)
        }

        do {
            try sendAll([0x05, 0x01, 0x00], fd: fd)
            let greeting = try recvExact(count: 2, fd: fd)
            guard greeting == [0x05, 0x00] else {
                throw ConnectorError.handshakeFailed
            }

            let ip = IPv4AddressFormatter.bytes(from: destinationIPv4)
            try sendAll([0x05, 0x01, 0x00, 0x01] + ip + UInt16(destinationPort).bytes, fd: fd)
            let head = try recvExact(count: 4, fd: fd)
            guard head[0] == 0x05 else {
                throw ConnectorError.handshakeFailed
            }
            guard head[1] == 0x00 else {
                throw ConnectorError.connectRejected(head[1])
            }

            let addressLength: Int
            switch head[3] {
            case 0x01:
                addressLength = 4
            case 0x03:
                addressLength = Int(try recvExact(count: 1, fd: fd)[0])
            case 0x04:
                addressLength = 16
            default:
                throw ConnectorError.handshakeFailed
            }
            _ = try recvExact(count: addressLength + 2, fd: fd)
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private static func sendAll(_ bytes: [UInt8], fd: Int32) throws {
        try bytes.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var sent = 0
            while sent < rawBuffer.count {
                let result = Darwin.send(fd, base.advanced(by: sent), rawBuffer.count - sent, 0)
                if result <= 0 {
                    throw ConnectorError.handshakeFailed
                }
                sent += result
            }
        }
    }

    private static func recvExact(count: Int, fd: Int32) throws -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(count)
        var buffer = [UInt8](repeating: 0, count: count)
        while result.count < count {
            let needed = count - result.count
            let received = Darwin.recv(fd, &buffer, needed, 0)
            guard received > 0 else {
                throw ConnectorError.handshakeFailed
            }
            result.append(contentsOf: buffer[0..<received])
        }
        return result
    }
}

private final class DNSOverHTTPSProxy: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.chenhuazhao.blaze.tunnel", category: "DNSOverHTTPSProxy")
    private let url: URL
    private let session: URLSession
    private let suppressIPv6DNS: Bool

    init(url: URL, httpProxyHost: String, httpProxyPort: Int, suppressIPv6DNS: Bool) {
        self.url = url
        self.suppressIPv6DNS = suppressIPv6DNS
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 8
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: true,
            kCFNetworkProxiesHTTPProxy as String: httpProxyHost,
            kCFNetworkProxiesHTTPPort as String: httpProxyPort,
            kCFNetworkProxiesHTTPSEnable as String: true,
            kCFNetworkProxiesHTTPSProxy as String: httpProxyHost,
            kCFNetworkProxiesHTTPSPort as String: httpProxyPort
        ]
        session = URLSession(configuration: configuration)
    }

    func handleQuery(ipv4: IPv4Packet, udp: UDPPacket, packetWriter: @escaping @Sendable (Data) -> Void) {
        if suppressIPv6DNS,
           DNSMessage.isAAAAQuestion(udp.payload),
           let response = DNSMessage.emptyNoErrorResponse(for: udp.payload) {
            logger.debug("Suppressing AAAA DNS answer while IPv6 packet forwarding is disabled")
            let packet = IPv4PacketFactory.udp(
                sourceAddress: ipv4.destinationAddress,
                destinationAddress: ipv4.sourceAddress,
                sourcePort: udp.destinationPort,
                destinationPort: udp.sourcePort,
                payload: response
            )
            packetWriter(packet)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = udp.payload
        request.setValue("application/dns-message", forHTTPHeaderField: "Content-Type")
        request.setValue("application/dns-message", forHTTPHeaderField: "Accept")

        let sourceAddress = ipv4.sourceAddress
        let destinationAddress = ipv4.destinationAddress
        let sourcePort = udp.sourcePort
        let destinationPort = udp.destinationPort

        session.dataTask(with: request) { data, _, error in
            if let error {
                self.logger.error("DoH query failed: \(String(describing: error), privacy: .public)")
                return
            }
            guard let data, !data.isEmpty else {
                self.logger.error("DoH query returned no response bytes")
                return
            }
            self.logger.debug("DoH query answered \(data.count, privacy: .public) bytes")
            let packet = IPv4PacketFactory.udp(
                sourceAddress: destinationAddress,
                destinationAddress: sourceAddress,
                sourcePort: destinationPort,
                destinationPort: sourcePort,
                payload: data
            )
            packetWriter(packet)
        }.resume()
    }
}

private enum IPv4PacketFactory {
    static func tcp(
        sourceAddress: UInt32,
        destinationAddress: UInt32,
        sourcePort: UInt16,
        destinationPort: UInt16,
        sequenceNumber: UInt32,
        acknowledgmentNumber: UInt32,
        flags: TCPFlags,
        window: UInt16,
        payload: Data
    ) -> Data {
        var tcp = [UInt8](repeating: 0, count: 20 + payload.count)
        tcp.writeUInt16(sourcePort, at: 0)
        tcp.writeUInt16(destinationPort, at: 2)
        tcp.writeUInt32(sequenceNumber, at: 4)
        tcp.writeUInt32(acknowledgmentNumber, at: 8)
        tcp[12] = 5 << 4
        tcp[13] = flags.rawValue
        tcp.writeUInt16(window, at: 14)
        tcp.writeUInt16(0, at: 16)
        tcp.writeUInt16(0, at: 18)
        tcp.replaceSubrange(20..<tcp.count, with: payload)

        let checksum = transportChecksum(
            sourceAddress: sourceAddress,
            destinationAddress: destinationAddress,
            protocolNumber: IPProtocolNumber.tcp,
            transport: tcp
        )
        tcp.writeUInt16(checksum, at: 16)
        return ipv4(sourceAddress: sourceAddress, destinationAddress: destinationAddress, protocolNumber: IPProtocolNumber.tcp, payload: tcp)
    }

    static func udp(
        sourceAddress: UInt32,
        destinationAddress: UInt32,
        sourcePort: UInt16,
        destinationPort: UInt16,
        payload: Data
    ) -> Data {
        var udp = [UInt8](repeating: 0, count: 8 + payload.count)
        udp.writeUInt16(sourcePort, at: 0)
        udp.writeUInt16(destinationPort, at: 2)
        udp.writeUInt16(UInt16(udp.count), at: 4)
        udp.writeUInt16(0, at: 6)
        udp.replaceSubrange(8..<udp.count, with: payload)

        let checksum = transportChecksum(
            sourceAddress: sourceAddress,
            destinationAddress: destinationAddress,
            protocolNumber: IPProtocolNumber.udp,
            transport: udp
        )
        udp.writeUInt16(checksum == 0 ? 0xffff : checksum, at: 6)
        return ipv4(sourceAddress: sourceAddress, destinationAddress: destinationAddress, protocolNumber: IPProtocolNumber.udp, payload: udp)
    }

    static func icmpDestinationUnreachable(for original: IPv4Packet, code: UInt8) -> Data {
        var icmp = [UInt8](repeating: 0, count: 8)
        icmp[0] = 3
        icmp[1] = code
        icmp.append(contentsOf: original.icmpQuote)
        icmp.writeUInt16(internetChecksum(icmp), at: 2)
        return ipv4(
            sourceAddress: original.destinationAddress,
            destinationAddress: original.sourceAddress,
            protocolNumber: IPProtocolNumber.icmp,
            payload: icmp
        )
    }

    private static func ipv4(sourceAddress: UInt32, destinationAddress: UInt32, protocolNumber: UInt8, payload: [UInt8]) -> Data {
        var packet = [UInt8](repeating: 0, count: 20 + payload.count)
        packet[0] = 0x45
        packet[1] = 0
        packet.writeUInt16(UInt16(packet.count), at: 2)
        packet.writeUInt16(UInt16.random(in: 0...UInt16.max), at: 4)
        packet.writeUInt16(0x4000, at: 6)
        packet[8] = 64
        packet[9] = protocolNumber
        packet.writeUInt16(0, at: 10)
        packet.writeUInt32(sourceAddress, at: 12)
        packet.writeUInt32(destinationAddress, at: 16)
        packet.replaceSubrange(20..<packet.count, with: payload)
        packet.writeUInt16(internetChecksum(packet[0..<20]), at: 10)
        return Data(packet)
    }

    private static func transportChecksum(sourceAddress: UInt32, destinationAddress: UInt32, protocolNumber: UInt8, transport: [UInt8]) -> UInt16 {
        var pseudo = [UInt8]()
        pseudo.reserveCapacity(12 + transport.count + 1)
        pseudo.append(contentsOf: IPv4AddressFormatter.bytes(from: sourceAddress))
        pseudo.append(contentsOf: IPv4AddressFormatter.bytes(from: destinationAddress))
        pseudo.append(0)
        pseudo.append(protocolNumber)
        pseudo.append(contentsOf: UInt16(transport.count).bytes)
        pseudo.append(contentsOf: transport)
        return internetChecksum(pseudo)
    }

    private static func internetChecksum<S: Sequence>(_ bytes: S) -> UInt16 where S.Element == UInt8 {
        var sum: UInt32 = 0
        var iterator = bytes.makeIterator()
        while let high = iterator.next() {
            let low = iterator.next() ?? 0
            sum += (UInt32(high) << 8) | UInt32(low)
            while sum > 0xffff {
                sum = (sum & 0xffff) + (sum >> 16)
            }
        }
        return UInt16((~sum) & 0xffff)
    }
}

private enum DNSMessage {
    static func isAAAAQuestion(_ data: Data) -> Bool {
        guard let question = questionRangeAndType(in: data) else { return false }
        return question.type == 28
    }

    static func emptyNoErrorResponse(for query: Data) -> Data? {
        guard query.count >= 12,
              let flags = query.uint16(at: 2),
              let qdCount = query.uint16(at: 4),
              qdCount > 0,
              let question = questionRangeAndType(in: query)
        else {
            return nil
        }

        var response = [UInt8](repeating: 0, count: 12)
        response[0] = query[0]
        response[1] = query[1]
        let responseFlags = UInt16(0x8000) | (flags & 0x7900) | 0x0080
        response.writeUInt16(responseFlags, at: 2)
        response.writeUInt16(qdCount, at: 4)
        response.writeUInt16(0, at: 6)
        response.writeUInt16(0, at: 8)
        response.writeUInt16(0, at: 10)
        response.append(contentsOf: query[question.range])
        return Data(response)
    }

    private static func questionRangeAndType(in data: Data) -> (range: Range<Data.Index>, type: UInt16)? {
        guard data.count >= 12,
              let qdCount = data.uint16(at: 4),
              qdCount == 1
        else {
            return nil
        }

        var offset = 12
        while offset < data.count {
            let length = Int(data[offset])
            if (length & 0xC0) != 0 {
                return nil
            }
            offset += 1
            if length == 0 {
                break
            }
            guard offset + length <= data.count else {
                return nil
            }
            offset += length
        }

        guard offset + 4 <= data.count,
              let type = data.uint16(at: offset)
        else {
            return nil
        }
        return (12..<(offset + 4), type)
    }
}

private enum IPv4AddressFormatter {
    static func bytes(from address: UInt32) -> [UInt8] {
        [
            UInt8((address >> 24) & 0xff),
            UInt8((address >> 16) & 0xff),
            UInt8((address >> 8) & 0xff),
            UInt8(address & 0xff)
        ]
    }

    static func string(from address: UInt32) -> String {
        bytes(from: address).map(String.init).joined(separator: ".")
    }
}

private extension Data {
    func uint16(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 1 < count else { return nil }
        return (UInt16(self[offset]) << 8) | UInt16(self[offset + 1])
    }

    func uint32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 3 < count else { return nil }
        return (UInt32(self[offset]) << 24)
            | (UInt32(self[offset + 1]) << 16)
            | (UInt32(self[offset + 2]) << 8)
            | UInt32(self[offset + 3])
    }
}

private extension Array where Element == UInt8 {
    mutating func writeUInt16(_ value: UInt16, at offset: Int) {
        self[offset] = UInt8((value >> 8) & 0xff)
        self[offset + 1] = UInt8(value & 0xff)
    }

    mutating func writeUInt32(_ value: UInt32, at offset: Int) {
        self[offset] = UInt8((value >> 24) & 0xff)
        self[offset + 1] = UInt8((value >> 16) & 0xff)
        self[offset + 2] = UInt8((value >> 8) & 0xff)
        self[offset + 3] = UInt8(value & 0xff)
    }
}

private extension UInt16 {
    var bytes: [UInt8] {
        [UInt8((self >> 8) & 0xff), UInt8(self & 0xff)]
    }
}
