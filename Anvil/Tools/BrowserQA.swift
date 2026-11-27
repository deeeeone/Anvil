import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Pure helpers behind browser_open's report, browser_styles and browser_audit, plus the scripts they run in the page.
enum BrowserQA {
    /// A navigation that another navigation replaced (WebKit cancels it), not a failure.
    static func isSupersededNavigation(_ error: Error) -> Bool {
        let e = error as NSError
        return (e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled) || (e.domain == "WebKitErrorDomain" && e.code == 102)
    }

    /// Heuristic: the title or the start of the visible text says the page is missing.
    static func looksLikeNotFound(title: String, text: String) -> Bool {
        // The title, or both "404" and "not found" near the top: an app page saying "Item not found" is not a 404.
        let t = title.lowercased(), body = String(text.prefix(1500)).lowercased()
        if t.contains("404") || t.contains("not found") || body.contains("this page could not be found") { return true }
        return body.contains("404") && body.contains("not found")
    }

    static func sameURL(_ a: String, _ b: String) -> Bool {
        func trimmed(_ s: String) -> String { s.hasSuffix("/") ? String(s.dropLast()) : s }
        return trimmed(a) == trimmed(b)
    }

    /// browser_open's one-line result: the final address and title, a redirect note, a 404 warning.
    static func describeLoaded(requested: String, final: String, title: String, notFound: Bool) -> String {
        var line = "loaded \(final) (\"\(title)\")"
        if !sameURL(requested, final) { line += "; redirected to \(final) from \(requested)" }
        if notFound { line += "; looks like a 404 page" }
        return line
    }

    static let defaultStyleProps = ["color", "background-color", "font-family", "font-size", "font-weight", "line-height", "padding", "margin",
                                    "border", "border-radius", "display", "gap", "width", "height"]

