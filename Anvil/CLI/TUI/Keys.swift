import Foundation

/// One decoded keypress. The terminal sends bytes; this turns them into the handful of keys the editor cares about.
/// Why: raw bytes are ambiguous (ESC alone versus the start of an arrow key, CR versus LF, UTF-8 split across reads),
/// so decoding lives in one pure place that tests can drive without a terminal.
nonisolated enum Key: Equatable, Sendable {
    case char(Character)
    case enter
    case altEnter
    case tab
    case shiftTab
    case backspace
    case delete
    case left, right, up, down
    case home, end
    case pageUp, pageDown
    case escape
    /// Control letter, lower case: ctrl("c") is byte 0x03.
    case ctrl(Character)
    /// Text pasted with bracketed paste, already decoded and with CRLF/CR normalised to LF.
    case paste(String)
    case unknown
}

/// Turns a byte stream into keys. Feed it whatever `read` returned; partial UTF-8 sequences, escape sequences and
/// bracketed pastes may be split across calls and are held until complete. A lone ESC is ambiguous, so it is held
/// until `flushPendingEscape()` (the reader calls it after about 30 ms with no further bytes).
nonisolated struct KeyParser {
    private var pending: [UInt8] = []
    /// Non-nil while inside a bracketed paste: the bytes collected so far.
    private var pasteBytes: [UInt8]?

    private static let pasteStart: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]  // ESC [200~
    private static let pasteEnd: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]    // ESC [201~

    /// True when a lone ESC is waiting for more bytes. The reader uses it to choose a short poll timeout.
    var hasPendingEscape: Bool { pasteBytes == nil && pending.first == 0x1B }

    mutating func feed(_ bytes: [UInt8]) -> [Key] {
        pending.append(contentsOf: bytes)
        var out: [Key] = []
        var i = 0
        let n = pending.count

        scan: while i < n {
            if pasteBytes != nil {
                if let end = KeyParser.find(KeyParser.pasteEnd, in: pending, from: i) {
                    pasteBytes! += pending[i..<end]
                    out.append(.paste(KeyParser.normalizeNewlines(String(decoding: pasteBytes!, as: UTF8.self))))
                    pasteBytes = nil
                    i = end + KeyParser.pasteEnd.count
                    continue
                }
                // Keep the last few bytes: they may be the start of the end marker split across reads.
                let safe = max(i, n - (KeyParser.pasteEnd.count - 1))
                pasteBytes! += pending[i..<safe]
                i = safe
                break scan
            }

            let b = pending[i]
            if b == 0x1B {
                guard i + 1 < n else { break scan }  // lone ESC: wait for more bytes or a flush
                let c = pending[i + 1]
                if c == 0x5B {  // CSI: ESC [ params final
                    var j = i + 2
                    while j < n && !(0x40...0x7E).contains(pending[j]) { j += 1 }
                    if j >= n {
                        if n - i > 32 { i = n; out.append(.unknown) }  // garbage that never ends: drop it
                        break scan
                    }
                    let params = Array(pending[(i + 2)..<j])
                    let final = pending[j]
                    i = j + 1
                    if final == 0x7E && params == Array("200".utf8) {
                        pasteBytes = []
                        continue
                    }
                    out.append(KeyParser.csiKey(params: params, final: final))
                    continue
                }
                if c == 0x4F {  // SS3: ESC O x
                    guard i + 2 < n else { break scan }
                    let key = KeyParser.ss3Key(pending[i + 2])
                    out.append(key)
                    i += 3
                    continue
                }
                if c == 0x0D {  // ESC CR: Alt+Enter
                    out.append(.altEnter)
                    i += 2
                    continue
                }
                if c == 0x1B {
                    out.append(.escape)
                    i += 1
                    continue
                }
                if (0x20...0x7E).contains(c) {  // Alt+printable: not used by the editor
                    out.append(.unknown)
                    i += 2
                    continue
                }
                out.append(.escape)
                i += 1
                continue
            }

            switch b {
            case 0x0D, 0x0A:
                out.append(.enter)
                i += 1
            case 0x09:
                out.append(.tab)
                i += 1
            case 0x7F, 0x08:
                out.append(.backspace)
                i += 1
            case 0x01...0x1A:
                out.append(.ctrl(Character(Unicode.Scalar(b + 0x60))))
                i += 1
            case 0x00, 0x1C...0x1F:
                out.append(.unknown)
                i += 1
            default:
                if b < 0x80 {
                    out.append(.char(Character(Unicode.Scalar(b))))
                    i += 1
                    continue
                }
                let length: Int
                switch b {
                case 0xC0...0xDF: length = 2
                case 0xE0...0xEF: length = 3
                case 0xF0...0xF7: length = 4
                default:
                    out.append(.unknown)
                    i += 1
                    continue
                }
                if i + length > n { break scan }  // incomplete sequence: wait for the rest
                let text = String(decoding: pending[i..<(i + length)], as: UTF8.self)
                if text.unicodeScalars.contains("\u{FFFD}") {
                    out.append(.unknown)
                } else {
                    for ch in text { out.append(.char(ch)) }
                }
                i += length
            }
        }

        pending.removeFirst(min(i, pending.count))
        return out
    }

    /// Emits a held lone ESC as `.escape`. Any other incomplete sequence has its ESC dropped and the rest re-parsed.
    mutating func flushPendingEscape() -> [Key] {
        guard pasteBytes == nil, pending.first == 0x1B else { return [] }
        if pending.count == 1 {
            pending.removeAll()
            return [.escape]
        }
        pending.removeFirst()
        return [.escape] + feed([])
    }

    private static func csiKey(params: [UInt8], final: UInt8) -> Key {
        switch final {
        case 0x41: return .up
        case 0x42: return .down
        case 0x43: return .right
        case 0x44: return .left
        case 0x48: return .home
        case 0x46: return .end
        case 0x5A: return .shiftTab
        case 0x7E:
            // ESC [ n ~ and ESC [ n ; mod ~: the modifier is ignored, the first number names the key.
            let head = params.prefix(while: { $0 != 0x3B })
            switch Int(String(decoding: head, as: UTF8.self)) ?? -1 {
            case 1, 7: return .home
            case 4, 8: return .end
            case 3: return .delete
            case 5: return .pageUp
            case 6: return .pageDown
            default: return .unknown
            }
        default:
            // Modifier forms such as ESC [1;5C arrive with a final letter, so the base key still applies.
            return .unknown
        }
    }

    private static func ss3Key(_ final: UInt8) -> Key {
        switch final {
        case 0x41: return .up
        case 0x42: return .down
        case 0x43: return .right
        case 0x44: return .left
        case 0x48: return .home
        case 0x46: return .end
        default: return .unknown
        }
    }

    private static func find(_ needle: [UInt8], in haystack: [UInt8], from start: Int) -> Int? {
        guard haystack.count >= needle.count else { return nil }
        var k = start
        while k + needle.count <= haystack.count {
            if haystack[k] == needle[0] && Array(haystack[k..<(k + needle.count)]) == needle { return k }
            k += 1
        }
        return nil
    }

    /// CRLF and lone CR both become LF, so pasted Windows text does not double its line breaks.
    static func normalizeNewlines(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var previousWasCR = false
        for scalar in s.unicodeScalars {
            if scalar == "\r" {
                out.append("\n")
                previousWasCR = true
                continue
            }
            if scalar == "\n" && previousWasCR {
                previousWasCR = false
                continue
            }
            previousWasCR = false
            out.append(scalar)
        }
        return String(out)
    }
}
