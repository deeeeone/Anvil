import Foundation

/// Reads a pipe's output on a background thread, calling `onData` for each chunk and `onEOF` exactly once at the end.
///
/// Darwin: the readabilityHandler pattern the app has always used (empty data means EOF; the handler is cleared).
/// Elsewhere: a blocking read loop on a background thread, because swift-corelibs-foundation never delivers the
/// empty-Data EOF callback through readabilityHandler, so code waiting for EOF would hang.
/// Call sites on Darwin keep their own readabilityHandler code; PipeReader is used on other platforms.
nonisolated enum PipeReader {
    static func start(_ handle: FileHandle, onData: @escaping @Sendable (Data) -> Void, onEOF: @escaping @Sendable () -> Void) {
#if canImport(Darwin)
        handle.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; onEOF(); return }
            onData(d)
        }
#else
        // A dedicated thread, not the global dispatch pool: each reader blocks until its child exits, and a few
        // long-running children would otherwise use up the pool's threads and stall unrelated work.
        let reader = Thread {
#if os(Windows)
            // availableData returns what has arrived so far; empty means EOF.
            while true {
                let d = handle.availableData
                if d.isEmpty { break }
                onData(d)
            }
#else
            // Plain read(2), not FileHandle.read(upToCount:): on a pipe that one waits for the full count or EOF, so a
            // small reply (an MCP handshake) would sit unread. read(2) returns whatever is there; 0 is EOF, -1 an error.
            let fd = handle.fileDescriptor
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if n > 0 { onData(Data(buf[0..<n])); continue }
                if n < 0 && errno == EINTR { continue }
                break
            }
#endif
            onEOF()
        }
        reader.start()
#endif
    }
}
