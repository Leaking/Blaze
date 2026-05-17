import Foundation
@testable import BlazeTunnelExtension
import XCTest

final class TCPOptionsTests: XCTestCase {
    func testSYNOptionsRoundTripThroughTCPPacketFactory() {
        let options = Data(TCPOptions.synAckOptions(maxSegmentSize: 1360, windowScale: 0, sackPermitted: true))

        let packet = IPv4PacketFactory.tcp(
            sourceAddress: 0xC612_0001,
            destinationAddress: 0x0A00_0002,
            sourcePort: 443,
            destinationPort: 53_000,
            sequenceNumber: 10,
            acknowledgmentNumber: 20,
            flags: [.syn, .ack],
            window: 65_535,
            options: options,
            payload: Data()
        )

        let ipv4 = IPv4Packet.parse(packet)
        XCTAssertNotNil(ipv4)
        let tcp = ipv4!.payload
        let headerLength = Int(tcp[12] >> 4) * 4
        XCTAssertEqual(headerLength, 32)

        let parsed = TCPOptions.parse(tcp.subdata(in: 20..<headerLength))
        XCTAssertEqual(parsed.maxSegmentSize, 1360)
        XCTAssertTrue(parsed.sackPermitted)
        XCTAssertEqual(parsed.windowScale, 0)
    }

    func testSYNACKOmitsNegotiatedOptionsWhenClientDidNotOfferThem() {
        let options = Data(TCPOptions.synAckOptions(maxSegmentSize: 1360, windowScale: nil, sackPermitted: false))

        let parsed = TCPOptions.parse(options)
        XCTAssertEqual(parsed.maxSegmentSize, 1360)
        XCTAssertFalse(parsed.sackPermitted)
        XCTAssertNil(parsed.windowScale)
        XCTAssertEqual(options.count, 8)
    }

    func testMalformedOptionsStopParsingWithoutCrashing() {
        let parsed = TCPOptions.parse(Data([2, 4, 0x05]))

        XCTAssertNil(parsed.maxSegmentSize)
        XCTAssertNil(parsed.windowScale)
        XCTAssertFalse(parsed.sackPermitted)
    }
}
