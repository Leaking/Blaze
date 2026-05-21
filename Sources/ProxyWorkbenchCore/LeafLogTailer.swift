import Darwin
import Foundation
import os.log

private let leafTailerLogger = Logger(subsystem: "com.chenhuazhao.blaze", category: "LeafLogTailer")

/// Tails leaf's log file and emits each `handled` dispatcher line as a
/// `ProxyServerEvent` into the shared `ProxyEventStore`. Restores the
/// per-connection traffic feed the UI relied on when the Swift listener
/// was alive. Restartable across leaf relaunches — the tailer follows
/// the same path; when leaf truncates/appends, the tailer keeps reading
/// from the current offset.
public actor LeafLogTailer {
    private let logURL: URL
    private let store: ProxyEventStore
    private var task: Task<Void, Never>?

    public init(logURL: URL, store: ProxyEventStore) {
        self.logURL = logURL
        self.store = store
    }

    public func start() {
        task?.cancel()
        let path = logURL.path
        let store = store
        task = Task.detached(priority: .utility) {
            await Self.runLoop(path: path, store: store)
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    private static func runLoop(path: String, store: ProxyEventStore) async {
        var fd: Int32 = -1
        var offset: off_t = 0
        var leftover = Data()
        let pollInterval: UInt64 = 250_000_000 // 250ms — fast enough to feel live, cheap enough to ignore
        var lastInode: ino_t = 0

        while !Task.isCancelled {
            if fd < 0 {
                fd = open(path, O_RDONLY | O_NONBLOCK)
                if fd < 0 {
                    try? await Task.sleep(nanoseconds: pollInterval)
                    continue
                }
                // Start at end of file so we don't replay an existing log.
                // Subsequent appends will be streamed.
                offset = lseek(fd, 0, SEEK_END)
                if offset < 0 { offset = 0 }
                var statBuf = stat()
                if fstat(fd, &statBuf) == 0 { lastInode = statBuf.st_ino }
            }

            // Detect log rotation / file replacement.
            var statBuf = stat()
            if stat(path, &statBuf) == 0, statBuf.st_ino != lastInode {
                close(fd)
                fd = -1
                offset = 0
                leftover.removeAll(keepingCapacity: true)
                continue
            }

            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            let readCount = read(fd, &buffer, buffer.count)
            if readCount > 0 {
                offset += off_t(readCount)
                leftover.append(buffer, count: readCount)
                while let newlineIdx = leftover.firstIndex(of: 0x0A) {
                    let line = leftover.prefix(upTo: newlineIdx)
                    leftover.removeSubrange(0...newlineIdx)
                    if line.isEmpty { continue }
                    if let event = LeafLogParser.parseHandled(Data(line)) {
                        await store.append(event)
                    }
                }
            } else {
                try? await Task.sleep(nanoseconds: pollInterval)
            }
        }
        if fd >= 0 { close(fd) }
    }
}

/// Stateless parser for the subset of leaf's dispatcher log we surface to
/// the UI. Public for testability.
public enum LeafLogParser {
    /// Match the structured fields of a `handled` line, after stripping
    /// ANSI escape sequences. Example input (de-ansied):
    ///
    ///   2026-05-21T03:44:04.123Z  INFO leaf::app::dispatcher: handled
    ///   src=127.0.0.1 proto=tcp in=socks out=HK10 connect=86ms
    ///   dst=api.telegram.org:443
    public static func parseHandled(_ line: Data) -> ProxyServerEvent? {
        guard let rawString = String(data: line, encoding: .utf8) else { return nil }
        let stripped = stripAnsi(rawString)
        guard let handledRange = stripped.range(of: "handled ") else { return nil }
        let tail = stripped[handledRange.upperBound...]
        guard tail.contains("in=") else { return nil }

        var fields: [String: String] = [:]
        var current = tail.startIndex
        while current < tail.endIndex {
            // Skip whitespace
            while current < tail.endIndex, tail[current].isWhitespace { current = tail.index(after: current) }
            guard current < tail.endIndex else { break }
            guard let eq = tail[current...].firstIndex(of: "=") else { break }
            let key = String(tail[current..<eq])
            let valueStart = tail.index(after: eq)
            // out= can contain spaces (e.g. emoji + spaces), so we scan up to
            // the next " <known-key>=" rather than the next whitespace.
            var valueEnd = valueStart
            while valueEnd < tail.endIndex {
                if tail[valueEnd] == " " {
                    let probeStart = tail.index(after: valueEnd)
                    if probeStart >= tail.endIndex { break }
                    // Look ahead for "<word>="
                    var probe = probeStart
                    while probe < tail.endIndex, tail[probe] != "=" && tail[probe] != " " { probe = tail.index(after: probe) }
                    if probe < tail.endIndex, tail[probe] == "=" {
                        break  // next key starts at probeStart
                    }
                }
                valueEnd = tail.index(after: valueEnd)
            }
            let value = String(tail[valueStart..<valueEnd]).trimmingCharacters(in: .whitespaces)
            fields[key] = value
            current = valueEnd
        }

        guard let dst = fields["dst"], dst.contains(":") else { return nil }
        let parts = dst.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let host = String(parts[0])
        let port = parts.count > 1 ? Int(parts[1]) ?? 0 : 0

        let outbound = fields["out"] ?? "DIRECT"
        let connect = fields["connect"] ?? ""
        let inbound = fields["in"] ?? ""
        let proto = fields["proto"] ?? "tcp"
        let method = inbound == "socks" ? "SOCKS5" : (inbound == "http" ? "HTTP" : "PROXY")

        var noteParts: [String] = []
        if !proto.isEmpty { noteParts.append("proto=\(proto)") }
        if !inbound.isEmpty { noteParts.append("in=\(inbound)") }
        if !connect.isEmpty { noteParts.append("connect=\(connect)") }

        return ProxyServerEvent(
            method: method,
            target: dst,
            host: host,
            port: port,
            policy: outbound,
            status: "Connected",
            rule: "leaf",
            note: noteParts.joined(separator: " ")
        )
    }

    /// Strip ANSI CSI sequences (`\u{1B}[...m`) from a string. leaf colourises
    /// its tracing output by default and the raw bytes hit the file.
    public static func stripAnsi(_ input: String) -> String {
        var result = String()
        result.reserveCapacity(input.count)
        var iterator = input.makeIterator()
        while let ch = iterator.next() {
            if ch == "\u{1B}" {
                // Consume until 'm' (or end)
                while let next = iterator.next() {
                    if next == "m" { break }
                }
                continue
            }
            result.append(ch)
        }
        return result
    }
}

private extension Character {
    var isWhitespace: Bool {
        self == " " || self == "\t" || self == "\r"
    }
}
