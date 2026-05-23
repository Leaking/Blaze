import Darwin
import Foundation
@testable import BlazeTunnelExtension
import XCTest

final class UDPForwarderTests: XCTestCase {
    func testUDPForwarderRelaysSOCKS5UDPResponseIntoIPv4Packet() throws {
        let socks = try TinySOCKS5UDPAssociateServer()
        defer { socks.stop() }

        let sourceAddress: UInt32 = 0x0a000002
        let destinationAddress: UInt32 = 0x08080808
        let sourcePort: UInt16 = 53000
        let destinationPort: UInt16 = 443
        let payload = Data("udp-forwarder-ok".utf8)
        let packet = IPv4PacketFactory.udp(
            sourceAddress: sourceAddress,
            destinationAddress: destinationAddress,
            sourcePort: sourcePort,
            destinationPort: destinationPort,
            payload: payload
        )
        let ipv4 = try XCTUnwrap(IPv4Packet.parse(packet))
        let udp = try XCTUnwrap(UDPPacket.parse(ipv4: ipv4))

        let collector = PacketCollector()
        let received = expectation(description: "UDP response packet")
        let forwarder = UDPForwarder(
            key: UDPFlowKey(sourceAddress: sourceAddress, sourcePort: sourcePort, destinationAddress: destinationAddress, destinationPort: destinationPort),
            destination: .ipv4(destinationAddress),
            socksHost: "127.0.0.1",
            socksPort: socks.port,
            packetWriter: { packet in
                collector.append(packet)
                received.fulfill()
            },
            onClose: { _ in }
        )
        defer { forwarder.stop() }

        forwarder.handle(udp, originalIPv4: ipv4)

        wait(for: [received], timeout: 3.0)
        let response = try XCTUnwrap(collector.first())
        let responseIPv4 = try XCTUnwrap(IPv4Packet.parse(response))
        let responseUDP = try XCTUnwrap(UDPPacket.parse(ipv4: responseIPv4))
        XCTAssertEqual(responseIPv4.sourceAddress, destinationAddress)
        XCTAssertEqual(responseIPv4.destinationAddress, sourceAddress)
        XCTAssertEqual(responseUDP.sourcePort, destinationPort)
        XCTAssertEqual(responseUDP.destinationPort, sourcePort)
        XCTAssertEqual(responseUDP.payload, payload)
    }

    func testUDPForwarderEmitsICMPWhenSOCKSAssociationFails() throws {
        let unusedPort = try freeLoopbackTCPPort()
        let sourceAddress: UInt32 = 0x0a000002
        let destinationAddress: UInt32 = 0x08080808
        let sourcePort: UInt16 = 53000
        let destinationPort: UInt16 = 443
        let packet = IPv4PacketFactory.udp(
            sourceAddress: sourceAddress,
            destinationAddress: destinationAddress,
            sourcePort: sourcePort,
            destinationPort: destinationPort,
            payload: Data("udp-fail".utf8)
        )
        let ipv4 = try XCTUnwrap(IPv4Packet.parse(packet))
        let udp = try XCTUnwrap(UDPPacket.parse(ipv4: ipv4))

        let collector = PacketCollector()
        let received = expectation(description: "ICMP unreachable packet")
        let forwarder = UDPForwarder(
            key: UDPFlowKey(sourceAddress: sourceAddress, sourcePort: sourcePort, destinationAddress: destinationAddress, destinationPort: destinationPort),
            destination: .ipv4(destinationAddress),
            socksHost: "127.0.0.1",
            socksPort: unusedPort,
            packetWriter: { packet in
                collector.append(packet)
                received.fulfill()
            },
            onClose: { _ in }
        )
        defer { forwarder.stop() }

        forwarder.handle(udp, originalIPv4: ipv4)

        wait(for: [received], timeout: 3.0)
        let response = try XCTUnwrap(collector.first())
        let responseIPv4 = try XCTUnwrap(IPv4Packet.parse(response))
        XCTAssertEqual(responseIPv4.protocolNumber, IPProtocolNumber.icmp)
        XCTAssertEqual(responseIPv4.sourceAddress, destinationAddress)
        XCTAssertEqual(responseIPv4.destinationAddress, sourceAddress)
    }
}

private final class PacketCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var packets: [Data] = []

    func append(_ packet: Data) {
        lock.lock()
        packets.append(packet)
        lock.unlock()
    }

    func first() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return packets.first
    }
}

private final class TinySOCKS5UDPAssociateServer: @unchecked Sendable {
    let port: Int
    private let listenerFD: Int32
    private var controlFD: Int32 = -1
    private var udpFD: Int32 = -1
    private var task: Task<Void, Never>?
    private var udpTask: Task<Void, Never>?

