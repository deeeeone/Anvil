import Foundation

/// Reads a pipe's output on a background thread, calling `onData` for each chunk and `onEOF` exactly once at the end.
///
/// Darwin: the readabilityHandler pattern the app has always used (empty data means EOF; the handler is cleared).
/// Elsewhere: a blocking read loop on a background queue, because swift-corelibs-foundation never delivers the
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
        DispatchQueue.global().async {
            while true {
                // read(upToCount:) returns nil or empty at EOF; a read error (handle closed under us) also ends the loop.
                guard let d = try? handle.read(upToCount: 65536), !d.isEmpty else { break }
                onData(d)
            }
            onEOF()
        }
#endif
    }
}
