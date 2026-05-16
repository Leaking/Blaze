import Foundation
@testable import BlazeTunnelExtension
import XCTest

final class DNSFakeIPStoreTests: XCTestCase {
    func testFakeIPAllocationIsStableAndReversible() {
        let store = DNSFakeIPStore(ttl: 60, maxEntries: 16)
        let now = Date(timeIntervalSince1970: 1_000)

        let first = store.address(for: "Example.COM.", now: now)
        let second = store.address(for: "example.com", now: now.addingTimeInterval(10))

        XCTAssertEqual(first, second)
        XCTAssertTrue(DNSFakeIPStore.isFakeIP(first))
        XCTAssertEqual(store.domain(for: first, now: now.addingTimeInterval(20)), "example.com")
    }

    func testExpiredFakeIPMappingIsRemoved() {
        let store = DNSFakeIPStore(ttl: 5, maxEntries: 16)
        let now = Date(timeIntervalSince1970: 1_000)

        let address = store.address(for: "expired.example", now: now)

        XCTAssertEqual(store.domain(for: address, now: now.addingTimeInterval(4)), "expired.example")
        XCTAssertNil(store.domain(for: address, now: now.addingTimeInterval(6)))
    }

    func testLeastRecentlyUsedMappingIsEvictedWhenFull() {
        let store = DNSFakeIPStore(ttl: 60, maxEntries: 2)
        let now = Date(timeIntervalSince1970: 1_000)

        let first = store.address(for: "a.example", now: now)
        let second = store.address(for: "b.example", now: now.addingTimeInterval(1))
        XCTAssertEqual(store.domain(for: first, now: now.addingTimeInterval(2)), "a.example")

        _ = store.address(for: "c.example", now: now.addingTimeInterval(3))

        XCTAssertEqual(store.domain(for: first, now: now.addingTimeInterval(4)), "a.example")
        XCTAssertNil(store.domain(for: second, now: now.addingTimeInterval(4)))
    }
}

final class DNSMessageFakeIPTests: XCTestCase {
    func testAQuestionCanBeAnsweredWithFakeIP() {
        let query = dnsQuery(name: "www.example.com", type: 1)
        let question = DNSMessage.singleQuestion(in: query)

        XCTAssertEqual(question?.name, "www.example.com")
        XCTAssertEqual(question?.type, 1)
        XCTAssertEqual(question?.recordClass, 1)

        let response = DNSMessage.fakeAResponse(for: query, question: question!, address: 0xC6120001, ttl: 60)

        XCTAssertEqual(response?[0], 0x12)
        XCTAssertEqual(response?[1], 0x34)
        XCTAssertEqual(response?.uint16ForTest(at: 4), 1)
        XCTAssertEqual(response?.uint16ForTest(at: 6), 1)
        XCTAssertEqual(Array(response!.suffix(4)), [198, 18, 0, 1])
    }

    func testAAAAQuestionStillBuildsEmptyNoErrorResponse() {
        let query = dnsQuery(name: "www.example.com", type: 28)
        let response = DNSMessage.emptyNoErrorResponse(for: query)

        XCTAssertEqual(response?.uint16ForTest(at: 4), 1)
        XCTAssertEqual(response?.uint16ForTest(at: 6), 0)
    }

    func testLocalNamesAreNotFakeIPSynthesized() {
        XCTAssertFalse(DNSMessage.shouldSynthesizeFakeIP(for: "localhost"))
        XCTAssertFalse(DNSMessage.shouldSynthesizeFakeIP(for: "printer.local"))
        XCTAssertFalse(DNSMessage.shouldSynthesizeFakeIP(for: "1.0.0.127.in-addr.arpa"))
        XCTAssertTrue(DNSMessage.shouldSynthesizeFakeIP(for: "example.com"))
    }
}

private func dnsQuery(name: String, type: UInt16) -> Data {
    var bytes: [UInt8] = [
        0x12, 0x34,
        0x01, 0x00,
        0x00, 0x01,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00
    ]
    for label in name.split(separator: ".") {
        let labelBytes = Array(label.utf8)
        bytes.append(UInt8(labelBytes.count))
        bytes.append(contentsOf: labelBytes)
    }
    bytes.append(0)
    bytes.append(UInt8((type >> 8) & 0xff))
    bytes.append(UInt8(type & 0xff))
    bytes.append(0x00)
    bytes.append(0x01)
    return Data(bytes)
}

private extension Data {
    func uint16ForTest(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 1 < count else { return nil }
        return (UInt16(self[offset]) << 8) | UInt16(self[offset + 1])
    }
}
