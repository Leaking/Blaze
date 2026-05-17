import Darwin
import Foundation
@preconcurrency import NetworkExtension
import os.log

struct PacketTunnelRuntimeConfiguration {
    var httpHost: String
    var httpPort: Int
    var socksHost: String
    var socksPort: Int
    var dnsOverHTTPSURL: URL
    var excludedIPv4Addresses: [String]
    var suppressIPv6DNS: Bool
    var enableFakeIPDNS: Bool
    var enableUDPRelay: Bool
    var enableProxySettings: Bool
    var enableDNSNetworkFallback: Bool
    var enableIPv6Blackhole: Bool

    init(providerConfiguration: [String: Any]?) {
        httpHost = providerConfiguration?["httpHost"] as? String ?? "127.0.0.1"
        httpPort = providerConfiguration?["httpPort"] as? Int ?? 19080
        socksHost = providerConfiguration?["socksHost"] as? String ?? "127.0.0.1"
        socksPort = providerConfiguration?["socksPort"] as? Int ?? 19081
        let dnsURL = providerConfiguration?["dnsOverHTTPSURL"] as? String ?? "https://1.1.1.1/dns-query"
        dnsOverHTTPSURL = URL(string: dnsURL) ?? URL(string: "https://1.1.1.1/dns-query")!
        excludedIPv4Addresses = providerConfiguration?["excludedIPv4Addresses"] as? [String] ?? []
        suppressIPv6DNS = providerConfiguration?["suppressIPv6DNS"] as? Bool ?? true
        enableFakeIPDNS = providerConfiguration?["enableFakeIPDNS"] as? Bool ?? true
        enableUDPRelay = providerConfiguration?["enableUDPRelay"] as? Bool ?? false
        enableProxySettings = providerConfiguration?["enableProxySettings"] as? Bool ?? false
        enableDNSNetworkFallback = providerConfiguration?["enableDNSNetworkFallback"] as? Bool ?? false
        enableIPv6Blackhole = providerConfiguration?["enableIPv6Blackhole"] as? Bool ?? true
    }
}

struct PacketTunnelDiagnostics: Codable, Equatable, Sendable {
    var packetsRead: UInt64 = 0
    var ipv4Packets: UInt64 = 0
    var ipv6Packets: UInt64 = 0
    var unknownPackets: UInt64 = 0
    var tcpPackets: UInt64 = 0
    var udpPackets: UInt64 = 0
    var dnsQueries: UInt64 = 0
    var fakeIPTCPDestinations: UInt64 = 0
    var fakeIPUDPDestinations: UInt64 = 0
    var udpRelayedPackets: UInt64 = 0
    var udpRejectedPackets: UInt64 = 0
    var ipv6BlackholedPackets: UInt64 = 0
    var activeTCPFlows: Int = 0
    var activeUDPFlows: Int = 0
    var fakeIPMappings: Int = 0
    var tcpFlowsOpened: UInt64 = 0
    var tcpFlowsClosed: UInt64 = 0
    var tcpSocksConnectAttempts: UInt64 = 0
    var tcpSocksConnectSuccesses: UInt64 = 0
    var tcpSocksConnectFailures: UInt64 = 0
    var tcpClientBytesReceived: UInt64 = 0
    var tcpUpstreamBytesSent: UInt64 = 0
    var tcpUpstreamBytesReceived: UInt64 = 0
    var tcpClientBytesSent: UInt64 = 0
    var tcpPacketsWritten: UInt64 = 0
    var tcpRetransmittedPackets: UInt64 = 0
    var tcpResetsSent: UInt64 = 0
    var tcpPendingWriteOverflows: UInt64 = 0
    var tcpOutboundBufferOverflows: UInt64 = 0
    var tcpWindowStalls: UInt64 = 0
    var tcpUpstreamCloses: UInt64 = 0
}

