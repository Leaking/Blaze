import Foundation
@testable import BlazeTunnelExtension
import XCTest

final class TCPPendingWriteBufferTests: XCTestCase {
    func testAppendTracksAvailableByteCount() {
        var buffer = TCPPendingWriteBuffer(maxBufferedBytes: 8)

        XCTAssertTrue(buffer.append(Data("abc".utf8)))
        XCTAssertEqual(buffer.availableByteCount, 5)

        XCTAssertTrue(buffer.append(Data("de".utf8)))
        XCTAssertEqual(buffer.availableByteCount, 3)
    }

    func testAppendRejectsOverflowWithoutChangingAvailableBytes() {
        var buffer = TCPPendingWriteBuffer(maxBufferedBytes: 4)

        XCTAssertTrue(buffer.append(Data("abcd".utf8)))
        XCTAssertFalse(buffer.append(Data("e".utf8)))
        XCTAssertEqual(buffer.availableByteCount, 0)
    }

    func testDrainReturnsPayloadsAndResetsCapacity() {
        var buffer = TCPPendingWriteBuffer(maxBufferedBytes: 16)

        XCTAssertTrue(buffer.append(Data("one".utf8)))
        XCTAssertTrue(buffer.append(Data("two".utf8)))

        let drained = buffer.drain()

        XCTAssertEqual(drained.map { String(decoding: $0, as: UTF8.self) }, ["one", "two"])
        XCTAssertEqual(buffer.availableByteCount, 16)
    }
}