    init() throws {
        let bound = try listenLoopbackSocket()
        listenerFD = bound.fd
        port = bound.port

        task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let clientFD = accept(self.listenerFD, nil, nil)
            guard clientFD >= 0 else { return }
            self.controlFD = clientFD

            do {
                let greeting = try recvExact(2, from: clientFD)
                guard greeting[0] == 0x05 else {
                    close(clientFD)
                    return
                }
                _ = try recvExact(Int(greeting[1]), from: clientFD)
                try sendAll(Data([0x05, 0x00]), to: clientFD)

                let requestHead = try recvExact(4, from: clientFD)
                guard requestHead[0] == 0x05, requestHead[1] == 0x03 else {
                    close(clientFD)
                    return
                }
                switch requestHead[3] {
                case 0x01:
                    _ = try recvExact(4, from: clientFD)
                case 0x03:
                    let length = try recvExact(1, from: clientFD)[0]
                    _ = try recvExact(Int(length), from: clientFD)
                case 0x04:
                    _ = try recvExact(16, from: clientFD)
                default:
                    close(clientFD)
                    return
                }
                _ = try recvExact(2, from: clientFD)

                let udp = try bindLoopbackUDPSocket()
                self.udpFD = udp.fd
                var reply = Data([0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1])
                reply.append(UInt8((udp.port >> 8) & 0xFF))
                reply.append(UInt8(udp.port & 0xFF))
                try sendAll(reply, to: clientFD)

                self.udpTask = Task.detached(priority: .utility) {
                    echoUDPDatagrams(fd: udp.fd)
                }

                var byte: UInt8 = 0
                while recv(clientFD, &byte, 1, 0) > 0 {}
            } catch {
                _ = try? sendAll(Data([0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0]), to: clientFD)
            }
            close(clientFD)
        }
    }

    func stop() {
        task?.cancel()
        udpTask?.cancel()
        if controlFD >= 0 {
            shutdown(controlFD, SHUT_RDWR)
            close(controlFD)
        }
        if udpFD >= 0 {
            close(udpFD)
        }
        shutdown(listenerFD, SHUT_RDWR)
        close(listenerFD)
    }
}

private struct BoundSocket {
    var fd: Int32
    var port: Int
}

private func listenLoopbackSocket() throws -> BoundSocket {
    let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    guard fd >= 0 else {
        throw POSIXError(.ENOTSOCK)
    }

    var enabled: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout<Int32>.size))

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

    let bindResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0 else {
        let saved = errno
        close(fd)
        throw POSIXError(POSIXErrorCode(rawValue: saved) ?? .EINVAL)
    }
    guard listen(fd, 16) == 0 else {
        let saved = errno
        close(fd)
        throw POSIXError(POSIXErrorCode(rawValue: saved) ?? .EINVAL)
    }
    return try boundTCPPort(fd: fd)
}

private func boundTCPPort(fd: Int32) throws -> BoundSocket {
    var bound = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let result = withUnsafeMutablePointer(to: &bound) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(fd, $0, &length)
        }
    }
    guard result == 0 else {
        throw POSIXError(.EINVAL)
    }
    return BoundSocket(fd: fd, port: Int(in_port_t(bigEndian: bound.sin_port)))
}

private func bindLoopbackUDPSocket() throws -> BoundSocket {
    let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    guard fd >= 0 else {
        throw POSIXError(.ENOTSOCK)
    }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

    let bindResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0 else {
        let saved = errno
        close(fd)
        throw POSIXError(POSIXErrorCode(rawValue: saved) ?? .EINVAL)
    }

    var bound = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let result = withUnsafeMutablePointer(to: &bound) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(fd, $0, &length)
        }
    }
    guard result == 0 else {
        close(fd)
        throw POSIXError(.EINVAL)
    }
    return BoundSocket(fd: fd, port: Int(in_port_t(bigEndian: bound.sin_port)))
}

private func freeLoopbackTCPPort() throws -> Int {
    let bound = try listenLoopbackSocket()
    close(bound.fd)
    return bound.port
}

private func echoUDPDatagrams(fd: Int32) {
    var buffer = [UInt8](repeating: 0, count: 65_535)
    while !Task.isCancelled {
        var clientAddress = sockaddr_storage()
        var clientLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let count = withUnsafeMutablePointer(to: &clientAddress) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                buffer.withUnsafeMutableBytes { rawBuffer in
                    recvfrom(fd, rawBuffer.baseAddress, rawBuffer.count, 0, sockaddrPointer, &clientLength)
                }
            }
        }
        guard count > 0 else { break }
        _ = withUnsafePointer(to: &clientAddress) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                buffer.withUnsafeBytes { rawBuffer in
                    sendto(fd, rawBuffer.baseAddress, count, 0, sockaddrPointer, clientLength)
                }
            }
        }
    }
}

private func sendAll(_ data: Data, to fd: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return }
        var sent = 0
        while sent < data.count {
            let count = send(fd, baseAddress.advanced(by: sent), data.count - sent, 0)
            guard count > 0 else {
                throw POSIXError(.EIO)
            }
            sent += count
        }
    }
}

private func recvExact(_ byteCount: Int, from fd: Int32) throws -> [UInt8] {
    var result: [UInt8] = []
    result.reserveCapacity(byteCount)
    while result.count < byteCount {
        var buffer = [UInt8](repeating: 0, count: byteCount - result.count)
        let count = recv(fd, &buffer, buffer.count, 0)
        guard count > 0 else {
            throw POSIXError(.EIO)
        }
        result.append(contentsOf: buffer.prefix(count))
    }
    return result
}