final class PacketTunnelEngine: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.chenhuazhao.blaze.tunnel", category: "PacketTunnelEngine")
    private let packetFlow: NEPacketTunnelFlow
    private let configuration: PacketTunnelRuntimeConfiguration
    private let queue = DispatchQueue(label: "com.chenhuazhao.blaze.tunnel.engine")
    private let packetWriteQueue = DispatchQueue(label: "com.chenhuazhao.blaze.tunnel.packet-writer")
    private let dnsProxy: DNSOverHTTPSProxy
    private let fakeIPStore = DNSFakeIPStore()
    private var flows: [TCPFlowKey: TCPForwarder] = [:]
    private var udpFlows: [UDPFlowKey: UDPForwarder] = [:]
    private var diagnostics = PacketTunnelDiagnostics()
    private var stopped = false

    init(packetFlow: NEPacketTunnelFlow, configuration: PacketTunnelRuntimeConfiguration) {
        self.packetFlow = packetFlow
        self.configuration = configuration
        dnsProxy = DNSOverHTTPSProxy(
            url: configuration.dnsOverHTTPSURL,
            httpProxyHost: configuration.httpHost,
            httpProxyPort: configuration.httpPort,
            suppressIPv6DNS: configuration.suppressIPv6DNS,
            enableFakeIPDNS: configuration.enableFakeIPDNS,
            enableNetworkFallback: configuration.enableDNSNetworkFallback,
            fakeIPStore: fakeIPStore
        )
    }

    func handlePackets(_ packets: [Data], protocols: [NSNumber]) {
        guard !packets.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.diagnostics.packetsRead &+= UInt64(packets.count)
            for packet in packets {
                self.handlePacket(packet)
            }
        }
    }

    func stop() {
        queue.sync {
            stopped = true
            let activeFlows = flows.values
            let activeUDPFlows = udpFlows.values
            flows.removeAll()
            udpFlows.removeAll()
            activeFlows.forEach { $0.stop() }
            activeUDPFlows.forEach { $0.stop() }
        }
    }

    func diagnosticsSnapshot() -> PacketTunnelDiagnostics {
        queue.sync {
            var snapshot = diagnostics
            snapshot.activeTCPFlows = flows.count
            snapshot.activeUDPFlows = udpFlows.count
            snapshot.fakeIPMappings = fakeIPStore.mappingCount()
            return snapshot
        }
    }

    private func handlePacket(_ packet: Data) {
        if let ipv4 = IPv4Packet.parse(packet) {
            diagnostics.ipv4Packets &+= 1
            handleIPv4(ipv4)
            return
        }

        if configuration.enableIPv6Blackhole, let ipv6 = IPv6Packet.parse(packet) {
            diagnostics.ipv6Packets &+= 1
            diagnostics.ipv6BlackholedPackets &+= 1
            writeIPv6Packet(IPv6PacketFactory.icmpDestinationUnreachable(for: ipv6, originalPacket: packet, code: 1))
            return
        }

        diagnostics.unknownPackets &+= 1
    }

    private func handleIPv4(_ ipv4: IPv4Packet) {
        switch ipv4.protocolNumber {
        case IPProtocolNumber.tcp:
            guard let tcp = TCPPacket.parse(ipv4: ipv4) else { return }
            diagnostics.tcpPackets &+= 1
            handleTCP(ipv4: ipv4, tcp: tcp)
        case IPProtocolNumber.udp:
            guard let udp = UDPPacket.parse(ipv4: ipv4) else { return }
            diagnostics.udpPackets &+= 1
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
            let mappedDomain = fakeIPStore.domain(for: ipv4.destinationAddress)
            if mappedDomain != nil {
                diagnostics.fakeIPTCPDestinations &+= 1
            }
            let destination = mappedDomain
                .map { SOCKS5Destination.domain($0) }
                ?? .ipv4(ipv4.destinationAddress)
            flow = TCPForwarder(
                key: key,
                destination: destination,
                socksHost: configuration.socksHost,
                socksPort: configuration.socksPort,
                packetWriter: { [weak self] packet in
                    self?.writeIPv4Packet(packet)
                },
                eventHandler: { [weak self] event in
                    self?.recordTCPEvent(event)
                },
                onClose: { [weak self] flowKey in
                    self?.removeFlow(flowKey)
                }
            )
            flows[key] = flow
            diagnostics.tcpFlowsOpened &+= 1
        } else {
            return
        }

        flow.handle(tcp)
    }

    private func handleUDP(ipv4: IPv4Packet, udp: UDPPacket) {
        if udp.destinationPort == 53 {
            diagnostics.dnsQueries &+= 1
            dnsProxy.handleQuery(ipv4: ipv4, udp: udp) { [weak self] packet in
                self?.writeIPv4Packet(packet)
            }
            return
        }

        if configuration.enableUDPRelay {
            diagnostics.udpRelayedPackets &+= 1
            forwardUDP(ipv4: ipv4, udp: udp)
            return
        }

        diagnostics.udpRejectedPackets &+= 1
        logger.debug("Rejecting unsupported UDP \(IPv4AddressFormatter.string(from: ipv4.sourceAddress), privacy: .public):\(udp.sourcePort, privacy: .public) -> \(IPv4AddressFormatter.string(from: ipv4.destinationAddress), privacy: .public):\(udp.destinationPort, privacy: .public)")
        writeIPv4Packet(IPv4PacketFactory.icmpDestinationUnreachable(for: ipv4, code: 3))
    }

    private func forwardUDP(ipv4: IPv4Packet, udp: UDPPacket) {
        let key = UDPFlowKey(
            sourceAddress: ipv4.sourceAddress,
            sourcePort: udp.sourcePort,
            destinationAddress: ipv4.destinationAddress,
            destinationPort: udp.destinationPort
        )
        let flow: UDPForwarder
        if let existing = udpFlows[key] {
            flow = existing
        } else {
            let mappedDomain = fakeIPStore.domain(for: ipv4.destinationAddress)
            if mappedDomain != nil {
                diagnostics.fakeIPUDPDestinations &+= 1
            }
            let destination = mappedDomain
                .map { SOCKS5Destination.domain($0) }
                ?? .ipv4(ipv4.destinationAddress)
            flow = UDPForwarder(
                key: key,
                destination: destination,
                socksHost: configuration.socksHost,
                socksPort: configuration.socksPort,
                packetWriter: { [weak self] packet in
                    self?.writeIPv4Packet(packet)
                },
                onClose: { [weak self] flowKey in
                    self?.removeUDPFlow(flowKey)
                }
            )
            udpFlows[key] = flow
        }

        flow.handle(udp, originalIPv4: ipv4)
    }

    private func writeIPv4Packet(_ packet: Data) {
        packetWriteQueue.async { [packetFlow] in
            _ = packetFlow.writePackets([packet], withProtocols: [NSNumber(value: AF_INET)])
        }
    }

    private func writeIPv6Packet(_ packet: Data) {
        packetWriteQueue.async { [packetFlow] in
            _ = packetFlow.writePackets([packet], withProtocols: [NSNumber(value: AF_INET6)])
        }
    }

    private func removeFlow(_ key: TCPFlowKey) {
        queue.async { [weak self] in
            self?.flows.removeValue(forKey: key)
        }
    }

    private func removeUDPFlow(_ key: UDPFlowKey) {
        queue.async { [weak self] in
            self?.udpFlows.removeValue(forKey: key)
        }
    }

    private func recordTCPEvent(_ event: TCPForwarderEvent) {
        queue.async { [weak self] in
            guard let self else { return }
            switch event {
            case .flowClosed:
                self.diagnostics.tcpFlowsClosed &+= 1
            case .socksConnectAttempt:
                self.diagnostics.tcpSocksConnectAttempts &+= 1
            case .socksConnectSucceeded:
                self.diagnostics.tcpSocksConnectSuccesses &+= 1
            case .socksConnectFailed:
                self.diagnostics.tcpSocksConnectFailures &+= 1
            case .clientPayloadReceived(let byteCount):
                self.diagnostics.tcpClientBytesReceived &+= UInt64(byteCount)
            case .upstreamPayloadSent(let byteCount):
                self.diagnostics.tcpUpstreamBytesSent &+= UInt64(byteCount)
            case .upstreamPayloadReceived(let byteCount):
                self.diagnostics.tcpUpstreamBytesReceived &+= UInt64(byteCount)
            case .clientPayloadSent(let byteCount):
                self.diagnostics.tcpClientBytesSent &+= UInt64(byteCount)
            case .packetWritten:
                self.diagnostics.tcpPacketsWritten &+= 1
            case .packetRetransmitted:
                self.diagnostics.tcpRetransmittedPackets &+= 1
            case .resetSent:
                self.diagnostics.tcpResetsSent &+= 1
            case .pendingWriteOverflow:
                self.diagnostics.tcpPendingWriteOverflows &+= 1
            case .outboundBufferOverflow:
                self.diagnostics.tcpOutboundBufferOverflows &+= 1
            case .windowStall:
                self.diagnostics.tcpWindowStalls &+= 1
            case .upstreamClosed:
                self.diagnostics.tcpUpstreamCloses &+= 1
            }
        }
    }
}

