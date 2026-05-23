import Foundation
@testable import BlazeTunnelExtension
import XCTest

final class TCPByteBufferTests: XCTestCase {
    func testPopPrefixReturnsQueuedBytesInOrder() {
        var buffer = TCPByteBuffer(maxBufferedBytes: 16)

        XCTAssertTrue(buffer.append(Data("hello".utf8)))
        XCTAssertTrue(buffer.append(Data("world".utf8)))

        XCTAssertEqual(buffer.count, 10)
        XCTAssertEqual(buffer.popPrefix(3), Data("hel".utf8))
        XCTAssertEqual(buffer.popPrefix(4), Data("lowo".utf8))
        XCTAssertEqual(buffer.popPrefix(3), Data("rld".utf8))
        XCTAssertTrue(buffer.isEmpty)
    }

    func testAppendRejectsOverflowWithoutChangingQueuedBytes() {
        var buffer = TCPByteBuffer(maxBufferedBytes: 4)

        XCTAssertTrue(buffer.append(Data("abcd".utf8)))
        XCTAssertFalse(buffer.append(Data("e".utf8)))
        XCTAssertEqual(buffer.count, 4)
        XCTAssertEqual(buffer.popPrefix(4), Data("abcd".utf8))
    }
}
