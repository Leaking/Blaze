@testable import BlazeTunnelExtension
import XCTest

final class TCPActivityDeadlineTests: XCTestCase {
    func testDeadlineExpiresAfterTimeout() {
        let deadline = TCPActivityDeadline(timeoutNanos: 100, now: 1_000)

        XCTAssertFalse(deadline.isExpired(at: 1_099))
        XCTAssertTrue(deadline.isExpired(at: 1_100))
    }

    func testMarkActivityRefreshesDeadline() {
        var deadline = TCPActivityDeadline(timeoutNanos: 100, now: 1_000)

        deadline.markActivity(at: 1_050)

        XCTAssertFalse(deadline.isExpired(at: 1_149))
        XCTAssertTrue(deadline.isExpired(at: 1_150))
    }
}