private enum TCPForwarderEvent: Sendable {
    case flowClosed
    case socksConnectAttempt
    case socksConnectSucceeded
    case socksConnectFailed
    case clientPayloadReceived(Int)
    case upstreamPayloadSent(Int)
    case upstreamPayloadReceived(Int)
    case clientPayloadSent(Int)
    case packetWritten
    case packetRetransmitted
    case resetSent
    case pendingWriteOverflow
    case outboundBufferOverflow
    case windowStall
    case upstreamClosed
}

enum IPProtocolNumber {
    static let icmp: UInt8 = 1
    static let tcp: UInt8 = 6
    static let udp: UInt8 = 17
    static let icmpv6: UInt8 = 58
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

struct IPv4Packet: Sendable {
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

struct TCPFlags: OptionSet, Sendable {
    let rawValue: UInt8

    static let fin = TCPFlags(rawValue: 0x01)
    static let syn = TCPFlags(rawValue: 0x02)
    static let reset = TCPFlags(rawValue: 0x04)
    static let push = TCPFlags(rawValue: 0x08)
    static let ack = TCPFlags(rawValue: 0x10)
}

struct TCPOptions: Equatable, Sendable {
    var maxSegmentSize: Int?
    var windowScale: UInt8?
    var sackPermitted: Bool

    static func parse(_ data: Data) -> TCPOptions {
        var result = TCPOptions(maxSegmentSize: nil, windowScale: nil, sackPermitted: false)
        var index = 0

        while index < data.count {
            let kind = data[index]
            switch kind {
            case 0:
                return result
            case 1:
                index += 1
                continue
            default:
                guard index + 1 < data.count else { return result }
                let length = Int(data[index + 1])
                guard length >= 2, index + length <= data.count else { return result }
                let option = data.subdata(in: index..<(index + length))
                switch kind {
                case 2 where length == 4:
                    result.maxSegmentSize = Int(option.uint16(at: 2) ?? 0)
                case 3 where length == 3:
                    result.windowScale = min(option[2], 14)
                case 4 where length == 2:
                    result.sackPermitted = true
                default:
                    break
                }
                index += length
            }
        }

        return result
    }

    static func synAckOptions(maxSegmentSize: Int, windowScale: UInt8?, sackPermitted: Bool) -> [UInt8] {
        var options: [UInt8] = []
        options.append(2)
        options.append(4)
        options.append(contentsOf: UInt16(min(max(maxSegmentSize, 536), 9_000)).bytes)
        if sackPermitted {
            options.append(4)
            options.append(2)
        }
        if let windowScale {
            options.append(3)
            options.append(3)
            options.append(min(windowScale, 14))
        }
        options.append(0)
        while options.count % 4 != 0 {
            options.append(0)
        }
        return options
    }
}

private struct TCPPacket: Sendable {
    var sourcePort: UInt16
    var destinationPort: UInt16
    var sequenceNumber: UInt32
    var acknowledgmentNumber: UInt32
    var flags: TCPFlags
    var window: UInt16
    var options: TCPOptions
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
        let options = TCPOptions.parse(data.subdata(in: 20..<headerLength))
        return TCPPacket(
            sourcePort: sourcePort,
            destinationPort: destinationPort,
            sequenceNumber: sequenceNumber,
            acknowledgmentNumber: acknowledgmentNumber,
            flags: TCPFlags(rawValue: data[13]),
            window: window,
            options: options,
            payload: data.subdata(in: headerLength..<data.count)
        )
    }
}

struct UDPPacket: Sendable {
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
    private let destination: SOCKS5Destination
    private let socksHost: String
    private let socksPort: Int
    private let packetWriter: @Sendable (Data) -> Void
    private let eventHandler: @Sendable (TCPForwarderEvent) -> Void
    private let onClose: @Sendable (TCPFlowKey) -> Void
    private let queue: DispatchQueue
    private var activityDeadline = TCPActivityDeadline(timeoutNanos: 120_000_000_000)
    private var idleTimer: DispatchSourceTimer?
    private var state: State = .new
    private var socketFD: Int32 = -1
    private var connecting = false
    private var clientNextSequence: UInt32 = 0
    private let serverInitialSequence: UInt32
    private var serverSequence: UInt32
    private var clientAdvertisedWindow: UInt32 = 65_535
    private var clientWindowScale: UInt8 = 0
    private var clientMaximumSegmentSize = 1360
    private var serverWindowScale: UInt8?
    private var serverSACKPermitted = false
    private var inboundReassembler = TCPInboundReassembler(maxBufferedBytes: 512 * 1024)
    private var outboundTracker = TCPOutboundSegmentTracker(maxRetainedBytes: 512 * 1024)
    private var pendingWrites = TCPPendingWriteBuffer(maxBufferedBytes: 512 * 1024)
    private var pendingOutboundData = TCPByteBuffer(maxBufferedBytes: 1024 * 1024)
    private var upstreamClosePending = false
    private var retransmissionTimer: DispatchSourceTimer?
    private var pendingFINSequence: UInt32?

