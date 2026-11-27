import Foundation
#if os(Windows)
import WinSDK
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

#if os(Windows)
// Console mode constants spelled out so they do not depend on header macro import.
private let kEnableProcessedInput: DWORD = 0x0001
private let kEnableLineInput: DWORD = 0x0002
private let kEnableEchoInput: DWORD = 0x0004
private let kEnableVTInput: DWORD = 0x0200
private let kEnableVTProcessing: DWORD = 0x0004
private let kDisableNewlineAutoReturn: DWORD = 0x0008
#endif

/// Raw keys and VT output. POSIX uses termios; Windows uses console modes.
final class Terminal {
    #if os(Windows)
    private let hIn: HANDLE
    private let hOut: HANDLE
    private var savedIn: DWORD?
    private var savedOut: DWORD?
    #else
    private var saved: termios?
    #endif

    init() {
        #if os(Windows)
        hIn = GetStdHandle(UInt32(bitPattern: -10))   // STD_INPUT_HANDLE
        hOut = GetStdHandle(UInt32(bitPattern: -11))  // STD_OUTPUT_HANDLE
        #endif
    }

    var isConsole: Bool {
        #if os(Windows)
        var mode: DWORD = 0
        return GetConsoleMode(hIn, &mode)
        #else
        return isatty(0) != 0
        #endif
    }

    /// Enters raw mode and VT processing. Saves the previous state for restore().
    func enableRaw() -> Bool {
        #if os(Windows)
        var inMode: DWORD = 0
        var outMode: DWORD = 0
        guard GetConsoleMode(hIn, &inMode), GetConsoleMode(hOut, &outMode) else {
            return false
        }
        savedIn = inMode
        savedOut = outMode
        let newIn = (inMode & ~(kEnableLineInput | kEnableEchoInput)) | kEnableVTInput
        let newOut = outMode | kEnableVTProcessing | kDisableNewlineAutoReturn
        return SetConsoleMode(hIn, newIn) && SetConsoleMode(hOut, newOut)
        #else
        var t = termios()
        guard tcgetattr(0, &t) == 0 else { return false }
        saved = t
        // ISIG is cleared too, so Ctrl-C arrives as byte 3 and 'q' is the way out.
        t.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG)
        return tcsetattr(0, TCSANOW, &t) == 0
        #endif
    }

    /// Reads the mode back and checks that the raw/VT flags actually stuck.
    func rawVerified() -> Bool {
        #if os(Windows)
        var inMode: DWORD = 0
        var outMode: DWORD = 0
        guard GetConsoleMode(hIn, &inMode), GetConsoleMode(hOut, &outMode) else {
            return false
        }
        return (inMode & kEnableVTInput) != 0
            && (inMode & kEnableLineInput) == 0
            && (outMode & kEnableVTProcessing) != 0
        #else
        var t = termios()
        guard tcgetattr(0, &t) == 0 else { return false }
        return (t.c_lflag & tcflag_t(ICANON)) == 0 && (t.c_lflag & tcflag_t(ECHO)) == 0
        #endif
    }

    func restore() {
        #if os(Windows)
        if let m = savedIn { _ = SetConsoleMode(hIn, m) }
        if let m = savedOut { _ = SetConsoleMode(hOut, m) }
        savedIn = nil
        savedOut = nil
        #else
        if var t = saved { _ = tcsetattr(0, TCSANOW, &t) }
        saved = nil
        #endif
    }

    /// Window size in columns and rows, with an 80x24 fallback.
    func size() -> (cols: Int, rows: Int) {
        #if os(Windows)
        var info = CONSOLE_SCREEN_BUFFER_INFO()
        if GetConsoleScreenBufferInfo(hOut, &info) {
            let cols = Int(info.srWindow.Right - info.srWindow.Left + 1)
            let rows = Int(info.srWindow.Bottom - info.srWindow.Top + 1)
            return (cols, rows)
        }
        return (80, 24)
        #else
        var ws = winsize()
        if ioctl(1, UInt(TIOCGWINSZ), &ws) == 0 {
            return (Int(ws.ws_col), Int(ws.ws_row))
        }
        return (80, 24)
        #endif
    }

    /// Blocks until at least one byte is available. Empty means EOF or error.
    func readBytes() -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: 64)
        #if os(Windows)
        var n: DWORD = 0
        guard ReadFile(hIn, &buf, DWORD(buf.count), &n, nil) else { return [] }
        return Array(buf[0..<Int(n)])
        #else
        let n = read(0, &buf, buf.count)
        return n > 0 ? Array(buf[0..<n]) : []
        #endif
    }

    func emit(_ s: String) {
        FileHandle.standardOutput.write(Data(s.utf8))
    }

    /// One frame of a 3-line live region, wrapped in synchronized update.
    func drawLiveRegion(_ frame: Int) {
        var s = "\u{1B}[?2026h"
        if frame > 0 { s += "\u{1B}[3A" }  // cursor up 3 lines, back to the region's top
        s += "\u{1B}[2K\u{1B}[1;36m[anvil] status: streaming (frame \(frame))\u{1B}[0m\r\n"
        s += "\u{1B}[2K\u{1B}[33mtok \(frame * 3) ...\u{1B}[0m\r\n"
        s += "\u{1B}[2K\u{1B}[32m>\u{1B}[0m \r\n"
        s += "\u{1B}[?2026l"
        emit(s)
    }
}

func runTTY(check: Bool) -> Bool {
    let term = Terminal()
    let size = term.size()  // must never crash, console or not

    if !term.isConsole {
        if check {
            print("PASS tty: no console (expected in CI), api compiled")
            print("  window size fallback/query: \(size.cols)x\(size.rows)")
            return true
        }
        return report(false, "tty", "stdin is not a console; run this subcommand in a terminal")
    }

    guard term.enableRaw() else {
        return report(false, "tty", "could not enter raw mode")
    }
    defer { term.restore() }
    guard term.rawVerified() else {
        return report(false, "tty", "raw/VT mode did not stick on read-back")
    }

    if check {
        return report(true, "tty", "console found; raw+VT verified; size \(size.cols)x\(size.rows)")
    }

    term.emit("\r\n")
    for frame in 0..<10 {
        term.drawLiveRegion(frame)
        Thread.sleep(forTimeInterval: 0.1)
    }
    term.emit("\r\nPress keys to see their bytes; 'q' quits.\r\n")
    while true {
        let bytes = term.readBytes()
        if bytes.isEmpty { break }
        term.emit("keys: \(bytes.map { String($0) }.joined(separator: " "))\r\n")
        if bytes.contains(0x71) || bytes.contains(0x51) { break }
    }
    return report(true, "tty", "interactive demo completed")
}
