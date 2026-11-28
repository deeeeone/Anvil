import Dispatch
import Foundation
#if os(Windows)
import WinSDK
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// Named TUITerminal rather than Terminal: AnvilCore already has a `Terminal` enum (CLI/Config).

#if os(Windows)
nonisolated private let kEnableProcessedInput: DWORD = 0x0001
nonisolated private let kEnableLineInput: DWORD = 0x0002
nonisolated private let kEnableEchoInput: DWORD = 0x0004
nonisolated private let kEnableVirtualTerminalInput: DWORD = 0x0200
nonisolated private let kEnableVirtualTerminalProcessing: DWORD = 0x0004
nonisolated private let kDisableNewlineAutoReturn: DWORD = 0x0008
nonisolated private let kWaitTimeout: DWORD = 0x0102
#endif

/// Owns the process's terminal state: raw mode, the size, key input, and writes.
///
/// Why raw mode is process-wide: the terminal modes outlive any one object, and a Ctrl-C that kills the process must
/// still leave the user's shell usable. So the saved state lives in `TerminalGuard.shared`, which the atexit hook and
/// the signal handlers reach too. Restore is idempotent.
/// Why one write per frame: one syscall per frame keeps the frame from tearing across several flushes.
nonisolated final class TUITerminal: @unchecked Sendable {
    #if os(Windows)
    private let hIn: HANDLE
    private let hOut: HANDLE
    #endif
    private var resizeSource: DispatchSourceSignal?
    private var resizeTimer: DispatchSourceTimer?
    private var lastSize: (cols: Int, rows: Int)?

    /// Called on the main queue when the window size changes. POSIX: SIGWINCH. Windows: a 250 ms size poll, because
    /// the console has no equivalent signal.
    var onResize: (() -> Void)? {
        didSet { if onResize != nil { installResizeWatch() } }
    }

    init() {
        #if os(Windows)
        hIn = GetStdHandle(UInt32(bitPattern: -10))   // STD_INPUT_HANDLE
        hOut = GetStdHandle(UInt32(bitPattern: -11))  // STD_OUTPUT_HANDLE
        #endif
    }

    /// Whether stdout is a terminal. Used to decide on color.
    static var outputIsTTY: Bool {
        #if os(Windows)
        var mode: DWORD = 0
        return GetConsoleMode(GetStdHandle(UInt32(bitPattern: -11)), &mode)
        #else
        return isatty(1) != 0
        #endif
    }

    var isInputTTY: Bool {
        #if os(Windows)
        var mode: DWORD = 0
        return GetConsoleMode(hIn, &mode)
        #else
        return isatty(0) != 0
        #endif
    }

    /// Switches the input to raw mode and output to VT sequences. Returns false when that fails. Ctrl-C arrives as
    /// byte 0x03 instead of SIGINT; the signal handlers below cover `kill`.
    func enterRawMode() -> Bool {
        if TerminalGuard.shared.isArmed { return true }
        #if os(Windows)
        var inMode: DWORD = 0
        var outMode: DWORD = 0
        guard GetConsoleMode(hIn, &inMode), GetConsoleMode(hOut, &outMode) else { return false }
        let newIn = (inMode & ~(kEnableProcessedInput | kEnableLineInput | kEnableEchoInput)) | kEnableVirtualTerminalInput
        let newOut = outMode | kEnableVirtualTerminalProcessing | kDisableNewlineAutoReturn
        guard SetConsoleMode(hIn, newIn) else { return false }
        guard SetConsoleMode(hOut, newOut) else {
            _ = SetConsoleMode(hIn, inMode)
            return false
        }
        let input = hIn
        let output = hOut
        TerminalGuard.shared.arm {
            writeHandle(output, "\u{1B}[?2004l\u{1B}[0m\u{1B}[?25h")
            _ = SetConsoleMode(input, inMode)
            _ = SetConsoleMode(output, outMode)
        }
        writeHandle(output, "\u{1B}[?2004h")
        return true
        #else
        var t = termios()
        guard tcgetattr(0, &t) == 0 else { return false }
        let original = t
        t.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG | IEXTEN)
        t.c_iflag &= ~tcflag_t(IXON)  // OPOST stays on so "\n" still moves down a line
        guard tcsetattr(0, TCSANOW, &t) == 0 else { return false }
        TerminalGuard.shared.arm {
            writeFD(1, "\u{1B}[?2004l\u{1B}[0m\u{1B}[?25h")
            var saved = original
            _ = tcsetattr(0, TCSANOW, &saved)
        }
        writeFD(1, "\u{1B}[?2004h")
        installPOSIXExitHooks()
        return true
        #endif
    }

    /// Puts the terminal back as it was. Safe to call any number of times, from any thread.
    func restore() {
        TerminalGuard.shared.restore()
    }

    /// Window size as (columns, rows). Falls back to $COLUMNS/$LINES, then 80x24. A pseudo-terminal can report 0x0,
    /// which counts as no answer.
    func size() -> (cols: Int, rows: Int) {
        #if os(Windows)
        var info = CONSOLE_SCREEN_BUFFER_INFO()
        if GetConsoleScreenBufferInfo(hOut, &info) {
            let cols = Int(info.srWindow.Right - info.srWindow.Left + 1)
            let rows = Int(info.srWindow.Bottom - info.srWindow.Top + 1)
            if cols > 0 && rows > 0 { return (cols, rows) }
        }
        #else
        for fd: Int32 in [1, 0] {
            var ws = winsize()
            if ioctl(fd, UInt(TIOCGWINSZ), &ws) == 0, ws.ws_col > 0, ws.ws_row > 0 {
                return (Int(ws.ws_col), Int(ws.ws_row))
            }
        }
        #endif
        let cols = TUIEnv.value("COLUMNS").flatMap { Int($0) } ?? 0
        let rows = TUIEnv.value("LINES").flatMap { Int($0) } ?? 0
        return (cols > 0 ? cols : 80, rows > 0 ? rows : 24)
    }

    /// Writes the whole string in one call (looping only on partial writes).
    func write(_ s: String) {
        #if os(Windows)
        writeHandle(hOut, s)
        #else
        writeFD(1, s)
        #endif
    }

    /// Decoded keys from the terminal. A reader thread blocks on input; it polls with a 30 ms timeout while a lone
    /// ESC is pending, so the ESC can be flushed as Escape. Finishing the stream stops the thread.
    func keys() -> AsyncStream<Key> {
        AsyncStream(Key.self) { continuation in
            let stop = ReaderStop()
            continuation.onTermination = { _ in stop.stop() }
            let thread = Thread { [self] in
                self.readLoop(continuation, stop)
            }
            thread.name = "anvil.tui.keys"
            thread.start()
        }
    }

    nonisolated private func readLoop(_ out: AsyncStream<Key>.Continuation, _ stop: ReaderStop) {
        var parser = KeyParser()
        var buffer = [UInt8](repeating: 0, count: 256)
        #if os(Windows)
        let input = hIn
        while !stop.isStopped {
            let wait = WaitForSingleObject(input, parser.hasPendingEscape ? 30 : 200)
            if wait == kWaitTimeout {
                for key in parser.flushPendingEscape() { out.yield(key) }
                continue
            }
            if wait != 0 { break }
            var count: DWORD = 0
            guard ReadFile(input, &buffer, DWORD(buffer.count), &count, nil) else { break }
            if count == 0 { continue }
            for key in parser.feed(Array(buffer[0..<Int(count)])) { out.yield(key) }
        }
        #else
        while !stop.isStopped {
            var pfd = pollfd(fd: 0, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, parser.hasPendingEscape ? 30 : 200)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 {
                for key in parser.flushPendingEscape() { out.yield(key) }
                continue
            }
            let n = read(0, &buffer, buffer.count)
            if n < 0 {
                if errno == EINTR { continue }
                break
            }
            if n == 0 { break }
            for key in parser.feed(Array(buffer[0..<n])) { out.yield(key) }
        }
        #endif
        for key in parser.flushPendingEscape() { out.yield(key) }
        out.finish()
    }

    nonisolated private func installResizeWatch() {
        #if os(Windows)
        guard resizeTimer == nil else { return }
        lastSize = size()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = self.size()
            if let last = self.lastSize, last.cols != now.cols || last.rows != now.rows {
                self.lastSize = now
                self.onResize?()
            }
        }
        timer.resume()
        resizeTimer = timer
        #else
        guard resizeSource == nil else { return }
        _ = signal(SIGWINCH, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
        source.setEventHandler { [weak self] in self?.onResize?() }
        source.resume()
        resizeSource = source
        #endif
    }

    #if !os(Windows)
    nonisolated private func installPOSIXExitHooks() {
        TerminalGuard.shared.installHooksOnce {
            // atexit takes a C function, so the closure may not capture; it reaches the guard through its static.
            _ = atexit { TerminalGuard.shared.restore() }
            // A caught signal (not SIG_IGN) resets to default across exec, so child processes keep their normal
            // SIGTERM. The no-op handler only makes the signal reach the dispatch source.
            for (sig, code) in [(SIGINT, Int32(130)), (SIGTERM, Int32(143)), (SIGHUP, Int32(129))] {
                _ = signal(sig) { _ in }
                let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
                source.setEventHandler {
                    TerminalGuard.shared.restore()
                    exit(code)
                }
                source.resume()
                TerminalGuard.shared.retain(source)
            }
        }
    }
    #endif
}