    init(
        key: TCPFlowKey,
        destination: SOCKS5Destination,
        socksHost: String,
        socksPort: Int,
        packetWriter: @escaping @Sendable (Data) -> Void,
        eventHandler: @escaping @Sendable (TCPForwarderEvent) -> Void,
        onClose: @escaping @Sendable (TCPFlowKey) -> Void
    ) {
        self.key = key
        self.destination = destination
        self.socksHost = socksHost
        self.socksPort = socksPort
        self.packetWriter = packetWriter
        self.eventHandler = eventHandler
        self.onClose = onClose
        let initialSequence = UInt32.random(in: 1...UInt32.max)
        serverInitialSequence = initialSequence
        serverSequence = initialSequence
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
        markActivityLocked()

        if packet.flags.contains(.reset) {
            closeLocked(notify: true)
            return
        }

        if packet.flags.contains(.syn) {
            handleSYN(packet)
            return
        }

        guard state != .new else { return }
        updateClientWindowLocked(packet)

        if packet.flags.contains(.ack) {
            handleACKLocked(packet.acknowledgmentNumber)
            flushOutboundDataLocked()
        }

        var shouldAcknowledgePayload = false
        if !packet.payload.isEmpty {
            switch inboundReassembler.insert(
                sequenceNumber: packet.sequenceNumber,
                payload: packet.payload,
                nextSequence: &clientNextSequence
            ) {
            case .accepted(let payloads):
                shouldAcknowledgePayload = true
                for payload in payloads {
                    eventHandler(.clientPayloadReceived(payload.count))
                    writeOrBufferLocked(payload)
                }
            case .overflow:
                sendSegmentLocked(flags: [.reset, .ack], payload: Data(), advanceSequence: false)
                closeLocked(notify: true)
                return
            }
        }

        let consumedPendingFIN = consumePendingFINIfReadyLocked()

        if packet.flags.contains(.fin) {
            handleFINLocked(sequenceNumber: packet.sequenceNumber, payloadLength: packet.payload.count)
            shouldAcknowledgePayload = false
        } else if consumedPendingFIN {
            shouldAcknowledgePayload = false
        }

        if shouldAcknowledgePayload {
            sendACKLocked()
        }
    }

    private func handleSYN(_ packet: TCPPacket) {
        switch state {
        case .new:
            clientNextSequence = packet.sequenceNumber &+ 1
            clientWindowScale = packet.options.windowScale ?? 0
            clientMaximumSegmentSize = max(536, min(packet.options.maxSegmentSize ?? 1360, 1360))
            serverWindowScale = packet.options.windowScale == nil ? nil : 0
            serverSACKPermitted = packet.options.sackPermitted
            updateClientWindowLocked(packet)
            state = .synReceived
            sendSegmentLocked(flags: [.syn, .ack], payload: Data())
            startUpstreamLocked()
        case .synReceived, .established:
            sendSegmentLocked(flags: [.syn, .ack], payload: Data(), advanceSequence: false, sequenceNumberOverride: serverInitialSequence)
        case .closing, .closed:
            break
        }
    }

    private func handleACKLocked(_ acknowledgmentNumber: UInt32) {
        switch outboundTracker.acknowledge(acknowledgmentNumber) {
        case .progress:
            if outboundTracker.isEmpty {
                stopRetransmissionTimerLocked()
                finishPendingUpstreamCloseIfPossibleLocked()
                if state == .closing, socketFD < 0 {
                    closeLocked(notify: true)
                }
            }
        case .duplicate(let count):
            guard count >= 3,
                  let segment = outboundTracker.nextDuplicateAckRetransmission(at: DispatchTime.now().uptimeNanoseconds)
            else {
                return
            }
            retransmitSegmentLocked(segment)
        case .ignored:
            break
        }
    }

