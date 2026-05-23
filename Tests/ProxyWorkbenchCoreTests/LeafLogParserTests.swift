import XCTest
@testable import ProxyWorkbenchCore

final class LeafLogParserTests: XCTestCase {
    func testParsesAnsiColouredHandledLine() {
        let raw = "\u{1B}[2m2026-05-21T03:44:04.123Z\u{1B}[0m \u{1B}[32m INFO\u{1B}[0m \u{1B}[2mleaf::app::dispatcher\u{1B}[0m\u{1B}[2m:\u{1B}[0m handled src=127.0.0.1 proto=tcp in=socks out=HK10 connect=86ms dst=api.telegram.org:443"
        let event = LeafLogParser.parseHandled(Data(raw.utf8))
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.host, "api.telegram.org")
        XCTAssertEqual(event?.port, 443)
        XCTAssertEqual(event?.method, "SOCKS5")
        XCTAssertEqual(event?.policy, "HK10")
        XCTAssertEqual(event?.status, "Connected")
        XCTAssertEqual(event?.rule, "leaf")
        XCTAssertTrue(event?.note.contains("connect=86ms") ?? false)
    }

    func testParsesHttpInbound() {
        let raw = "handled src=127.0.0.1 proto=tcp in=http out=DIRECT connect=12ms dst=example.com:80"
        let event = LeafLogParser.parseHandled(Data(raw.utf8))
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.method, "HTTP")
        XCTAssertEqual(event?.policy, "DIRECT")
        XCTAssertEqual(event?.host, "example.com")
        XCTAssertEqual(event?.port, 80)
    }

    func testParsesPolicyWithSpacesAndEmoji() {
        let raw = "handled src=127.0.0.1 proto=tcp in=socks out=🇭🇰 Hong Kong 10 connect=86ms dst=api.telegram.org:443"
        let event = LeafLogParser.parseHandled(Data(raw.utf8))
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.policy, "🇭🇰 Hong Kong 10")
        XCTAssertEqual(event?.host, "api.telegram.org")
    }

    func testReturnsNilForNonHandledLine() {
        let raw = "INFO leaf::app::inbound::network_listener: listening tcp 127.0.0.1:19181"
        XCTAssertNil(LeafLogParser.parseHandled(Data(raw.utf8)))
    }

    func testStripsAnsi() {
        let raw = "\u{1B}[2mhello\u{1B}[0m world"
        XCTAssertEqual(LeafLogParser.stripAnsi(raw), "hello world")
    }
}
