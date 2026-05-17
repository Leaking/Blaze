import Foundation
@testable import BlazeTunnelExtension
import XCTest

final class IPv6PacketFactoryTests: XCTestCase {
    func testDestinationUnreachableSwapsAddressesAndQuotesOriginalPacket() {
        let source = [UInt8](repeating: 0x20, count: 16)
        let destination = [UInt8](repeating: 0xfd, count: 16)
        let original = makeIPv6Packet(source: source, destination: destination, nextHeader: IPProtocolNumber.tcp, payload: Data([1, 2, 3, 4]))
        let parsed = IPv6Packet.parse(original)
        XCTAssertNotNil(parsed)

        let response = IPv6PacketFactory.icmpDestinationUnreachable(for: parsed!, originalPacket: original, code: 1)
        let responseIPv6 = IPv6Packet.parse(response)

        XCTAssertEqual(responseIPv6?.sourceAddress, destination)
        XCTAssertEqual(responseIPv6?.destinationAddress, source)
        XCTAssertEqual(responseIPv6?.nextHeader, IPProtocolNumber.icmpv6)
        XCTAssertEqual(responseIPv6?.payload.first, 1)
        XCTAssertEqual(responseIPv6?.payload.dropFirst().first, 1)
        XCTAssertEqual(responseIPv6?.payload.dropFirst(8).prefix(original.count), original)
    }

    private func makeIPv6Packet(source: [UInt8], destination: [UInt8], nextHeader: UInt8, payload: Data) -> Data {
        var packet = [UInt8](repeating: 0, count: 40 + payload.count)
        packet[0] = 0x60
        packet.writeUInt16(UInt16(payload.count), at: 4)
        packet[6] = nextHeader
        packet[7] = 64
        packet.replaceSubrange(8..<24, with: source)
        packet.replaceSubrange(24..<40, with: destination)
        packet.replaceSubrange(40..<packet.count, with: payload)
        return Data(packet)
    }
}