/// Process-wide restore hook. Holds one action that puts the terminal back, taken exactly once.
nonisolated final class TerminalGuard: @unchecked Sendable {
    static let shared = TerminalGuard()

    private let lock = NSLock()
    private var restoreAction: (() -> Void)?
    private var hooksInstalled = false
    private var retained: [AnyObject] = []

    func arm(_ action: @escaping () -> Void) {
        lock.lock()
        restoreAction = action
        lock.unlock()
    }

    var isArmed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return restoreAction != nil
    }

    /// Runs the restore action if one is armed. Idempotent: the action is taken out under the lock, so a second call
    /// (say, from atexit after a signal handler) does nothing.
    func restore() {
        lock.lock()
        let action = restoreAction
        restoreAction = nil
        lock.unlock()
        action?()
    }

    func installHooksOnce(_ install: () -> Void) {
        lock.lock()
        let first = !hooksInstalled
        hooksInstalled = true
        lock.unlock()
        if first { install() }
    }

    func retain(_ object: AnyObject) {
        lock.lock()
        retained.append(object)
        lock.unlock()
    }
}

/// Stops the key reader thread once the consumer is gone.
nonisolated final class ReaderStop: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
}

/// Writes all bytes of `s` to a POSIX file descriptor, retrying partial writes and EINTR.
nonisolated fileprivate func writeFD(_ fd: Int32, _ s: String) {
    let bytes = Array(s.utf8)
    bytes.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            #if canImport(Darwin)
            let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
            #else
            let n = Glibc.write(fd, raw.baseAddress! + offset, raw.count - offset)
            #endif
            if n < 0 {
                if errno == EINTR { continue }
                return
            }
            offset += n
        }
    }
}

#if os(Windows)
/// Writes all bytes of `s` to a console handle, retrying partial writes.
nonisolated fileprivate func writeHandle(_ handle: HANDLE, _ s: String) {
    let bytes = Array(s.utf8)
    bytes.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            var written: DWORD = 0
            let chunk = UnsafeRawPointer(raw.baseAddress! + offset)
            guard WriteFile(handle, chunk, DWORD(raw.count - offset), &written, nil), written > 0 else { return }
            offset += Int(written)
        }
    }
}
#endif
