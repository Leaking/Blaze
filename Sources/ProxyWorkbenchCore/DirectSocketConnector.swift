import Darwin
import Foundation

enum DirectSocketConnector {
    static func connect(host: String, port: Int) async throws -> Int32 {
        if !host.isIPAddressLiteral {
            for address in await DNSOverHTTPSJSONResolver.resolveA(host) {
                if let fd = try? connectAddress(host: address, port: port) {
                    return fd
                }
            }
        }
        return try connectAddress(host: host, port: port)
    }

    private static func connectAddress(host: String, port: Int) throws -> Int32 {
        var hints = addrinfo(
            ai_flags: AI_NUMERICSERV,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var info: UnsafeMutablePointer<addrinfo>?
        let lookup = getaddrinfo(host, String(port), &hints, &info)
        guard lookup == 0, let first = info else {
            throw ProxyServerError.lookup(String(cString: gai_strerror(lookup)))
        }
        defer { freeaddrinfo(first) }

        var current: UnsafeMutablePointer<addrinfo>? = first
        var savedErrno: Int32 = 0
        while let address = current {
            let fd = socket(address.pointee.ai_family, address.pointee.ai_socktype, address.pointee.ai_protocol)
            if fd >= 0 {
                if let socketAddress = address.pointee.ai_addr {
                    ProxySocketOptions.prepareOutbound(fd, destination: socketAddress)
                } else {
                    ProxySocketOptions.prepare(fd)
                }
                if Darwin.connect(fd, address.pointee.ai_addr, address.pointee.ai_addrlen) == 0 {
                    return fd
                }
                savedErrno = errno
                close(fd)
            }
            current = address.pointee.ai_next
        }
        throw ProxyServerError.posix("connect", savedErrno)
    }
}
