import Darwin

enum ProxySocketOptions {
    static func prepare(_ fd: Int32) {
        disableSigPipe(fd)
    }

    private static func disableSigPipe(_ fd: Int32) {
        var enabled: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    }
}
