import Darwin

enum ProxySocketOptions {
    static func prepare(_ fd: Int32) {
        disableSigPipe(fd)
    }

    static func prepareOutbound(_ fd: Int32, destination: UnsafePointer<sockaddr>) {
        prepare(fd)
        guard shouldBindToPhysicalInterface(destination),
              let interfaceIndex = PrimaryPhysicalInterface.index()
        else {
            return
        }

        var index = interfaceIndex
        switch Int32(destination.pointee.sa_family) {
        case AF_INET:
            _ = setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size))
        case AF_INET6:
            _ = setsockopt(fd, IPPROTO_IPV6, IPV6_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size))
        default:
            break
        }
    }

    private static func disableSigPipe(_ fd: Int32) {
        var enabled: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func shouldBindToPhysicalInterface(_ destination: UnsafePointer<sockaddr>) -> Bool {
        switch Int32(destination.pointee.sa_family) {
        case AF_INET:
            let address = destination.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            return (address & 0xFF00_0000) != 0x7F00_0000
        case AF_INET6:
            let address = destination.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                $0.pointee.sin6_addr
            }
            return !withUnsafeBytes(of: address.__u6_addr.__u6_addr8) { rawBuffer in
                let bytes = rawBuffer.bindMemory(to: UInt8.self)
                return bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
            }
        default:
            return false
        }
    }
}

private enum PrimaryPhysicalInterface {
    static func index() -> UInt32? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else {
            return nil
        }
        defer { freeifaddrs(first) }

        var fallback: UInt32?
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let pointer = current {
            defer { current = pointer.pointee.ifa_next }
            guard let address = pointer.pointee.ifa_addr,
                  Int32(address.pointee.sa_family) == AF_INET,
                  isUsable(flags: pointer.pointee.ifa_flags)
            else {
                continue
            }

            let name = String(cString: pointer.pointee.ifa_name)
            guard !isVirtualOrSpecial(name) else { continue }
            let interfaceIndex = if_nametoindex(name)
            guard interfaceIndex != 0 else { continue }
            if name.hasPrefix("en") {
                return interfaceIndex
            }
            if fallback == nil {
                fallback = interfaceIndex
            }
        }
        return fallback
    }

    private static func isUsable(flags: UInt32) -> Bool {
        (flags & UInt32(IFF_UP)) != 0
            && (flags & UInt32(IFF_RUNNING)) != 0
            && (flags & UInt32(IFF_LOOPBACK)) == 0
    }

    private static func isVirtualOrSpecial(_ name: String) -> Bool {
        let prefixes = ["lo", "utun", "ipsec", "gif", "stf", "awdl", "llw", "bridge", "p2p", "anpi"]
        return prefixes.contains { name.hasPrefix($0) }
    }
}
