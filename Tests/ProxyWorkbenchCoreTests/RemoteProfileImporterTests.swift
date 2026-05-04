import Darwin
import Foundation
@testable import ProxyWorkbenchCore
import XCTest

final class RemoteProfileImporterTests: XCTestCase {
    func testImporterDownloadsAndDecodesBase64Profile() async throws {
        let plain = """
        [Proxy]
        Direct = direct

        [Rule]
        FINAL,DIRECT
        """
        let server = try SingleResponseHTTPServer(body: Data(plain.utf8).base64EncodedString())
        defer { server.stop() }

        let imported = try await RemoteProfileImporter.importText(from: server.url(path: "/profile?token=redacted"))

        XCTAssertEqual(imported, plain)
    }

    func testImporterRejectsNonHTTPURLs() async throws {
        let url = URL(string: "file:///tmp/profile.conf")!

        do {
            _ = try await RemoteProfileImporter.importText(from: url)
            XCTFail("Expected invalid URL")
        } catch let error as RemoteProfileImporterError {
            XCTAssertEqual(error.description, "Enter an http or https URL")
        }
    }

    func testPreviewDownloadsSummaryWithoutExposingProfileText() async throws {
        let plain = """
        [Proxy]
        Proxy = trojan, proxy.example.test, 443, password=do-not-print

        [Rule]
        GEOIP,CN,DIRECT
        FINAL,Proxy
        """
        let server = try SingleResponseHTTPServer(body: plain)
        defer { server.stop() }

        let preview = try await RemoteProfilePreviewer.preview(from: server.url(path: "/subscription?token=redacted"))

        XCTAssertEqual(preview.summary.proxies, 1)
        XCTAssertEqual(preview.summary.rules, 2)
        XCTAssertEqual(preview.summary.warnings, 1)
        XCTAssertTrue(preview.warningSamples.first?.contains("GEOIP") == true)
        XCTAssertFalse(String(describing: preview).contains("do-not-print"))
    }
}

private final class SingleResponseHTTPServer: @unchecked Sendable {
    let port: Int
    private let fd: Int32
    private var task: Task<Void, Never>?

    init(body: String, status: String = "200 OK") throws {
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
            HTTP/1.1 \(status)\r
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