    /// True when an image is one flat colour (a page that never painted, or an empty one): sampled on a 24x24 grid.
    static func looksBlank(_ data: Data) -> Bool {
#if canImport(AppKit)
        guard let rep = NSBitmapImageRep(data: data), rep.pixelsWide > 0, rep.pixelsHigh > 0,
              let first = rep.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB) else { return false }
        for i in 0..<24 { for j in 0..<24 {
            guard let c = rep.colorAt(x: i * (rep.pixelsWide - 1) / 23, y: j * (rep.pixelsHigh - 1) / 23)?.usingColorSpace(.deviceRGB) else { continue }
            if abs(c.redComponent - first.redComponent) + abs(c.greenComponent - first.greenComponent) + abs(c.blueComponent - first.blueComponent) > 0.06 { return false }
        } }
        return true
#else
        // TODO(linux): no AppKit image reps here; report "not blank" so the caller treats the capture as real.
        return false
#endif
    }

    static func number(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

    static func trim(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }

    struct RGBA: Equatable { var r, g, b, a: Double }

    /// Parses the rgb()/rgba() strings that getComputedStyle returns.
    static func parseColor(_ css: String) -> RGBA? {
        guard let open = css.firstIndex(of: "("), let close = css.lastIndex(of: ")"), open < close,
              css[..<open].lowercased().hasPrefix("rgb") else { return nil }
        let parts = css[css.index(after: open)..<close].split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" }).map(String.init)
        guard parts.count >= 3, let r = Double(parts[0]), let g = Double(parts[1]), let b = Double(parts[2]) else { return nil }
        var a = 1.0
        if parts.count > 3 {
            let t = parts[3]
            a = t.hasSuffix("%") ? (Double(t.dropLast()) ?? 100) / 100 : (Double(t) ?? 1)
        }
        return RGBA(r: r, g: g, b: b, a: a)
    }

    /// WCAG relative luminance of an opaque colour.
    static func luminance(_ c: RGBA) -> Double {
        func lin(_ v: Double) -> Double {
            let x = v / 255
            return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    /// WCAG contrast ratio, 1...21, of two opaque colours.
    static func contrastRatio(_ a: RGBA, _ b: RGBA) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// WCAG AA: 4.5:1 for text, 3:1 for large text (24px, or 18.66px bold).
    static func requiredContrast(fontSize: Double, weight: Int) -> Double {
        fontSize >= 24 || (fontSize >= 18.66 && weight >= 700) ? 3.0 : 4.5
    }

    /// Contrast of text colour `fg` (blended over `bg` when translucent) against the nearest opaque background; nil bg means white.
    static func textContrast(fg: String, bg: String?, fontSize: Double, weight: Int) -> (ratio: Double, required: Double)? {
        guard let text = parseColor(fg) else { return nil }
        let back = bg.flatMap(parseColor) ?? RGBA(r: 255, g: 255, b: 255, a: 1)
        let a = text.a
        let shown = RGBA(r: text.r * a + back.r * (1 - a), g: text.g * a + back.g * (1 - a), b: text.b * a + back.b * (1 - a), a: 1)
        return (contrastRatio(shown, back), requiredContrast(fontSize: fontSize, weight: weight))
    }

    /// JS: the nearest ancestor-or-self with an opaque background colour (null when none).
    private static let bgOfJS = #"""
    const bgOf = n => { for (let x = n; x && x.nodeType === 1; x = x.parentElement) { const c = getComputedStyle(x).backgroundColor; const m = c.match(/^rgba?\(([^)]+)\)$/); if (!m) continue; const p = m[1].split(/[ ,\/]+/).filter(Boolean); if (p.length < 4 || parseFloat(p[3]) >= 0.99) return c; } return null; };
    """#

    /// Script for browser_styles: computed styles, box, and the colours needed for contrast.
    static func styleScript(selector: String, props: [String]) -> String {
        #"""
        (() => {
          \#(bgOfJS)
          let e;
          try { e = document.querySelector(\#(JSON.string(selector).compact)) } catch (err) { return JSON.stringify({ error: 'not a valid CSS selector' }) }
          if (!e) return JSON.stringify({ found: false });
          const cs = getComputedStyle(e), r = e.getBoundingClientRect();
          const props = [\#(props.map { JSON.string($0).compact }.joined(separator: ", "))];
          const value = p => cs.getPropertyValue(p) || (p === 'border' ? [cs.borderTopWidth, cs.borderTopStyle, cs.borderTopColor].join(' ') : '');
          return JSON.stringify({
            found: true, pairs: props.map(p => [p, value(p)]),
            box: 'x=' + Math.round(r.x) + ' y=' + Math.round(r.y) + ' ' + Math.round(r.width) + 'x' + Math.round(r.height),
            hasText: (e.textContent || '').trim().length > 0,
            fg: cs.color, bg: bgOf(e), fontSize: parseFloat(cs.fontSize), weight: parseInt(cs.fontWeight) || 400
          });
        })()
        """#
    }

    /// Script for browser_audit: one pass over the visible page, returning the raw facts that `auditReport` formats.
    static let auditScript = #"""
    (() => {
      \#(bgOfJS)
      const iw = window.innerWidth;
      const vis = e => e.getClientRects().length > 0 && getComputedStyle(e).visibility !== 'hidden';
      const label = e => e.tagName.toLowerCase() + (e.id ? '#' + e.id : '') + (typeof e.className === 'string' && e.className.trim() ? '.' + e.className.trim().split(/\s+/)[0] : '');
      const all = [...document.querySelectorAll('body *')].filter(vis);
      const textEls = all.filter(e => [...e.childNodes].some(n => n.nodeType === 3 && n.textContent.trim()));
      const samples = textEls.slice(0, 400).map(e => { const cs = getComputedStyle(e); return {
        fg: cs.color, bg: bgOf(e), fontSize: parseFloat(cs.fontSize), weight: parseInt(cs.fontWeight) || 400,
        font: (cs.fontFamily.split(',')[0] || '').replace(/["']/g, '').trim(), text: e.textContent.trim().slice(0, 40) }; });
      const over = all.filter(e => e.getBoundingClientRect().right > iw + 1 && !(e.parentElement && e.parentElement.getBoundingClientRect().right > iw + 1));
      const named = e => { const t = (e.getAttribute('aria-label') || e.getAttribute('aria-labelledby') || e.title || e.value || e.textContent || '').trim(); return t.length > 0 || [...e.querySelectorAll('img')].some(i => i.alt.trim().length > 0); };
      const imgs = [...document.images];
      const ctrls = [...document.querySelectorAll('a[href], button, [role=button], [role=link]')].filter(vis);
      const unnamed = ctrls.filter(e => !named(e));
      return JSON.stringify({
        url: location.href, title: document.title, viewportWidth: iw, documentWidth: document.documentElement.scrollWidth,
        textTotal: textEls.length, samples,
        overflowCount: over.length, overflowExamples: over.slice(0, 3).map(e => label(e) + ' ends at ' + Math.round(e.getBoundingClientRect().right) + 'px'),
        imagesTotal: imgs.length, imagesNoAlt: imgs.filter(i => !i.hasAttribute('alt')).length,
        controlsTotal: ctrls.length, controlsUnnamed: unnamed.length, unnamedExamples: unnamed.slice(0, 3).map(label),
        consoleErrors: (window.__anvilLogs || []).filter(l => /^(error|uncaught|unhandled|network)/.test(l)).length
      });
    })()
    """#

    /// One compact report (under 3000 characters) from the facts `auditScript` returns.
    static func auditReport(_ o: [String: Any]) -> String {
        func n(_ k: String) -> Int { Int(number(o[k]) ?? 0) }
        func list(_ k: String) -> [String] { (o[k] as? [String] ?? []).prefix(3).map { "    " + $0 } }
        var out = ["UI audit of \((o["url"] as? String) ?? "") (\"\((o["title"] as? String) ?? "")\")"]
        var low: [String] = [], checked = 0
        var families: [String: Int] = [:], sizes = Set<Double>()
        for s in o["samples"] as? [[String: Any]] ?? [] {
            if let f = s["font"] as? String, !f.isEmpty { families[f, default: 0] += 1 }
            guard let size = number(s["fontSize"]) else { continue }
            sizes.insert(size)
            guard let fg = s["fg"] as? String, let weight = number(s["weight"]),
                  let c = textContrast(fg: fg, bg: s["bg"] as? String, fontSize: size, weight: Int(weight)) else { continue }
            checked += 1
            if c.ratio < c.required {
                low.append("    \"\((s["text"] as? String) ?? "")\" \(String(format: "%.2f", c.ratio)):1, needs \(trim(c.required)):1")
            }
        }
        out.append("- low text contrast: \(low.count) of \(checked) sampled text elements (WCAG AA: 4.5:1, 3:1 for large text)")
        out += low.prefix(3)
        out.append("- horizontal overflow: \(n("overflowCount")) elements run past the \(n("viewportWidth"))px viewport (document \(n("documentWidth"))px wide)")
        out += list("overflowExamples")
        out.append("- images without alt: \(n("imagesNoAlt")) of \(n("imagesTotal"))")
        out.append("- buttons and links without an accessible name: \(n("controlsUnnamed")) of \(n("controlsTotal"))")
        out += list("unnamedExamples")
        let top = families.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(5).map { "\($0.key) (\($0.value))" }
        out.append("- font families: " + (top.isEmpty ? "none found" : top.joined(separator: ", ")))
        let sz = sizes.sorted().map { trim($0) + "px" }
        out.append("- font sizes, \(sz.count) distinct: " + sz.prefix(12).joined(separator: ", "))
        out.append("- console errors: \(n("consoleErrors"))" + (n("consoleErrors") > 0 ? " (see browser_console)" : ""))
        return String(out.joined(separator: "\n").prefix(2900))
    }
}