    private func startUpstreamLocked() {
        guard !connecting, socketFD < 0 else { return }
        connecting = true
        eventHandler(.socksConnectAttempt)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let fd = try SOCKS5Connector.connect(
                    socksHost: self.socksHost,
                    socksPort: self.socksPort,
                    destination: self.destination,
                    destinationPort: self.key.destinationPort
                )
                self.queue.async {
                    self.eventHandler(.socksConnectSucceeded)
                    self.finishUpstreamConnectLocked(fd: fd)
                }
            } catch {
                self.queue.async {
                    self.eventHandler(.socksConnectFailed)
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
        markActivityLocked()
        socketFD = fd
        connecting = false
        if state == .synReceived {
            state = .established
        }

        let buffered = pendingWrites.drain()
        for payload in buffered {
            guard writeSocketLocked(payload) else { return }
        }
        if state == .closing {
            shutdown(fd, SHUT_WR)
        }
        startReadLoop(fd: fd)
    }

    private func handleFINLocked(sequenceNumber: UInt32, payloadLength: Int) {
        let finSequence = sequenceNumber &+ UInt32(payloadLength)
        if finSequence == clientNextSequence {
            acceptFINLocked()
        } else if tcpSequenceLessThan(finSequence, clientNextSequence) {
            sendACKLocked()
        } else {
            pendingFINSequence = finSequence
            sendACKLocked()
        }
    }

    @discardableResult
    private func consumePendingFINIfReadyLocked() -> Bool {
        guard let pendingFINSequence, pendingFINSequence == clientNextSequence else {
            return false
        }
        acceptFINLocked()
        return true
    }

    private func acceptFINLocked() {
        pendingFINSequence = nil
        clientNextSequence = clientNextSequence &+ 1
        sendACKLocked()
        if socketFD >= 0 {
            shutdown(socketFD, SHUT_WR)
        }
        if state != .closed {
            state = .closing
        }
    }

    private func writeOrBufferLocked(_ payload: Data) {
        guard !payload.isEmpty else { return }
        if socketFD >= 0 {
            _ = writeSocketLocked(payload)
        } else {
            guard pendingWrites.append(payload) else {
                eventHandler(.pendingWriteOverflow)
                sendSegmentLocked(flags: [.reset, .ack], payload: Data(), advanceSequence: false)
                closeLocked(notify: true)
                return
            }
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
        } else {
            eventHandler(.upstreamPayloadSent(payload.count))
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
            self.markActivityLocked()
            self.eventHandler(.upstreamPayloadReceived(data.count))
            guard self.pendingOutboundData.append(data) else {
                self.eventHandler(.outboundBufferOverflow)
                self.sendSegmentLocked(flags: [.reset, .ack], payload: Data(), advanceSequence: false)
                self.closeLocked(notify: true)
                return
            }
            self.flushOutboundDataLocked()
        }
    }

    private func handleUpstreamClosed() {
        queue.async { [weak self] in
            guard let self, self.state != .closed else { return }
            self.markActivityLocked()
            if self.socketFD >= 0 {
                Darwin.close(self.socketFD)
                self.socketFD = -1
            }
            self.eventHandler(.upstreamClosed)
            self.upstreamClosePending = true
            self.finishPendingUpstreamCloseIfPossibleLocked()
        }
    }

    private func sendACKLocked() {
        sendSegmentLocked(flags: [.ack], payload: Data(), advanceSequence: false)
    }

    private func updateClientWindowLocked(_ packet: TCPPacket) {
        clientAdvertisedWindow = UInt32(packet.window) << UInt32(clientWindowScale)
    }

    private func sendSegmentLocked(
        flags: TCPFlags,
        payload: Data,
        advanceSequence: Bool = true,
        sequenceNumberOverride: UInt32? = nil
    ) {
        let sequenceNumber = sequenceNumberOverride ?? serverSequence
        let options = flags.contains(.syn)
            ? Data(TCPOptions.synAckOptions(maxSegmentSize: 1360, windowScale: serverWindowScale, sackPermitted: serverSACKPermitted))
            : Data()
        let packet = IPv4PacketFactory.tcp(
            sourceAddress: key.destinationAddress,
            destinationAddress: key.sourceAddress,
            sourcePort: key.destinationPort,
            destinationPort: key.sourcePort,
            sequenceNumber: sequenceNumber,
            acknowledgmentNumber: clientNextSequence,
            flags: flags,
            window: advertisedReceiveWindowLocked(),
            options: options,
            payload: payload
        )
        packetWriter(packet)
        eventHandler(.packetWritten)
        if !payload.isEmpty {
            eventHandler(.clientPayloadSent(payload.count))
        }
        if flags.contains(.reset) {
            eventHandler(.resetSent)
        }

        guard advanceSequence else { return }
        let increment = TCPOutboundSegmentTracker.sequenceLength(flags: flags, payloadLength: payload.count)
        if increment > 0 {
            guard outboundTracker.record(
                sequenceNumber: sequenceNumber,
                flags: flags,
                options: options,
                payload: payload,
                sentAt: DispatchTime.now().uptimeNanoseconds
            ) else {
                closeLocked(notify: true)
                return
            }
            startRetransmissionTimerLocked()
        }
        serverSequence = serverSequence &+ increment
    }

    private func retransmitSegmentLocked(_ segment: TCPOutboundSegmentTracker.SegmentSnapshot) {
        let packet = IPv4PacketFactory.tcp(
            sourceAddress: key.destinationAddress,
            destinationAddress: key.sourceAddress,
            sourcePort: key.destinationPort,
            destinationPort: key.sourcePort,
            sequenceNumber: segment.sequenceNumber,
            acknowledgmentNumber: clientNextSequence,
            flags: segment.flags,
            window: advertisedReceiveWindowLocked(),
            options: segment.options,
            payload: segment.payload
        )
        packetWriter(packet)
        eventHandler(.packetWritten)
        eventHandler(.packetRetransmitted)
        if !segment.payload.isEmpty {
            eventHandler(.clientPayloadSent(segment.payload.count))
        }
    }

    private func flushOutboundDataLocked() {
        guard state != .closed else { return }
        while !pendingOutboundData.isEmpty {
            let availableWindow = clientAdvertisedWindow > outboundTracker.inFlightSequenceLength
                ? clientAdvertisedWindow - outboundTracker.inFlightSequenceLength
                : 0
            guard availableWindow > 0 else {
                eventHandler(.windowStall)
                break
            }
            let chunkSize = min(clientMaximumSegmentSize, Int(availableWindow), pendingOutboundData.count)
            guard chunkSize > 0, let chunk = pendingOutboundData.popPrefix(chunkSize) else {
                eventHandler(.windowStall)
                break
            }
            sendSegmentLocked(flags: [.push, .ack], payload: chunk)
            guard state != .closed else { return }
        }
        finishPendingUpstreamCloseIfPossibleLocked()
    }

    private func finishPendingUpstreamCloseIfPossibleLocked() {
        guard upstreamClosePending, pendingOutboundData.isEmpty else { return }
        upstreamClosePending = false
        sendSegmentLocked(flags: [.fin, .ack], payload: Data())
        if outboundTracker.isEmpty {
            closeLocked(notify: true)
        } else {
            state = .closing
            startRetransmissionTimerLocked()
        }
    }

    private func startRetransmissionTimerLocked() {
        guard retransmissionTimer == nil, !outboundTracker.isEmpty else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.handleRetransmissionTimerLocked()
        }
        retransmissionTimer = timer
        timer.resume()
    }

    private func stopRetransmissionTimerLocked() {
        retransmissionTimer?.cancel()
        retransmissionTimer = nil
    }

    private func markActivityLocked() {
        activityDeadline.markActivity(at: DispatchTime.now().uptimeNanoseconds)
        startIdleTimerLocked()
    }

    private func startIdleTimerLocked() {
        guard idleTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(30), repeating: .seconds(30))
        timer.setEventHandler { [weak self] in
            self?.handleIdleTimerLocked()
        }
        idleTimer = timer
        timer.resume()
    }

    private func stopIdleTimerLocked() {
        idleTimer?.cancel()
        idleTimer = nil
    }

    private func handleIdleTimerLocked() {
        guard state != .closed else {
            stopIdleTimerLocked()
            return
        }
        guard activityDeadline.isExpired(at: DispatchTime.now().uptimeNanoseconds) else { return }
        sendSegmentLocked(flags: [.reset, .ack], payload: Data(), advanceSequence: false)
        closeLocked(notify: true)
    }

    private func handleRetransmissionTimerLocked() {
        guard state != .closed else {
            stopRetransmissionTimerLocked()
            return
        }

        if outboundTracker.isEmpty {
            stopRetransmissionTimerLocked()
            if state == .closing, socketFD < 0 {
                closeLocked(notify: true)
            }
            return
        }

        let now = DispatchTime.now().uptimeNanoseconds
        guard let segment = outboundTracker.nextTimedOutRetransmission(at: now) else { return }
        retransmitSegmentLocked(segment)
    }

