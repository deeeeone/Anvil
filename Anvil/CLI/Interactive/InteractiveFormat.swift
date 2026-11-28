import Foundation

/// Pure formatting for the interactive session: diffs, the permission choice keys, and the status line.
/// Everything here returns strings, so the rules can be tested without a terminal.

// MARK: - Diffs

enum DiffView {
    /// A compact colored diff for one file: a header, then `+`/`-` rows with context dim. Shows at most `cap` rows,
    /// then `… N more lines`. With `color` false the same text comes back without any escape codes.
    static func lines(_ d: FileDiff, color: Bool, cap: Int = 60) -> [String] {
        let stat = d.isNew ? "new, +\(d.added)" : d.isDeleted ? "deleted" : "+\(d.added) −\(d.removed)"
        var out = [paint("1", "── \(d.path)  \(stat)", color)]
        let rows: [String] = DiffEngine.parseUnified(d.unified).map { line in
            switch line.kind {
            case .add: return paint("32", "  + " + line.text, color)
            case .remove: return paint("31", "  - " + line.text, color)
            case .context:
                if line.text.hasPrefix("@@") { return paint("36", "  " + line.text, color) }
                return paint("2", "    " + line.text, color)
            }
        }
        out += rows.prefix(max(0, cap))
        if rows.count > cap { out.append(paint("2", "  … \(rows.count - cap) more lines", color)) }
        return out
    }

    static func paint(_ code: String, _ text: String, _ color: Bool) -> String {
        color ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }
}

// MARK: - Permission prompt keys

/// What a key means at a permission prompt.
enum PermissionKeyAction: Equatable {
    case answer(PermissionAnswer)
    /// "deny with note": the editor opens so the owner can type why.
    case denyWithNote
    case ignore
}

enum PermissionKeys {
    /// `isCommand`: the prompt is for a shell command (true) or for file edits (false).
    static func action(for key: Key, isCommand: Bool) -> PermissionKeyAction {
        switch key {
        case .escape:
            return .answer(.deny(nil))
        case .char(let c):
            switch String(c).lowercased() {
            case "y": return .answer(.allow)
            case "a": return .answer(.allowSession)
            case "b": return isCommand ? .ignore : .answer(.allowBatch)
            case "n": return .answer(.deny(nil))
            case "e": return isCommand ? .denyWithNote : .ignore
            default: return .ignore
            }
        default:
            return .ignore
        }
    }

    /// The one-key choice line shown under the request.
    static func choiceLine(isCommand: Bool) -> String {
        isCommand
            ? "[y] allow  [a] allow for this session  [n] deny  [e] deny with note"
            : "[y] apply  [b] apply all in this reply  [a] auto-accept edits from now  [n] deny"
    }
}

// MARK: - Status line

enum StatusLine {
    /// Idle: `model · mode · ⇧⇥ mode · / commands · @ files`, dim. Bypass is red. `hint` replaces the tail when set
    /// (for example "press Ctrl-C again to exit").
    static func idle(model: String, mode: PermissionMode, hint: String?, width: Int) -> String {
        let modeText = mode == .bypass ? Ansi.red(mode.short) : mode.short
        let tail = hint ?? "⇧⇥ mode · / commands · @ files"
        let line = Ansi.dim("\(model) · ") + modeText + Ansi.dim(" · \(tail)")
        return Ansi.truncate(line, width: width)
    }

    /// Working: `frame working 12s · step 3 · $0.0021 · context 34%`, then the agent's status text, truncated.
    static func working(frame: String, elapsed: Double, steps: Int, cost: Double, contextPercent: Int?,
                        status: String, mode: PermissionMode, width: Int) -> String {
        var parts = ["working \(Spinner.elapsed(elapsed))", "step \(steps)", Fmt.dollars(cost)]
        if let p = contextPercent { parts.append("context \(p)%") }
        var line = Ansi.cyan(frame) + " " + Ansi.dim(parts.joined(separator: " · "))
        if mode == .bypass { line += " " + Ansi.red("[bypass]") }
        let text = status.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { line += Ansi.dim(" · " + Fmt.line(text, 200)) }
        return Ansi.truncate(line, width: width)
    }
}
