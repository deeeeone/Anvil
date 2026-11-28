import Foundation
#if canImport(FoundationNetworking) && !canImport(Darwin)
// swift-corelibs-foundation keeps URLSession and URLRequest in a separate module. Re-export it here so every file that
// imports Foundation through this module sees the same API as on Apple platforms. Apple platforms never take this branch.
@_exported import FoundationNetworking
#endif

/// Process-wide platform setup.
nonisolated enum Platform {
    /// Writing to a child whose stdin is closed raises SIGPIPE, which kills the process by default on Linux.
    /// Darwin avoids it per descriptor (F_SETNOSIGPIPE at the pipe call sites), so this does nothing there.
    /// The CLI's main must call this once at startup; nothing in the app calls it yet.
    static func ignoreSIGPIPE() {
#if canImport(Darwin)
        // Intentionally empty: Darwin uses F_SETNOSIGPIPE on each pipe.
#elseif os(Windows)
        // Windows has no SIGPIPE: a write to a closed pipe fails with an error instead.
#else
        signal(SIGPIPE, SIG_IGN)
#endif
    }
}