    private func advertisedReceiveWindowLocked() -> UInt16 {
        UInt16(min(65_535, inboundReassembler.availableByteCount, pendingWrites.availableByteCount))
    }

    private func closeLocked(notify: Bool) {
        guard state != .closed else { return }
        state = .closed
        stopIdleTimerLocked()
        stopRetransmissionTimerLocked()
        if socketFD >= 0 {
            Darwin.close(socketFD)
            socketFD = -1
        }
        pendingWrites.removeAll()
        pendingOutboundData.removeAll()
        upstreamClosePending = false
        eventHandler(.flowClosed)
        if notify {
            onClose(key)
        }
    }
}

struct TCPActivityDeadline {
    private let timeoutNanos: UInt64
    private var lastActivity: UInt64

    init(timeoutNanos: UInt64, now: UInt64 = 0) {
        self.timeoutNanos = timeoutNanos
        lastActivity = now
    }

    mutating func markActivity(at now: UInt64) {
        lastActivity = now
    }

    func isExpired(at now: UInt64) -> Bool {
        now >= lastActivity + timeoutNanos
    }
}

struct TCPOutboundSegmentTracker {
    enum AckResult: Equatable {
        case progress
        case duplicate(Int)
        case ignored
    }

    struct SegmentSnapshot: Equatable {
        var sequenceNumber: UInt32
        var flags: TCPFlags
        var options: Data
        var payload: Data
    }

    private struct Segment {
        var sequenceNumber: UInt32
        var flags: TCPFlags
        var options: Data
        var payload: Data
        var sentAt: UInt64
        var retransmissionCount: Int = 0

        var length: UInt32 {
            TCPOutboundSegmentTracker.sequenceLength(flags: flags, payloadLength: payload.count)
        }

        var endSequence: UInt32 {
            sequenceNumber &+ length
        }

        var snapshot: SegmentSnapshot {
            SegmentSnapshot(sequenceNumber: sequenceNumber, flags: flags, options: options, payload: payload)
        }
    }

    private static let retransmissionTimeoutNanos: UInt64 = 1_500_000_000
    private let maxRetainedBytes: Int
    private var segments: [Segment] = []
    private var retainedBytes = 0
    private var lastAcknowledgment: UInt32?
    private var duplicateAckCount = 0

    init(maxRetainedBytes: Int) {
        self.maxRetainedBytes = max(0, maxRetainedBytes)
    }

    var isEmpty: Bool {
        segments.isEmpty
    }

    var inFlightSequenceLength: UInt32 {
        segments.reduce(UInt32(0)) { partial, segment in
            partial &+ segment.length
        }
    }

    static func sequenceLength(flags: TCPFlags, payloadLength: Int) -> UInt32 {
        var length = UInt32(payloadLength)
        if flags.contains(.syn) {
            length = length &+ 1
        }
        if flags.contains(.fin) {
            length = length &+ 1
        }
        return length
    }

    mutating func record(sequenceNumber: UInt32, flags: TCPFlags, options: Data = Data(), payload: Data, sentAt: UInt64) -> Bool {
        let length = Self.sequenceLength(flags: flags, payloadLength: payload.count)
        guard length > 0 else { return true }
        guard retainedBytes + payload.count <= maxRetainedBytes else { return false }
        retainedBytes += payload.count
        segments.append(Segment(sequenceNumber: sequenceNumber, flags: flags, options: options, payload: payload, sentAt: sentAt))
        return true
    }

    mutating func acknowledge(_ acknowledgmentNumber: UInt32) -> AckResult {
        guard !segments.isEmpty else {
            lastAcknowledgment = acknowledgmentNumber
            duplicateAckCount = 0
            return .ignored
        }

        if let lastAcknowledgment {
            if tcpSequenceLessThan(acknowledgmentNumber, lastAcknowledgment) {
                return .ignored
            }

            if acknowledgmentNumber == lastAcknowledgment {
                duplicateAckCount += 1
                return .duplicate(duplicateAckCount)
            }
        }

        lastAcknowledgment = acknowledgmentNumber
        duplicateAckCount = 0

        var progressed = false
        var updated: [Segment] = []
        updated.reserveCapacity(segments.count)

        for var segment in segments {
            guard tcpSequenceLessThan(segment.sequenceNumber, acknowledgmentNumber) else {
                updated.append(segment)
                continue
            }

            progressed = true
            if tcpSequenceLessThanOrEqual(segment.endSequence, acknowledgmentNumber) {
                retainedBytes -= segment.payload.count
                continue
            }

            let acknowledgedLength = Int(acknowledgmentNumber &- segment.sequenceNumber)
            let trimCount = min(acknowledgedLength, segment.payload.count)
            if trimCount > 0 {
                segment.payload.removeFirst(trimCount)
                retainedBytes -= trimCount
            }
            segment.sequenceNumber = acknowledgmentNumber
            updated.append(segment)
        }

        segments = updated
        return progressed ? .progress : .ignored
    }

    mutating func nextDuplicateAckRetransmission(at now: UInt64) -> SegmentSnapshot? {
        nextRetransmission(at: now, requireTimeout: false)
    }

    mutating func nextTimedOutRetransmission(at now: UInt64) -> SegmentSnapshot? {
        nextRetransmission(at: now, requireTimeout: true)
    }

    private mutating func nextRetransmission(at now: UInt64, requireTimeout: Bool) -> SegmentSnapshot? {
        guard let index = segments.indices.first(where: { index in
            !requireTimeout || now >= segments[index].sentAt + Self.retransmissionTimeoutNanos
        }) else {
            return nil
        }

        segments[index].sentAt = now
        segments[index].retransmissionCount += 1
        return segments[index].snapshot
    }
}

struct TCPInboundReassembler {
    enum InsertResult {
        case accepted([Data])
        case overflow
    }

    private struct BufferedSegment {
        var sequenceNumber: UInt32
        var payload: Data

        var endSequence: UInt32 {
            sequenceNumber &+ UInt32(payload.count)
        }
    }

