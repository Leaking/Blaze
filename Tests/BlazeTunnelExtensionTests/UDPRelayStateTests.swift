import Foundation
@testable import BlazeTunnelExtension
import XCTest

final class UDPFlowTableTests: XCTestCase {
    func testTouchAndExpireFlows() {
        var table = UDPFlowTable(idleTimeoutNanos: 100)
        let first = UDPFlowKey(sourceAddress: 1, sourcePort: 10, destinationAddress: 2, destinationPort: 20)
        let second = UDPFlowKey(sourceAddress: 3, sourcePort: 30, destinationAddress: 4, destinationPort: 40)

        table.touch(first, at: 1_000)
        table.touch(second, at: 1_050)

        XCTAssertEqual(table.count, 2)
        XCTAssertEqual(table.removeExpired(at: 1_099), [])
        XCTAssertEqual(table.removeExpired(at: 1_100), [first])
        XCTAssertEqual(table.count, 1)
        XCTAssertEqual(table.removeExpired(at: 1_150), [second])
        XCTAssertEqual(table.count, 0)
    }
}

final class SOCKS5UDPDatagramTests: XCTestCase {
    func testIPv4DatagramRoundTrip() {
        let payload = Data("hello".utf8)
        let encoded = SOCKS5UDPDatagram.encode(destination: .ipv4(0x08080808), destinationPort: 53, payload: payload)
        let decoded = encoded.flatMap(SOCKS5UDPDatagram.parse)

        XCTAssertEqual(decoded?.destination, .ipv4(0x08080808))
        XCTAssertEqual(decoded?.destinationPort, 53)
        XCTAssertEqual(decoded?.payload, payload)
    }

    func testDomainDatagramRoundTrip() {
        let payload = Data([0xde, 0xad, 0xbe, 0xef])
        let encoded = SOCKS5UDPDatagram.encode(destination: .domain("example.com"), destinationPort: 443, payload: payload)
        let decoded = encoded.flatMap(SOCKS5UDPDatagram.parse)

        XCTAssertEqual(decoded?.destination, .domain("example.com"))
        XCTAssertEqual(decoded?.destinationPort, 443)
        XCTAssertEqual(decoded?.payload, payload)
    }

    func testFragmentedDatagramsAreRejected() {
        let invalid = Data([0x00, 0x00, 0x01, 0x01, 127, 0, 0, 1, 0, 53])

        XCTAssertNil(SOCKS5UDPDatagram.parse(invalid))
    }
}
