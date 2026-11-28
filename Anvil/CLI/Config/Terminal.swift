import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import WinSDK
#endif

/// Terminal helpers: is a stream a terminal, and reading a secret without echoing it.
nonisolated enum Terminal {
    static var stdinIsTTY: Bool { isTTY(0) }
    static var stdoutIsTTY: Bool { isTTY(1) }
    static var stderrIsTTY: Bool { isTTY(2) }

    static func isTTY(_ fd: Int32) -> Bool {
#if os(Windows)
        return _isatty(fd) != 0
#else
        return isatty(fd) != 0
#endif
    }

    /// Everything on stdin, decoded as UTF-8 (used for a piped prompt).
    static func readAllStdin() -> String {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }

    /// Reads one line with echo off when stdin is a terminal; otherwise reads one line as it is.
    /// Returns nil at end of input. The terminal state is restored before returning.
    static func readSecret(prompt: String) -> String? {
        guard stdinIsTTY else { return readPlainLine() }
        FileHandle.standardError.write(Data(prompt.utf8))
        let restore = EchoOff.begin()
        let line = readPlainLine()
        restore()
        FileHandle.standardError.write(Data("\n".utf8))
        return line
    }

    /// A plain line from stdin, without the newline. Nil at end of input.
    static func readPlainLine() -> String? {
        guard let line = Swift.readLine(strippingNewline: true) else { return nil }
        return line
    }

    /// Writes a prompt to stderr and reads a plain (echoed) line.
    static func ask(_ prompt: String) -> String? {
        FileHandle.standardError.write(Data(prompt.utf8))
        return readPlainLine()
    }
}

/// Turns terminal echo off and back on. On POSIX the restore also runs on Ctrl-C, so the terminal is never left
/// without echo. On Windows the console mode is restored the same way on normal return.
nonisolated enum EchoOff {
#if os(Windows)
    static func begin() -> () -> Void {
        let h = GetStdHandle(STD_INPUT_HANDLE)
        var mode: DWORD = 0
        guard GetConsoleMode(h, &mode) else { return {} }
        _ = SetConsoleMode(h, mode & ~DWORD(ENABLE_ECHO_INPUT))
        return { _ = SetConsoleMode(h, mode) }
    }
#else
    /// The original settings, kept for the signal handler (a C function cannot capture anything).
    nonisolated(unsafe) fileprivate static var original = termios()
    nonisolated(unsafe) fileprivate static var previousINT: (@convention(c) (Int32) -> Void)?

    static func begin() -> () -> Void {
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { return {} }
        var quiet = original
        quiet.c_lflag &= ~tcflag_t(ECHO)
        guard tcsetattr(STDIN_FILENO, TCSANOW, &quiet) == 0 else { return {} }
        previousINT = signal(SIGINT) { _ in
            tcsetattr(STDIN_FILENO, TCSANOW, &EchoOff.original)
            _exit(130)
        }
        return {
            tcsetattr(STDIN_FILENO, TCSANOW, &original)
            signal(SIGINT, EchoOff.previousINT)
        }
    }
#endif
}
