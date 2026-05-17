import CFNetwork
import Foundation
import os.log

final class DNSOverHTTPSProxy: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.chenhuazhao.blaze.tunnel", category: "DNSOverHTTPSProxy")
    private let url: URL
    private let session: URLSession
    private let suppressIPv6DNS: Bool
    private let enableFakeIPDNS: Bool
    private let enableNetworkFallback: Bool
    private let fakeIPStore: DNSFakeIPStore

    init(
        url: URL,
        httpProxyHost: String,
        httpProxyPort: Int,
        suppressIPv6DNS: Bool,
        enableFakeIPDNS: Bool,
        enableNetworkFallback: Bool,
        fakeIPStore: DNSFakeIPStore
    ) {
        self.url = url
        self.suppressIPv6DNS = suppressIPv6DNS
        self.enableFakeIPDNS = enableFakeIPDNS
        self.enableNetworkFallback = enableNetworkFallback
        self.fakeIPStore = fakeIPStore
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
        if let question = DNSMessage.singleQuestion(in: udp.payload) {
            if enableFakeIPDNS,
               question.type == DNSMessage.RecordType.a,
               question.recordClass == 1,
               DNSMessage.shouldSynthesizeFakeIP(for: question.name) {
                let fakeAddress = fakeIPStore.address(for: question.name)
                if let response = DNSMessage.fakeAResponse(for: udp.payload, question: question, address: fakeAddress) {
                    logger.debug("Synthesizing fake A answer \(IPv4AddressFormatter.string(from: fakeAddress), privacy: .public) for \(question.name, privacy: .public)")
                    sendDNSResponse(
                        response,
                        originalIPv4: ipv4,
                        originalUDP: udp,
                        packetWriter: packetWriter
                    )
                    return
                }
            }

            if DNSMessage.shouldAnswerEmptyLocally(
                question: question,
                suppressIPv6DNS: suppressIPv6DNS,
                enableFakeIPDNS: enableFakeIPDNS
            ),
               let response = DNSMessage.emptyNoErrorResponse(for: udp.payload) {
                logger.debug("Suppressing DNS type \(question.type, privacy: .public) answer for \(question.name, privacy: .public)")
                sendDNSResponse(
                    response,
                    originalIPv4: ipv4,
                    originalUDP: udp,
                    packetWriter: packetWriter
                )
                return
            }
        }

        guard enableNetworkFallback else {
            logger.debug("Answering DNS query locally with empty fallback because network fallback is disabled")
            sendEmptyFallbackResponse(
                for: udp.payload,
                sourceAddress: ipv4.sourceAddress,
                destinationAddress: ipv4.destinationAddress,
                sourcePort: udp.sourcePort,
                destinationPort: udp.destinationPort,
                packetWriter: packetWriter
            )
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
                self.sendEmptyFallbackResponse(
                    for: udp.payload,
                    sourceAddress: sourceAddress,
                    destinationAddress: destinationAddress,
                    sourcePort: sourcePort,
                    destinationPort: destinationPort,
                    packetWriter: packetWriter
                )
                return
            }
            guard let data, !data.isEmpty else {
                self.logger.error("DoH query returned no response bytes")
                self.sendEmptyFallbackResponse(
                    for: udp.payload,
                    sourceAddress: sourceAddress,
                    destinationAddress: destinationAddress,
                    sourcePort: sourcePort,
                    destinationPort: destinationPort,
                    packetWriter: packetWriter
                )
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

    private func sendEmptyFallbackResponse(
        for query: Data,
        sourceAddress: UInt32,
        destinationAddress: UInt32,
        sourcePort: UInt16,
        destinationPort: UInt16,
        packetWriter: @escaping @Sendable (Data) -> Void
    ) {
        guard let response = DNSMessage.emptyNoErrorResponse(for: query) else { return }
        let packet = IPv4PacketFactory.udp(
            sourceAddress: destinationAddress,
            destinationAddress: sourceAddress,
            sourcePort: destinationPort,
            destinationPort: sourcePort,
            payload: response
        )
        packetWriter(packet)
    }

    private func sendDNSResponse(
        _ response: Data,
        originalIPv4: IPv4Packet,
        originalUDP: UDPPacket,
        packetWriter: @escaping @Sendable (Data) -> Void
    ) {
        let packet = IPv4PacketFactory.udp(
            sourceAddress: originalIPv4.destinationAddress,
            destinationAddress: originalIPv4.sourceAddress,
            sourcePort: originalUDP.destinationPort,
            destinationPort: originalUDP.sourcePort,
            payload: response
        )
        packetWriter(packet)
    }
}

final class DNSFakeIPStore: @unchecked Sendable {
    private struct Record {
        var domain: String
        var address: UInt32
        var expiresAt: Date
        var lastAccess: Date
    }

    private static let baseAddress: UInt32 = 0xC6120001
    private static let lastAddress: UInt32 = 0xC613FFFE
    private let queue = DispatchQueue(label: "com.chenhuazhao.blaze.tunnel.fake-ip")
    private let ttl: TimeInterval
    private let maxEntries: Int
    private var nextAddress = DNSFakeIPStore.baseAddress
    private var domainToAddress: [String: UInt32] = [:]
    private var addressToRecord: [UInt32: Record] = [:]

    init(ttl: TimeInterval = 600, maxEntries: Int = 4096) {
        self.ttl = ttl
        self.maxEntries = max(1, maxEntries)
    }

    func address(for domain: String, now: Date = Date()) -> UInt32 {
        let normalized = normalize(domain)
        return queue.sync {
            removeExpiredLocked(now: now)
            if let existing = domainToAddress[normalized],
               var record = addressToRecord[existing] {
                record.expiresAt = now.addingTimeInterval(ttl)
                record.lastAccess = now
                addressToRecord[existing] = record
                return existing
            }

            evictIfNeededLocked()
            let address = allocateAddressLocked(now: now)
            let record = Record(domain: normalized, address: address, expiresAt: now.addingTimeInterval(ttl), lastAccess: now)
            domainToAddress[normalized] = address
            addressToRecord[address] = record
            return address
        }
    }

    func domain(for address: UInt32, now: Date = Date()) -> String? {
        queue.sync {
            guard var record = addressToRecord[address] else { return nil }
            guard record.expiresAt > now else {
                domainToAddress.removeValue(forKey: record.domain)
                addressToRecord.removeValue(forKey: address)
                return nil
            }
            record.lastAccess = now
            addressToRecord[address] = record
            return record.domain
        }
    }

    func mappingCount(now: Date = Date()) -> Int {
        queue.sync {
            removeExpiredLocked(now: now)
            return addressToRecord.count
        }
    }

    static func isFakeIP(_ address: UInt32) -> Bool {
        (address & 0xFFFE0000) == 0xC6120000
    }

    private func normalize(_ domain: String) -> String {
        domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
    }

    private func allocateAddressLocked(now: Date) -> UInt32 {
        let start = nextAddress
        while addressToRecord[nextAddress] != nil {
            advanceNextAddressLocked()
            if nextAddress == start {
                evictLeastRecentlyUsedLocked()
                break
            }
        }
        let address = nextAddress
        advanceNextAddressLocked()
        return address
    }

    private func advanceNextAddressLocked() {
        if nextAddress >= Self.lastAddress {
            nextAddress = Self.baseAddress
        } else {
            nextAddress = nextAddress &+ 1
        }
    }

    private func removeExpiredLocked(now: Date) {
        let expired = addressToRecord.filter { $0.value.expiresAt <= now }
        for (address, record) in expired {
            domainToAddress.removeValue(forKey: record.domain)
            addressToRecord.removeValue(forKey: address)
        }
    }

    private func evictIfNeededLocked() {
        while addressToRecord.count >= maxEntries {
            evictLeastRecentlyUsedLocked()
        }
    }

    private func evictLeastRecentlyUsedLocked() {
        guard let victim = addressToRecord.values.min(by: { $0.lastAccess < $1.lastAccess }) else { return }
        domainToAddress.removeValue(forKey: victim.domain)
        addressToRecord.removeValue(forKey: victim.address)
    }
}

enum DNSMessage {
    enum RecordType {
        static let a: UInt16 = 1
        static let aaaa: UInt16 = 28
        static let svcb: UInt16 = 64
        static let https: UInt16 = 65
    }

    struct Question: Equatable {
        var name: String
        var type: UInt16
        var recordClass: UInt16
        var range: Range<Data.Index>
    }

    static func emptyNoErrorResponse(for query: Data) -> Data? {
        guard query.count >= 12,
              let flags = query.uint16(at: 2),
              let qdCount = query.uint16(at: 4),
              qdCount > 0,
              let question = singleQuestion(in: query)
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

    static func fakeAResponse(for query: Data, question: Question, address: UInt32, ttl: UInt32 = 60) -> Data? {
        guard query.count >= 12,
              let flags = query.uint16(at: 2),
              let qdCount = query.uint16(at: 4),
              qdCount == 1,
              question.type == 1,
              question.recordClass == 1
        else {
            return nil
        }

        var response = [UInt8](repeating: 0, count: 12)
        response[0] = query[0]
        response[1] = query[1]
        let responseFlags = UInt16(0x8000) | (flags & 0x7900) | 0x0080
        response.writeUInt16(responseFlags, at: 2)
        response.writeUInt16(1, at: 4)
        response.writeUInt16(1, at: 6)
        response.writeUInt16(0, at: 8)
        response.writeUInt16(0, at: 10)
        response.append(contentsOf: query[question.range])
        response.append(0xC0)
        response.append(0x0C)
        response.append(contentsOf: UInt16(1).bytes)
        response.append(contentsOf: UInt16(1).bytes)
        response.append(UInt8((ttl >> 24) & 0xff))
        response.append(UInt8((ttl >> 16) & 0xff))
        response.append(UInt8((ttl >> 8) & 0xff))
        response.append(UInt8(ttl & 0xff))
        response.append(contentsOf: UInt16(4).bytes)
        response.append(contentsOf: IPv4AddressFormatter.bytes(from: address))
        return Data(response)
    }

    static func shouldSynthesizeFakeIP(for domain: String) -> Bool {
        let lowercased = domain.lowercased()
        guard !lowercased.isEmpty else { return false }
        if lowercased == "localhost" { return false }
        if lowercased.hasSuffix(".local") { return false }
        if lowercased.hasSuffix(".arpa") { return false }
        return true
    }

    static func shouldAnswerEmptyLocally(question: Question, suppressIPv6DNS: Bool, enableFakeIPDNS: Bool) -> Bool {
        if suppressIPv6DNS, question.type == RecordType.aaaa {
            return true
        }
        if enableFakeIPDNS, question.type == RecordType.svcb || question.type == RecordType.https {
            return true
        }
        return false
    }

    static func singleQuestion(in data: Data) -> Question? {
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
        guard let recordClass = data.uint16(at: offset + 2) else {
            return nil
        }
        let name = decodeQName(in: data, range: 12..<offset)
        guard !name.isEmpty else { return nil }
        return Question(name: name, type: type, recordClass: recordClass, range: 12..<(offset + 4))
    }

    private static func decodeQName(in data: Data, range: Range<Data.Index>) -> String {
        var labels: [String] = []
        var offset = range.lowerBound
        while offset < range.upperBound {
            let length = Int(data[offset])
            offset += 1
            guard length > 0, offset + length <= range.upperBound else { break }
            labels.append(String(decoding: data[offset..<(offset + length)], as: UTF8.self))
            offset += length
        }
        return labels.joined(separator: ".").lowercased()
    }
}
