import Foundation
@testable import BlazeTunnelExtension
import XCTest

final class TCPInboundReassemblerTests: XCTestCase {
    func testOutOfOrderPayloadsDrainOnlyWhenContiguous() {
        var reassembler = TCPInboundReassembler(maxBufferedBytes: 1024)
        var nextSequence: UInt32 = 1_000

        XCTAssertAccepted([], reassembler.insert(sequenceNumber: 1_003, payload: Data("def".utf8), nextSequence: &nextSequence))
        XCTAssertEqual(nextSequence, 1_000)

        XCTAssertAccepted(["abcdef"], reassembler.insert(sequenceNumber: 1_000, payload: Data("abc".utf8), nextSequence: &nextSequence))
        XCTAssertEqual(nextSequence, 1_006)
    }

    func testDuplicatePayloadDoesNotDrainAgain() {
        var reassembler = TCPInboundReassembler(maxBufferedBytes: 1024)
        var nextSequence: UInt32 = 42

        XCTAssertAccepted(["hello"], reassembler.insert(sequenceNumber: 42, payload: Data("hello".utf8), nextSequence: &nextSequence))
        XCTAssertEqual(nextSequence, 47)

        XCTAssertAccepted([], reassembler.insert(sequenceNumber: 42, payload: Data("hello".utf8), nextSequence: &nextSequence))
        XCTAssertEqual(nextSequence, 47)
    }

    func testPartiallyOverlappingRetransmitDrainsOnlyNewTail() {
        var reassembler = TCPInboundReassembler(maxBufferedBytes: 1024)
        var nextSequence: UInt32 = 100

        XCTAssertAccepted(["abcd"], reassembler.insert(sequenceNumber: 100, payload: Data("abcd".utf8), nextSequence: &nextSequence))
        XCTAssertEqual(nextSequence, 104)

        XCTAssertAccepted(["ef"], reassembler.insert(sequenceNumber: 102, payload: Data("cdef".utf8), nextSequence: &nextSequence))
        XCTAssertEqual(nextSequence, 106)
    }

    func testBufferedOverlapIsCoalescedBeforeDrain() {
        var reassembler = TCPInboundReassembler(maxBufferedBytes: 1024)
        var nextSequence: UInt32 = 500

        XCTAssertAccepted([], reassembler.insert(sequenceNumber: 503, payload: Data("def".utf8), nextSequence: &nextSequence))
        XCTAssertAccepted([], reassembler.insert(sequenceNumber: 502, payload: Data("cde".utf8), nextSequence: &nextSequence))
        XCTAssertAccepted(["abcdef"], reassembler.insert(sequenceNumber: 500, payload: Data("ab".utf8), nextSequence: &nextSequence))
        XCTAssertEqual(nextSequence, 506)
    }

    func testOverflowIsReportedAfterCoalescing() {
        var reassembler = TCPInboundReassembler(maxBufferedBytes: 4)
        var nextSequence: UInt32 = 10

        XCTAssertAccepted([], reassembler.insert(sequenceNumber: 12, payload: Data("cd".utf8), nextSequence: &nextSequence))

        switch reassembler.insert(sequenceNumber: 14, payload: Data("efg".utf8), nextSequence: &nextSequence) {
        case .accepted:
            XCTFail("Expected overflow")
        case .overflow:
            break
        }
    }

    func testContiguousDrainIsNotLimitedByBufferedGapCapacity() {
        var reassembler = TCPInboundReassembler(maxBufferedBytes: 4)
        var nextSequence: UInt32 = 10

        XCTAssertAccepted([], reassembler.insert(sequenceNumber: 14, payload: Data("ef".utf8), nextSequence: &nextSequence))
        XCTAssertAccepted(["abcdef"], reassembler.insert(sequenceNumber: 10, payload: Data("abcd".utf8), nextSequence: &nextSequence))
        XCTAssertEqual(nextSequence, 16)
        XCTAssertEqual(reassembler.availableByteCount, 4)
    }
}

private func XCTAssertAccepted(
    _ expectedStrings: [String],
    _ result: TCPInboundReassembler.InsertResult,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    switch result {
    case .accepted(let payloads):
        XCTAssertEqual(payloads.map { String(decoding: $0, as: UTF8.self) }, expectedStrings, file: file, line: line)
    case .overflow:
        XCTFail("Expected accepted payloads", file: file, line: line)
    }
}
