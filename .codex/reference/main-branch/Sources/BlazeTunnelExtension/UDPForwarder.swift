import Darwin
import Foundation

final class UDPForwarder: @unchecked Sendable {
    private let key: UDPFlowKey
    private let destination: SOCKS5Destination
    private let socksHost: String
    private let socksPort: Int
    private let packetWriter: @Sendable (Data) -> Void
    private let onClose: @Sendable (UDPFlowKey) -> Void
    private let queue: DispatchQueue
    private var association: SOCKS5UDPAssociation?
    private var connecting = false
    private var pendingPayloads: [Data] = []
    private var lastOriginalPacket: IPv4Packet?
    private var idleTimer: DispatchSourceTimer?
    private var lastActivity = DispatchTime.now().uptimeNanoseconds
    private var closed = false

    init(
        key: UDPFlowKey,
        destination: SOCKS5Destination,
        socksHost: String,
        socksPort: Int,
        packetWriter: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable (UDPFlowKey) -> Void
    ) {
        self.key = key
        self.destination = destination
        self.socksHost = socksHost
        self.socksPort = socksPort
        self.packetWriter = packetWriter
        self.onClose = onClose
        queue = DispatchQueue(label: "com.chenhuazhao.blaze.tunnel.udp.\(key.sourcePort).\(key.destinationPort)")
    }

    func handle(_ packet: UDPPacket, originalIPv4: IPv4Packet) {
        queue.async { [weak self] in
            self?.handleLocked(packet, originalIPv4: originalIPv4)
        }
    }

    func stop() {
        queue.sync {
            closeLocked(notify: false)
        }
    }

    private func handleLocked(_ packet: UDPPacket, originalIPv4: IPv4Packet) {
        guard !closed else { return }
        markActivityLocked()
        lastOriginalPacket = originalIPv4

        if let association {
            sendLocked(packet.payload, association: association)
            return
        }

        pendingPayloads.append(packet.payload)
        startAssociationLocked()
    }

    private func startAssociationLocked() {
        guard !connecting, association == nil else { return }
        connecting = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            do {
                let association = try SOCKS5UDPAssociation.connect(socksHost: self.socksHost, socksPort: self.socksPort)
                self.queue.async {
                    self.finishAssociationLocked(association)
                }
            } catch {
                self.queue.async {
                    self.sendICMPUnreachableForLastPacketLocked()
                    self.closeLocked(notify: true)
                }
            }
        }
    }

    private func finishAssociationLocked(_ association: SOCKS5UDPAssociation) {
        guard !closed else {
            association.close()
            return
        }

        self.association = association
        connecting = false
        markActivityLocked()
        startReadLoop(association)

        let payloads = pendingPayloads
        pendingPayloads.removeAll()
        for payload in payloads {
            sendLocked(payload, association: association)
        }
    }

    private func sendLocked(_ payload: Data, association: SOCKS5UDPAssociation) {
        guard let datagram = SOCKS5UDPDatagram.encode(destination: destination, destinationPort: key.destinationPort, payload: payload) else {
            sendICMPUnreachableForLastPacketLocked()
            closeLocked(notify: true)
            return
        }

        do {
            try association.send(datagram)
            markActivityLocked()
        } catch {
            sendICMPUnreachableForLastPacketLocked()
            closeLocked(notify: true)
        }
    }

    private func startReadLoop(_ association: SOCKS5UDPAssociation) {
        DispatchQueue.global(qos: .utility).async { [weak self, association] in
            guard let forwarder = self else { return }
            while !association.isClosed {
                do {
                    guard let data = try association.receive() else {
                        continue
                    }
                    forwarder.queue.async {
                        forwarder.handleResponseLocked(data)
                    }
                } catch {
                    forwarder.queue.async {
                        forwarder.closeLocked(notify: true)
                    }
                    return
                }
            }
        }
    }

    private func handleResponseLocked(_ data: Data) {
        guard !closed, let datagram = SOCKS5UDPDatagram.parse(data) else { return }
        let packet = IPv4PacketFactory.udp(
            sourceAddress: key.destinationAddress,
            destinationAddress: key.sourceAddress,
            sourcePort: key.destinationPort,
            destinationPort: key.sourcePort,
            payload: datagram.payload
        )
        packetWriter(packet)
        markActivityLocked()
    }

    private func sendICMPUnreachableForLastPacketLocked() {
        guard let lastOriginalPacket else { return }
        packetWriter(IPv4PacketFactory.icmpDestinationUnreachable(for: lastOriginalPacket, code: 3))
    }

    private func markActivityLocked() {
        lastActivity = DispatchTime.now().uptimeNanoseconds
        scheduleIdleTimerLocked()
    }

    private func scheduleIdleTimerLocked() {
        if idleTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [weak self] in
                self?.handleIdleTimerLocked()
            }
            idleTimer = timer
            timer.resume()
        }
        idleTimer?.schedule(deadline: .now() + .nanoseconds(Int(udpForwarderIdleTimeoutNanoseconds)))
    }

    private func handleIdleTimerLocked() {
        let now = DispatchTime.now().uptimeNanoseconds
        if now >= lastActivity + udpForwarderIdleTimeoutNanoseconds {
            closeLocked(notify: true)
        } else {
            scheduleIdleTimerLocked()
        }
    }

    private func closeLocked(notify: Bool) {
        guard !closed else { return }
        closed = true
        idleTimer?.cancel()
        idleTimer = nil
        association?.close()
        association = nil
        pendingPayloads.removeAll()
        if notify {
            onClose(key)
        }
    }
}