    private let maxBufferedBytes: Int
    private var segments: [BufferedSegment] = []
    private var bufferedBytes = 0

    init(maxBufferedBytes: Int) {
        self.maxBufferedBytes = max(0, maxBufferedBytes)
    }

    var availableByteCount: Int {
        max(0, maxBufferedBytes - bufferedBytes)
    }

    mutating func insert(sequenceNumber: UInt32, payload: Data, nextSequence: inout UInt32) -> InsertResult {
        guard !payload.isEmpty else {
            return .accepted([])
        }

        let endSequence = sequenceNumber &+ UInt32(payload.count)
        guard !tcpSequenceLessThanOrEqual(endSequence, nextSequence) else {
            return .accepted([])
        }

        var normalizedSequence = sequenceNumber
        var normalizedPayload = payload
        if tcpSequenceLessThan(normalizedSequence, nextSequence) {
            let trimCount = Int(nextSequence &- normalizedSequence)
            guard trimCount < normalizedPayload.count else {
                return .accepted([])
            }
            normalizedPayload.removeFirst(trimCount)
            normalizedSequence = nextSequence
        }

        segments.append(BufferedSegment(sequenceNumber: normalizedSequence, payload: normalizedPayload))
        coalesceSegments()
        let drained = drainContiguousSegments(nextSequence: &nextSequence)

        guard bufferedBytes <= maxBufferedBytes else {
            return .overflow
        }

        return .accepted(drained)
    }

    private mutating func coalesceSegments() {
        segments.sort { lhs, rhs in
            tcpSequenceLessThan(lhs.sequenceNumber, rhs.sequenceNumber)
        }

        var merged: [BufferedSegment] = []
        merged.reserveCapacity(segments.count)

        for segment in segments {
            guard !segment.payload.isEmpty else { continue }
            guard var last = merged.popLast() else {
                merged.append(segment)
                continue
            }

            let lastEnd = last.endSequence
            if tcpSequenceLessThan(segment.sequenceNumber, lastEnd) || segment.sequenceNumber == lastEnd {
                if tcpSequenceLessThan(lastEnd, segment.endSequence) {
                    let suffixOffset = Int(lastEnd &- segment.sequenceNumber)
                    last.payload.append(contentsOf: segment.payload.dropFirst(suffixOffset))
                }
                merged.append(last)
            } else {
                merged.append(last)
                merged.append(segment)
            }
        }

        segments = merged
        bufferedBytes = segments.reduce(0) { $0 + $1.payload.count }
    }

    private mutating func drainContiguousSegments(nextSequence: inout UInt32) -> [Data] {
        var drained: [Data] = []

        while let first = segments.first {
            if first.sequenceNumber == nextSequence {
                drained.append(first.payload)
                nextSequence = nextSequence &+ UInt32(first.payload.count)
                segments.removeFirst()
                continue
            }

            if tcpSequenceLessThan(first.sequenceNumber, nextSequence) {
                if tcpSequenceLessThanOrEqual(first.endSequence, nextSequence) {
                    segments.removeFirst()
                    continue
                }

                let trimCount = Int(nextSequence &- first.sequenceNumber)
                let payload = Data(first.payload.dropFirst(trimCount))
                drained.append(payload)
                nextSequence = nextSequence &+ UInt32(payload.count)
                segments.removeFirst()
                continue
            }

            break
        }

        bufferedBytes = segments.reduce(0) { $0 + $1.payload.count }
        return drained
    }
}

struct TCPPendingWriteBuffer {
    private let maxBufferedBytes: Int
    private var payloads: [Data] = []
    private var bufferedBytes = 0

    init(maxBufferedBytes: Int) {
        self.maxBufferedBytes = max(0, maxBufferedBytes)
    }

    var availableByteCount: Int {
        max(0, maxBufferedBytes - bufferedBytes)
    }

    mutating func append(_ payload: Data) -> Bool {
        guard !payload.isEmpty else { return true }
        guard bufferedBytes + payload.count <= maxBufferedBytes else { return false }
        payloads.append(payload)
        bufferedBytes += payload.count
        return true
    }

    mutating func drain() -> [Data] {
        let drained = payloads
        removeAll()
        return drained
    }

    mutating func removeAll() {
        payloads.removeAll()
        bufferedBytes = 0
    }
}

struct TCPByteBuffer {
    private let maxBufferedBytes: Int
    private var storage = Data()

    init(maxBufferedBytes: Int) {
        self.maxBufferedBytes = max(0, maxBufferedBytes)
    }

    var isEmpty: Bool {
        storage.isEmpty
    }

    var count: Int {
        storage.count
    }

    mutating func append(_ data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        guard storage.count + data.count <= maxBufferedBytes else { return false }
        storage.append(data)
        return true
    }

    mutating func popPrefix(_ count: Int) -> Data? {
        guard count > 0, count <= storage.count else { return nil }
        let prefix = storage.prefix(count)
        storage.removeFirst(count)
        return Data(prefix)
    }

    mutating func removeAll() {
        storage.removeAll(keepingCapacity: false)
    }
}

func tcpSequenceLessThan(_ lhs: UInt32, _ rhs: UInt32) -> Bool {
    lhs != rhs && Int32(bitPattern: lhs &- rhs) < 0
}

func tcpSequenceLessThanOrEqual(_ lhs: UInt32, _ rhs: UInt32) -> Bool {
    lhs == rhs || tcpSequenceLessThan(lhs, rhs)
}

enum SOCKS5Destination: Equatable, Sendable {
    case ipv4(UInt32)
    case domain(String)
}

private enum SOCKS5Connector {
    enum ConnectorError: Error {
        case invalidSocksEndpoint
        case connectFailed(Int32)
        case handshakeFailed
        case connectRejected(UInt8)
    }

