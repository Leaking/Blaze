import Darwin
import Foundation

enum ProxyIPv4AddressInspector {
    static func isFakeIP(_ host: String) -> Bool {
        var address = in_addr()
        guard inet_pton(AF_INET, host, &address) == 1 else {
            return false
        }
        let value = UInt32(bigEndian: address.s_addr)
        return (value & 0xFFFE_0000) == 0xC612_0000
    }
}

enum TLSClientHelloInspector {
    static func serverName(in data: Data) -> String? {
        let bytes = Array(data)
        guard bytes.count >= 5, bytes[0] == 0x16 else {
            return nil
        }

        let recordLength = (Int(bytes[3]) << 8) | Int(bytes[4])
        guard recordLength > 0, bytes.count >= 5 + recordLength else {
            return nil
        }

        var offset = 5
        guard offset + 4 <= bytes.count, bytes[offset] == 0x01 else {
            return nil
        }
        let handshakeLength = (Int(bytes[offset + 1]) << 16) | (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
        offset += 4
        let handshakeEnd = min(offset + handshakeLength, bytes.count)

        guard offset + 34 <= handshakeEnd else { return nil }
        offset += 34

        guard offset + 1 <= handshakeEnd else { return nil }
        let sessionIDLength = Int(bytes[offset])
        offset += 1 + sessionIDLength

        guard offset + 2 <= handshakeEnd else { return nil }
        let cipherSuitesLength = (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
        offset += 2 + cipherSuitesLength

        guard offset + 1 <= handshakeEnd else { return nil }
        let compressionMethodsLength = Int(bytes[offset])
        offset += 1 + compressionMethodsLength

        guard offset + 2 <= handshakeEnd else { return nil }
        let extensionsLength = (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
        offset += 2
        let extensionsEnd = min(offset + extensionsLength, handshakeEnd)

        while offset + 4 <= extensionsEnd {
            let type = (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
            let length = (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
            offset += 4
            guard offset + length <= extensionsEnd else {
                return nil
            }

            if type == 0x0000 {
                return serverName(inExtension: bytes, range: offset..<(offset + length))
            }
            offset += length
        }

        return nil
    }

    static func isPotentialClientHello(_ data: Data) -> Bool {
        guard let first = data.first else { return true }
        return first == 0x16
    }

    private static func serverName(inExtension bytes: [UInt8], range: Range<Int>) -> String? {
        var offset = range.lowerBound
        guard offset + 2 <= range.upperBound else { return nil }
        let listLength = (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
        offset += 2
        let listEnd = min(offset + listLength, range.upperBound)

        while offset + 3 <= listEnd {
            let nameType = bytes[offset]
            let nameLength = (Int(bytes[offset + 1]) << 8) | Int(bytes[offset + 2])
            offset += 3
            guard offset + nameLength <= listEnd else {
                return nil
            }

            if nameType == 0x00 {
                let nameBytes = bytes[offset..<(offset + nameLength)]
                guard let name = String(bytes: nameBytes, encoding: .utf8),
                      !name.isEmpty,
                      name.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7E }) else {
                    return nil
                }
                return name
            }
            offset += nameLength
        }

        return nil
    }
}

enum ProxyInitialPayloadReader {
    static func read(from fd: Int32, timeoutMilliseconds: Int = 3_000, maximumBytes: Int = 16 * 1024) throws -> Data {
        var data = Data()
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMilliseconds) / 1_000)

        while data.count < maximumBytes {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }

            var pollDescriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pollDescriptor, 1, Int32(max(1, remaining * 1_000)))
            if ready == 0 {
                break
            }
            guard ready > 0 else {
                throw ProxyServerError.posix("poll", errno)
            }
            guard (pollDescriptor.revents & Int16(POLLIN)) != 0 else {
                break
            }

            var buffer = [UInt8](repeating: 0, count: min(4096, maximumBytes - data.count))
            let count = recv(fd, &buffer, buffer.count, 0)
            if count == 0 {
                break
            }
            guard count > 0 else {
                throw ProxyServerError.posix("recv", errno)
            }
            data.append(buffer, count: count)

            if TLSClientHelloInspector.serverName(in: data) != nil {
                break
            }
            if !TLSClientHelloInspector.isPotentialClientHello(data) {
                break
            }
        }

        return data
    }
}

enum ProxyInitialPayloadDiagnostics {
    static func summary(for data: Data) -> String {
        guard !data.isEmpty else {
            return "initial payload 0 B"
        }

        let prefix = data.prefix(16)
            .map { String(format: "%02X", Int($0)) }
            .joined(separator: " ")
        return "initial payload \(data.count) B first=\(prefix)"
    }
}

enum HTTPHostHeaderInspector {
    static func host(in payload: Data) -> String? {
        guard !payload.isEmpty else { return nil }
        let prefix = payload.prefix(8 * 1024)
        guard let text = String(data: prefix, encoding: .isoLatin1) ?? String(data: prefix, encoding: .utf8) else {
            return nil
        }
        return host(inHeaderText: text)
    }

    static func host(inHeaderValue value: String) -> String? {
        normalizedHost(value)
    }

    private static func host(inHeaderText text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        guard lines.count > 1 else { return nil }

        for rawLine in lines.dropFirst() {
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
            if line.isEmpty { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.caseInsensitiveCompare("Host") == .orderedSame else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            return normalizedHost(String(value))
        }

        return nil
    }

    private static func normalizedHost(_ value: String) -> String? {
        var host = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return nil }

        if host.hasPrefix("["),
           let end = host.firstIndex(of: "]") {
            host = String(host[host.index(after: host.startIndex)..<end])
        } else if host.filter({ $0 == ":" }).count == 1,
                  let colon = host.lastIndex(of: ":"),
                  Int(host[host.index(after: colon)...]) != nil {
            host = String(host[..<colon])
        }

        host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !ProxyIPv4AddressInspector.isFakeIP(host) else {
            return nil
        }
        return host
    }
}
