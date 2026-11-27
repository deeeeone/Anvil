import Foundation

/// Design review for a finished web UI: cheap checks run in the page, plus a vision critic's score and fixes.
/// Pure logic only. The caller takes the screenshots, runs the scripts and asks the model.
nonisolated enum DesignCritique {
    enum Severity: String, Sendable, Equatable { case blocker, major, minor }

    struct Fix: Equatable, Sendable {
        var severity: Severity
        var location: String
        var change: String
    }

    struct Critique: Equatable, Sendable {
        var score: Int  // 0...100
        var fixes: [Fix]
    }

    /// File extensions that mean front-end work.
    static let uiExtensions: Set<String> = ["html", "htm", "css", "scss", "sass", "less", "jsx", "tsx", "vue", "svelte", "astro"]

    /// True when this request is UI work: the wording says so, or a changed file has a UI extension.
    static func isUIWork(uiRequest: Bool, changedPaths: [String]) -> Bool {
        if uiRequest { return true }
        return changedPaths.contains { uiExtensions.contains(NSString(string: $0).pathExtension.lowercased()) }
    }

    /// Design rules added to the agent's prompt for UI requests.
    static let brief = """
    DESIGN BRIEF (for this UI task)
    - For a new page or screen, put a short design plan in the "say" of your first reply (palette, type, layout, one distinctive idea), together with that reply's actions. Check it isn't a generic default. Small changes skip the plan.
    - Use semantic colour tokens (CSS variables) and a spacing scale.
    - At most 2 font families and 3 to 5 colours. No gradients, and no purple unless asked.
    - Mobile first. One main action per view.
    - Keep 3 to 5 things above the fold. Put the rest behind tabs, drawers or further down.
    - Group things with whitespace instead of borders.
    - Give every focusable element a visible focus style.
    - After you finish, the app screenshots the page and a design reviewer may send fixes.
    """

    /// JS run in the page: a colour count and a focus-style check that the audit does not cover. Returns a JSON string.
    static let extraChecksScript = #"""
    (() => {
      const label = e => e.tagName.toLowerCase() + (e.id ? '#' + e.id : '') + (typeof e.className === 'string' && e.className.trim() ? '.' + e.className.trim().split(/\s+/)[0] : '');
      const vis = e => e.getClientRects().length > 0 && getComputedStyle(e).visibility !== 'hidden';
      const isClear = v => !v || v === 'transparent' || /^rgba\(.*,\s*0(\.0*)?\)$/.test(v);
      try {
        const colors = new Set();
        for (const e of [...document.querySelectorAll('body *')].filter(vis).slice(0, 400)) {
          const cs = getComputedStyle(e);
          for (const v of [cs.color, cs.backgroundColor]) if (!isClear(v)) colors.add(v);
        }
        const focusable = [...document.querySelectorAll('a[href], button, input, select, textarea, [tabindex]:not([tabindex="-1"])')].filter(vis).slice(0, 20);
        const props = ['outline-style', 'outline-width', 'box-shadow', 'border-color', 'background-color'];
        const look = e => { const cs = getComputedStyle(e); return props.map(p => cs.getPropertyValue(p)).join('|'); };
        // A focus() call from script doesn't trigger :focus-visible, so a page whose CSS styles focus counts as styled.
        let css = '';
        for (const sheet of [...document.styleSheets]) { try { for (const r of [...sheet.cssRules]) css += r.cssText + '\n'; } catch (e) {} }
        const styledInCSS = /:focus(-visible|-within)?\b[^{]*\{[^}]*(outline|box-shadow|border|background)/.test(css);
        let noStyle = 0;
        const examples = [];
        for (const e of (styledInCSS ? [] : focusable)) {
          const before = look(e);
          e.focus({ preventScroll: true });
          const after = look(e);
          if (before === after) { noStyle++; if (examples.length < 3) examples.push(label(e)); }
          e.blur();
        }
        return JSON.stringify({ colors: colors.size, focusChecked: focusable.length, focusNoStyle: noStyle, focusExamples: examples });
      } catch (err) {
        return JSON.stringify({ colors: 0, focusChecked: 0, focusNoStyle: 0, focusExamples: [] });
      }
    })()
    """#

    /// Problems found without a model, from the audit facts (phone width) and the extra checks. Only real problems.
    static func checkFixes(audit: [String: Any], extra: [String: Any]) -> [Fix] {
        var fixes: [Fix] = []
        if int(audit["overflowCount"]) > 0 {
            let examples = ((audit["overflowExamples"] as? [String]) ?? []).prefix(2).joined(separator: "; ")
            fixes.append(Fix(severity: .blocker, location: "page at \(int(audit["viewportWidth"]))px",
                             change: "Content runs past the screen edge (document \(int(audit["documentWidth"]))px wide)\(examples.isEmpty ? "" : ": " + examples). Make it fit the width."))
        }
        var low: [(text: String, ratio: Double, required: Double)] = []
        var families: [String] = []
        for s in (audit["samples"] as? [[String: Any]]) ?? [] {
            if let font = s["font"] as? String, !font.isEmpty, !families.contains(font) { families.append(font) }
            guard let size = BrowserQA.number(s["fontSize"]), let fg = s["fg"] as? String,
                  let weight = BrowserQA.number(s["weight"]),
                  let c = BrowserQA.textContrast(fg: fg, bg: s["bg"] as? String, fontSize: size, weight: Int(weight)) else { continue }
            if c.ratio < c.required { low.append((Fmt.line(s["text"] as? String ?? "", 40), c.ratio, c.required)) }
        }
        if let first = low.first {
            fixes.append(Fix(severity: .major, location: "text",
                             change: "Low contrast on \(low.count) text elements, e.g. \"\(first.text)\" at \(String(format: "%.2f", first.ratio)):1 (needs \(BrowserQA.trim(first.required)):1)."))
        }
        if families.count > 2 {
            fixes.append(Fix(severity: .minor, location: "typography",
                             change: "Uses \(families.count) font families (\(families.joined(separator: ", "))); keep to 2."))
        }
        if int(extra["colors"]) > 12 {
            fixes.append(Fix(severity: .minor, location: "palette",
                             change: "Uses about \(int(extra["colors"])) distinct colours; keep to a small token palette."))
        }
        let noStyle = int(extra["focusNoStyle"])
        if noStyle > 0 {
            let examples = ((extra["focusExamples"] as? [String]) ?? []).prefix(3).joined(separator: ", ")
            fixes.append(Fix(severity: .major, location: "focus styles",
                             change: "\(noStyle) of \(int(extra["focusChecked"])) focusable elements show no visible focus style, e.g. \(examples)."))
        }
        if int(audit["consoleErrors"]) > 0 {
            fixes.append(Fix(severity: .major, location: "console", change: "\(int(audit["consoleErrors"])) console errors on the page."))
        }
        return fixes
    }

    /// The critic's prompt: the request, the design brief, the screenshot labels in attach order, and the automated checks.
    static func prompt(goal: String, checks: [String], shots: [String]) -> String {
        let shotLines = shots.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let checkLines = checks.isEmpty ? "none" : checks.map { "- \($0)" }.joined(separator: "\n")
        return """
        DESIGN CRITIC. You review screenshots of a web page an AI agent just built. You do not write code.

        REQUEST
        \(Fmt.clip(goal, max: 1500))

        \(brief)

        SCREENSHOTS (in the order attached)
        \(shotLines)

        AUTOMATED CHECKS
        \(checkLines)

        RULES
        - Score 0-100 for how well the page meets the request and the brief, and how finished and intentional it looks.
        - At most 8 fixes, most important first.
        - Each fix is concrete: where on the page and exactly what to change (sizes, colours, spacing, copy). No vague advice.
        - Severity: blocker = broken or unusable (overlap, clipped or unreadable content, layout breaks on phone); major = clearly hurts the design or usability; minor = polish.
        - Don't invent problems you can't see in the screenshots. Don't ask for new features.
        - Reply with one JSON object only, in a ```json block: {"score": 0-100, "fixes": [{"severity": "blocker|major|minor", "where": "...", "change": "..."}]}
        """
    }

    /// Reads the critic's reply. nil when there is no object or no numeric score.
    static func parse(_ reply: String) -> Critique? {
        guard let obj = CompletionJudge.jsonObject(reply), let value = clampScore(obj["score"]) else { return nil }
        var fixes: [Fix] = []
        for item in (obj["fixes"] as? [Any]) ?? [] {
            guard let f = item as? [String: Any] else { continue }
            let change = ((f["change"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !change.isEmpty else { continue }
            let location = (((f["where"] as? String) ?? (f["location"] as? String)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let raw = ((f["severity"] as? String) ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            fixes.append(Fix(severity: Severity(rawValue: raw) ?? .minor, location: location, change: change))
        }
        return Critique(score: value, fixes: Array(byWeight(fixes).prefix(8)))
    }

    /// Automated fixes first, then critic fixes whose change text is new. Capped at 8.
    static func merge(checks: [Fix], critic: [Fix]) -> [Fix] {
        var seen = Set(checks.map { normalised($0.change) })
        var out = checks
        for fix in critic {
            let key = normalised(fix.change)
            if !seen.contains(key) {
                seen.insert(key)
                out.append(fix)
            }
        }
        return Array(out.prefix(8))
    }

    /// Only blockers and majors.
    static func actionable(_ fixes: [Fix]) -> [Fix] {
        fixes.filter { $0.severity != .minor }
    }

    /// The hidden note sent back to the agent with the fixes to make.
    static func note(score: Int, fixes: [Fix]) -> String {
        var text = "<design-check>\nA design review of the screenshots (score \(score)/100) found these to fix:\n"
        for fix in fixes {
            text += "- [\(fix.severity.rawValue)] \(fix.location): \(fix.change)\n"
        }
        text += "Fix these, check the page in the browser again, then reply done:true. Don't change anything else.\n</design-check>"
        return text
    }

    /// Removes any <design-check> notes (and the newline after each), like CompletionJudge.strippingChecks.
    static func strippingNotes(_ text: String) -> String {
        guard text.contains("<design-check>") else { return text }
        let re = try! NSRegularExpression(pattern: "<design-check>[\\s\\S]*?</design-check>\\n?")
        return re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: NSString(string: text).length), withTemplate: "")
    }

    /// One short line for the chat step output.
    static func summary(score: Int, fixCount: Int) -> String {
        fixCount == 0 ? "Design check: \(score)/100, looks good" : "Design check: \(score)/100, \(fixCount == 1 ? "1 fix" : "\(fixCount) fixes")"
    }

    /// Rounds of critique for one request.
    struct Tracker: Sendable {
        enum Step: Equatable, Sendable { case fix, accept, revert }

        let cap: Int
        private(set) var rounds = 0
        private(set) var bestScore: Int? = nil
        private(set) var bestRound = 0

        init(cap: Int = 3) { self.cap = cap }

        var exhausted: Bool { rounds >= cap }

        /// Records one critique round and says what to do next.
        mutating func record(score: Int, actionable: Int) -> Step {
            rounds += 1
            if bestScore.map({ score > $0 }) ?? true {
                bestScore = score
                bestRound = rounds
            }
            let best = bestScore ?? score
            if score < best { return .revert }
            if rounds > 1 && score == best && bestRound != rounds { return .accept }
            if actionable == 0 { return .accept }
            if rounds >= cap { return .accept }
            return .fix
        }
    }

    // MARK: - Helpers

    private static func int(_ v: Any?) -> Int { Int(BrowserQA.number(v) ?? 0) }

    /// A score from a number or a numeric string, clamped to 0...100.
    private static func clampScore(_ v: Any?) -> Int? {
        var d: Double?
        if let n = v as? NSNumber {
            d = n.doubleValue
        } else if let s = v as? String {
            d = Double(s.trimmingCharacters(in: .whitespaces))
        }
        guard let value = d, value.isFinite else { return nil }
        return Int(min(100, max(0, value)).rounded())
    }

    /// Blockers, then majors, then minors; the order within each group is kept.
    private static func byWeight(_ fixes: [Fix]) -> [Fix] {
        [Severity.blocker, .major, .minor].flatMap { level in fixes.filter { $0.severity == level } }
    }

    private static func normalised(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
