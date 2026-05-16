import Foundation

struct UDPFlowKey: Hashable, Sendable {
    var sourceAddress: UInt32
    var sourcePort: UInt16
    var destinationAddress: UInt32
    var destinationPort: UInt16
}

struct UDPFlowTable {
    struct Entry: Equatable {
        var key: UDPFlowKey
        var lastActivity: UInt64
    }

    private let idleTimeoutNanos: UInt64
    private var entries: [UDPFlowKey: Entry] = [:]

    init(idleTimeoutNanos: UInt64 = 60_000_000_000) {
        self.idleTimeoutNanos = idleTimeoutNanos
    }

    var count: Int {
        entries.count
    }

    mutating func touch(_ key: UDPFlowKey, at now: UInt64) {
        entries[key] = Entry(key: key, lastActivity: now)
    }

    mutating func remove(_ key: UDPFlowKey) {
        entries.removeValue(forKey: key)
    }

    mutating func removeExpired(at now: UInt64) -> [UDPFlowKey] {
        let expired = entries.values
            .filter { now >= $0.lastActivity + idleTimeoutNanos }
            .map(\.key)
        for key in expired {
            entries.removeValue(forKey: key)
        }
        return expired
    }
}

struct SOCKS5UDPDatagram: Equatable {
    var destination: SOCKS5Destination
    var destinationPort: UInt16
    var payload: Data

    static func encode(destination: SOCKS5Destination, destinationPort: UInt16, payload: Data) -> Data? {
        var data = Data([0x00, 0x00, 0x00])
        switch destination {
        case .ipv4(let address):
            data.append(0x01)
            data.append(contentsOf: IPv4AddressFormatter.bytes(from: address))
        case .domain(let domain):
            let hostBytes = Data(domain.utf8)
            guard !hostBytes.isEmpty, hostBytes.count <= 255 else { return nil }
            data.append(0x03)
            data.append(UInt8(hostBytes.count))
            data.append(hostBytes)
        }
        data.append(contentsOf: destinationPort.bytes)
        data.append(payload)
        return data
    }

    static func parse(_ data: Data) -> SOCKS5UDPDatagram? {
        guard data.count >= 7,
              data[0] == 0x00,
              data[1] == 0x00,
              data[2] == 0x00
        else {
            return nil
        }

        var offset = 4
        let destination: SOCKS5Destination
        switch data[3] {
        case 0x01:
            guard offset + 4 + 2 <= data.count else { return nil }
            guard let address = data.uint32(at: offset) else { return nil }
            offset += 4
            destination = .ipv4(address)
        case 0x03:
            guard offset < data.count else { return nil }
            let length = Int(data[offset])
            offset += 1
            guard length > 0, offset + length + 2 <= data.count else { return nil }
            let domain = String(decoding: data[offset..<(offset + length)], as: UTF8.self)
            offset += length
            destination = .domain(domain)
        default:
            return nil
        }

        guard let port = data.uint16(at: offset) else { return nil }
        offset += 2
        return SOCKS5UDPDatagram(destination: destination, destinationPort: port, payload: data.subdata(in: offset..<data.count))
    }
}