private let udpForwarderIdleTimeoutNanoseconds: UInt64 = 60 * 1_000_000_000

private final class SOCKS5UDPAssociation: @unchecked Sendable {
    private enum AssociationError: Error {
        case invalidEndpoint
        case socketFailed(Int32)
        case connectFailed(Int32)
        case handshakeFailed
        case associateRejected(UInt8)
    }

    private let lock = NSLock()
    private var tcpFD: Int32
    private var udpFD: Int32
    private var closed = false

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    private init(tcpFD: Int32, udpFD: Int32) {
        self.tcpFD = tcpFD
        self.udpFD = udpFD
    }

    static func connect(socksHost: String, socksPort: Int) throws -> SOCKS5UDPAssociation {
        guard socksHost == "127.0.0.1", (1...65_535).contains(socksPort) else {
            throw AssociationError.invalidEndpoint
        }

        let tcpFD = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard tcpFD >= 0 else {
            throw AssociationError.socketFailed(errno)
        }

        var timeout = timeval(tv_sec: 12, tv_usec: 0)
        setsockopt(tcpFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(tcpFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        do {
            try connectLoopback(fd: tcpFD, port: socksPort)
            try sendAll([0x05, 0x01, 0x00], fd: tcpFD)
            guard try recvExact(count: 2, fd: tcpFD) == [0x05, 0x00] else {
                throw AssociationError.handshakeFailed
            }

            try sendAll([0x05, 0x03, 0x00, 0x01, 0, 0, 0, 0, 0, 0], fd: tcpFD)
            let relayAddress = try readAssociateReply(fd: tcpFD, socksPort: socksPort)
            let udpFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard udpFD >= 0 else {
                throw AssociationError.socketFailed(errno)
            }

            var recvTimeout = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(udpFD, SOL_SOCKET, SO_RCVTIMEO, &recvTimeout, socklen_t(MemoryLayout<timeval>.size))

            var relaySockaddr = relayAddress
            let connected = withUnsafePointer(to: &relaySockaddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(udpFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == 0 else {
                let code = errno
                Darwin.close(udpFD)
                throw AssociationError.connectFailed(code)
            }
            return SOCKS5UDPAssociation(tcpFD: tcpFD, udpFD: udpFD)
        } catch {
            Darwin.close(tcpFD)
            throw error
        }
    }

    func send(_ data: Data) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            let result = Darwin.send(udpFD, baseAddress, data.count, 0)
            guard result == data.count else {
                throw AssociationError.handshakeFailed
            }
        }
    }

    func receive() throws -> Data? {
        if isClosed { return nil }
        var buffer = [UInt8](repeating: 0, count: 65_535)
        let count = buffer.withUnsafeMutableBytes { rawBuffer in
            Darwin.recv(udpFD, rawBuffer.baseAddress, rawBuffer.count, 0)
        }
        if count < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                return nil
            }
            if isClosed {
                return nil
            }
            throw AssociationError.handshakeFailed
        }
        if count == 0 {
            return nil
        }
        return Data(buffer.prefix(count))
    }

    func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        let tcp = tcpFD
        let udp = udpFD
        tcpFD = -1
        udpFD = -1
        lock.unlock()

        shutdown(tcp, SHUT_RDWR)
        Darwin.close(tcp)
        Darwin.close(udp)
    }

    private static func connectLoopback(fd: Int32, port: Int) throws {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr = in_addr(s_addr: UInt32(0x7f000001).bigEndian)

        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            throw AssociationError.connectFailed(errno)
        }
    }

    private static func readAssociateReply(fd: Int32, socksPort: Int) throws -> sockaddr_in {
        let head = try recvExact(count: 4, fd: fd)
        guard head[0] == 0x05 else {
            throw AssociationError.handshakeFailed
        }
        guard head[1] == 0x00 else {
            throw AssociationError.associateRejected(head[1])
        }
        guard head[3] == 0x01 else {
            throw AssociationError.handshakeFailed
        }

        let addressBytes = try recvExact(count: 4, fd: fd)
        let portBytes = try recvExact(count: 2, fd: fd)
        let port = UInt16(portBytes[0]) << 8 | UInt16(portBytes[1])
        guard port != 0 else {
            throw AssociationError.handshakeFailed
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        if addressBytes == [0, 0, 0, 0] {
            address.sin_addr = in_addr(s_addr: UInt32(0x7f000001).bigEndian)
        } else {
            address.sin_addr = in_addr(s_addr: UInt32(addressBytes[0]) << 24 | UInt32(addressBytes[1]) << 16 | UInt32(addressBytes[2]) << 8 | UInt32(addressBytes[3]))
            address.sin_addr.s_addr = address.sin_addr.s_addr.bigEndian
        }
        _ = socksPort
        return address
    }

    private static func sendAll(_ bytes: [UInt8], fd: Int32) throws {
        try bytes.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var sent = 0
            while sent < rawBuffer.count {
                let result = Darwin.send(fd, base.advanced(by: sent), rawBuffer.count - sent, 0)
                if result <= 0 {
                    throw AssociationError.handshakeFailed
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
                throw AssociationError.handshakeFailed
            }
            result.append(contentsOf: buffer[0..<received])
        }
        return result
    }
}