    static func connect(socksHost: String, socksPort: Int, destination: SOCKS5Destination, destinationPort: UInt16) throws -> Int32 {
        guard socksHost == "127.0.0.1", (1...65_535).contains(socksPort) else {
            throw ConnectorError.invalidSocksEndpoint
        }

        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else {
            throw ConnectorError.connectFailed(errno)
        }

        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

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

            try sendAll([0x05, 0x01, 0x00] + addressBytes(for: destination) + UInt16(destinationPort).bytes, fd: fd)
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

    private static func addressBytes(for destination: SOCKS5Destination) throws -> [UInt8] {
        switch destination {
        case .ipv4(let address):
            return [0x01] + IPv4AddressFormatter.bytes(from: address)
        case .domain(let domain):
            let bytes = Array(domain.utf8)
            guard !bytes.isEmpty, bytes.count <= 255 else {
                throw ConnectorError.invalidSocksEndpoint
            }
            return [0x03, UInt8(bytes.count)] + bytes
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

enum IPv4PacketFactory {
    static func tcp(
        sourceAddress: UInt32,
        destinationAddress: UInt32,
        sourcePort: UInt16,
        destinationPort: UInt16,
        sequenceNumber: UInt32,
        acknowledgmentNumber: UInt32,
        flags: TCPFlags,
        window: UInt16,
        options: Data = Data(),
        payload: Data
    ) -> Data {
        var optionBytes = [UInt8](options)
        while optionBytes.count % 4 != 0 {
            optionBytes.append(0)
        }
        let headerLength = 20 + optionBytes.count
        precondition(headerLength <= 60, "TCP options exceed the maximum header size")

        var tcp = [UInt8](repeating: 0, count: headerLength + payload.count)
        tcp.writeUInt16(sourcePort, at: 0)
        tcp.writeUInt16(destinationPort, at: 2)
        tcp.writeUInt32(sequenceNumber, at: 4)
        tcp.writeUInt32(acknowledgmentNumber, at: 8)
        tcp[12] = UInt8(headerLength / 4) << 4
        tcp[13] = flags.rawValue
        tcp.writeUInt16(window, at: 14)
        tcp.writeUInt16(0, at: 16)
        tcp.writeUInt16(0, at: 18)
        if !optionBytes.isEmpty {
            tcp.replaceSubrange(20..<headerLength, with: optionBytes)
        }
        tcp.replaceSubrange(headerLength..<tcp.count, with: payload)

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

struct IPv6Packet: Sendable {
    var sourceAddress: [UInt8]
    var destinationAddress: [UInt8]
    var nextHeader: UInt8
    var payload: Data

    static func parse(_ data: Data) -> IPv6Packet? {
        guard data.count >= 40 else { return nil }
        guard data[0] >> 4 == 6 else { return nil }
        guard let payloadLength = data.uint16(at: 4) else { return nil }
        let packetLength = min(data.count, 40 + Int(payloadLength))
        guard packetLength >= 40 else { return nil }
        return IPv6Packet(
            sourceAddress: Array(data[8..<24]),
            destinationAddress: Array(data[24..<40]),
            nextHeader: data[6],
            payload: data.subdata(in: 40..<packetLength)
        )
    }

    var icmpQuote: Data {
        var quote = Data()
        quote.reserveCapacity(40 + payload.count)
        quote.append(contentsOf: [0x60, 0, 0, 0])
        quote.append(contentsOf: UInt16(min(payload.count, Int(UInt16.max))).bytes)
        quote.append(nextHeader)
        quote.append(64)
        quote.append(contentsOf: sourceAddress)
        quote.append(contentsOf: destinationAddress)
        quote.append(payload.prefix(1232))
        return quote
    }
}

enum IPv6PacketFactory {
    static func icmpDestinationUnreachable(for original: IPv6Packet, originalPacket: Data, code: UInt8) -> Data {
        var quote = originalPacket.prefix(1232)
        if quote.isEmpty {
            quote = original.icmpQuote.prefix(1232)
        }

        var icmp = [UInt8](repeating: 0, count: 8)
        icmp[0] = 1
        icmp[1] = code
        icmp.append(contentsOf: quote)

        let checksum = icmpv6Checksum(
            sourceAddress: original.destinationAddress,
            destinationAddress: original.sourceAddress,
            payload: icmp
        )
        icmp.writeUInt16(checksum, at: 2)

        return ipv6(
            sourceAddress: original.destinationAddress,
            destinationAddress: original.sourceAddress,
            nextHeader: IPProtocolNumber.icmpv6,
            payload: icmp
        )
    }

    private static func ipv6(sourceAddress: [UInt8], destinationAddress: [UInt8], nextHeader: UInt8, payload: [UInt8]) -> Data {
        precondition(sourceAddress.count == 16 && destinationAddress.count == 16, "IPv6 addresses must be 16 bytes")
        precondition(payload.count <= Int(UInt16.max), "IPv6 payload exceeds single-packet size")

        var packet = [UInt8](repeating: 0, count: 40 + payload.count)
        packet[0] = 0x60
        packet.writeUInt16(UInt16(payload.count), at: 4)
        packet[6] = nextHeader
        packet[7] = 64
        packet.replaceSubrange(8..<24, with: sourceAddress)
        packet.replaceSubrange(24..<40, with: destinationAddress)
        packet.replaceSubrange(40..<packet.count, with: payload)
        return Data(packet)
    }

    private static func icmpv6Checksum(sourceAddress: [UInt8], destinationAddress: [UInt8], payload: [UInt8]) -> UInt16 {
        var pseudo = [UInt8]()
        pseudo.reserveCapacity(40 + payload.count + 1)
        pseudo.append(contentsOf: sourceAddress)
        pseudo.append(contentsOf: destinationAddress)
        pseudo.append(contentsOf: UInt32(payload.count).bytes)
        pseudo.append(contentsOf: [0, 0, 0])
        pseudo.append(IPProtocolNumber.icmpv6)
        pseudo.append(contentsOf: payload)
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

enum IPv4AddressFormatter {
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

extension Data {
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

extension Array where Element == UInt8 {
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

extension UInt16 {
    var bytes: [UInt8] {
        [UInt8((self >> 8) & 0xff), UInt8(self & 0xff)]
    }
}

extension UInt32 {
    var bytes: [UInt8] {
        [
            UInt8((self >> 24) & 0xff),
            UInt8((self >> 16) & 0xff),
            UInt8((self >> 8) & 0xff),
            UInt8(self & 0xff)
        ]
    }
}
