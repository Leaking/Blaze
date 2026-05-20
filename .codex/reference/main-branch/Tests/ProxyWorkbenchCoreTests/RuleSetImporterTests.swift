import Darwin
import Foundation
@testable import ProxyWorkbenchCore
import XCTest

final class RuleSetImporterTests: XCTestCase {
    func testRuleSetParserUsesParentPolicy() {
        let rules = RuleSetImporter.parse(
            """
            # comment
            DOMAIN-SUFFIX,example.com
            DOMAIN-KEYWORD,openai,no-resolve
            PROCESS-NAME,IgnoredApp
            """,
            policy: "Proxies",
            sourceLineBase: 20_000
        )

        XCTAssertEqual(rules.count, 3)
        XCTAssertEqual(rules[0].type, "DOMAIN-SUFFIX")
        XCTAssertEqual(rules[0].value, "example.com")
        XCTAssertEqual(rules[0].policy, "Proxies")
        XCTAssertEqual(rules[1].options, ["no-resolve"])
    }

    func testImporterDownloadsRuleSetFromHTTP() async throws {
        let server = try RuleSetHTTPServer(body: "DOMAIN-SUFFIX,downloaded.test\n")
        defer { server.stop() }

        let rules = try await RuleSetImporter.importRules(from: server.url(path: "/rules.list"), policy: "Downloaded", sourceLineBase: 30_000)

        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules.first?.type, "DOMAIN-SUFFIX")
        XCTAssertEqual(rules.first?.value, "downloaded.test")
        XCTAssertEqual(rules.first?.policy, "Downloaded")
    }

    func testProfileExpandsImportedRuleSetInPlace() {
        let profile = ProxyProfile(
            rules: [
                ProxyRule(type: "RULE-SET", value: "https://example.test/rules.list", policy: "Proxies", options: [], sourceLine: 1, rawLine: "RULE-SET,https://example.test/rules.list,Proxies"),
                ProxyRule(type: "FINAL", value: "", policy: "DIRECT", options: [], sourceLine: 2, rawLine: "FINAL,DIRECT")
            ]
        )
        let imported = [
            "https://example.test/rules.list": [
                ProxyRule(type: "DOMAIN-SUFFIX", value: "expanded.test", policy: "Proxies", options: [], sourceLine: 100, rawLine: "DOMAIN-SUFFIX,expanded.test")
            ]
        ]

        let expanded = profile.expandedRules(ruleSetsByURL: imported)

        XCTAssertEqual(expanded.map(\.type), ["DOMAIN-SUFFIX", "FINAL"])
        XCTAssertEqual(RuleEngine(rules: expanded).firstMatch(for: "www.expanded.test")?.rule.policy, "Proxies")
    }
}

private final class RuleSetHTTPServer: @unchecked Sendable {
    let port: Int
    private let fd: Int32
    private var task: Task<Void, Never>?

    init(body: String) throws {
        let socketFD = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard socketFD >= 0 else {
            throw ProxyServerError.posix("socket", errno)
        }

        var enabled: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let saved = errno
            close(socketFD)
            throw ProxyServerError.posix("bind", saved)
        }

        guard listen(socketFD, 8) == 0 else {
            let saved = errno
            close(socketFD)
            throw ProxyServerError.posix("listen", saved)
        }

        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &length)
            }
        }
        guard nameResult == 0 else {
            let saved = errno
            close(socketFD)
            throw ProxyServerError.posix("getsockname", saved)
        }

        fd = socketFD
        port = Int(in_port_t(bigEndian: bound.sin_port))
        let responseBody = body

        task = Task.detached(priority: .utility) { [socketFD] in
            let clientFD = accept(socketFD, nil, nil)
            guard clientFD >= 0 else { return }
            _ = readHeaderOnly(from: clientFD)
            let response = """
            HTTP/1.1 200 OK\r
            Content-Length: \(responseBody.utf8.count)\r
            Connection: close\r
            \r
            \(responseBody)
            """
            try? sendAll(response, to: clientFD)
            close(clientFD)
        }
    }

    func url(path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    func stop() {
        task?.cancel()
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }
}

private func sendAll(_ string: String, to fd: Int32) throws {
    let data = Data(string.utf8)
    try data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return }
        var sent = 0
        while sent < data.count {
            let count = send(fd, baseAddress.advanced(by: sent), data.count - sent, 0)
            guard count > 0 else {
                throw ProxyServerError.posix("send", errno)
            }
            sent += count
        }
    }
}

private func readHeaderOnly(from fd: Int32) -> String {
    var data = Data()
    let terminator = Data([13, 10, 13, 10])
    var buffer = [UInt8](repeating: 0, count: 1024)
    while data.count < 64 * 1024 {
        let count = recv(fd, &buffer, buffer.count, 0)
        guard count > 0 else { break }
        data.append(buffer, count: count)
        if data.range(of: terminator) != nil { break }
    }
    return String(data: data, encoding: .utf8) ?? ""
}
