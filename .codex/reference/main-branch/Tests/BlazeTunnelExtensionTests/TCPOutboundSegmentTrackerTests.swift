import Foundation
@testable import BlazeTunnelExtension
import XCTest

final class TCPOutboundSegmentTrackerTests: XCTestCase {
    func testAcknowledgmentDropsFullyAckedSegments() {
        var tracker = TCPOutboundSegmentTracker(maxRetainedBytes: 1024)

        XCTAssertTrue(tracker.record(sequenceNumber: 1_000, flags: [.syn, .ack], payload: Data(), sentAt: 0))
        XCTAssertTrue(tracker.record(sequenceNumber: 1_001, flags: [.push, .ack], payload: Data("hello".utf8), sentAt: 0))
        XCTAssertEqual(tracker.inFlightSequenceLength, 6)

        XCTAssertEqual(tracker.acknowledge(1_001), .progress)
        XCTAssertFalse(tracker.isEmpty)
        XCTAssertEqual(tracker.inFlightSequenceLength, 5)

        XCTAssertEqual(tracker.acknowledge(1_006), .progress)
        XCTAssertTrue(tracker.isEmpty)
        XCTAssertEqual(tracker.inFlightSequenceLength, 0)
    }

    func testPartialAcknowledgmentTrimsRetransmittedPayload() {
        var tracker = TCPOutboundSegmentTracker(maxRetainedBytes: 1024)

        XCTAssertTrue(tracker.record(sequenceNumber: 50, flags: [.push, .ack], payload: Data("abcdef".utf8), sentAt: 0))
        XCTAssertEqual(tracker.acknowledge(53), .progress)
        XCTAssertEqual(tracker.inFlightSequenceLength, 3)

        let retransmission = tracker.nextDuplicateAckRetransmission(at: 1)
        XCTAssertEqual(retransmission?.sequenceNumber, 53)
        XCTAssertEqual(retransmission?.payload, Data("def".utf8))
    }

    func testDuplicateAcknowledgmentsCountTowardFastRetransmit() {
        var tracker = TCPOutboundSegmentTracker(maxRetainedBytes: 1024)

        XCTAssertTrue(tracker.record(sequenceNumber: 10, flags: [.push, .ack], payload: Data("abc".utf8), sentAt: 0))
        XCTAssertEqual(tracker.acknowledge(10), .ignored)
        XCTAssertEqual(tracker.acknowledge(10), .duplicate(1))
        XCTAssertEqual(tracker.acknowledge(10), .duplicate(2))
        XCTAssertEqual(tracker.acknowledge(10), .duplicate(3))

        let retransmission = tracker.nextDuplicateAckRetransmission(at: 10)
        XCTAssertEqual(retransmission?.sequenceNumber, 10)
        XCTAssertEqual(retransmission?.payload, Data("abc".utf8))
    }

    func testTimedRetransmissionWaitsForTimeout() {
        var tracker = TCPOutboundSegmentTracker(maxRetainedBytes: 1024)

        XCTAssertTrue(tracker.record(sequenceNumber: 90, flags: [.push, .ack], options: Data([1, 1]), payload: Data("xyz".utf8), sentAt: 0))
        XCTAssertNil(tracker.nextTimedOutRetransmission(at: 1_499_999_999))

        let retransmission = tracker.nextTimedOutRetransmission(at: 1_500_000_000)
        XCTAssertEqual(retransmission?.sequenceNumber, 90)
        XCTAssertEqual(retransmission?.options, Data([1, 1]))
        XCTAssertEqual(retransmission?.payload, Data("xyz".utf8))
    }

    func testRetainedPayloadLimitRejectsExcessData() {
        var tracker = TCPOutboundSegmentTracker(maxRetainedBytes: 4)

        XCTAssertTrue(tracker.record(sequenceNumber: 1, flags: [.push, .ack], payload: Data("abcd".utf8), sentAt: 0))
        XCTAssertFalse(tracker.record(sequenceNumber: 5, flags: [.push, .ack], payload: Data("e".utf8), sentAt: 0))
    }
}
