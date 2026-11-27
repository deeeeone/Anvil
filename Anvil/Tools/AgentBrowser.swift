import Foundation

/// What the agent's browser tools need (the app's embedded browser implements it).
protocol AgentBrowser: AnyObject {
    func open(_ url: String) async -> String
    func readPage() async throws -> String
    func click(_ id: Int) async throws -> String
    func type(_ id: Int, text: String, submit: Bool) async throws -> String
    func evaluate(_ js: String) async throws -> String
    func screenshot() async throws -> Data
    func navigate(_ action: String) async -> String
    func setViewport(width: Int?, height: Int?) -> String
    func console() async throws -> String
    func network(filter: String?, limit: Int, bodies: Bool, clear: Bool) async throws -> String
}

enum BrowserTools {
    static func all() -> [ToolSpec] { [open, read, find, click, type, key, select, hover, scroll, wait, nav, console, network, viewport, eval, screenshot, styles, audit] }

    /// Runs a small DOM action on element [id] from browser_read.
    static func onElement(_ ctx: ToolContext, _ id: Int, _ body: String) async throws -> String {
        let r = try await browser(ctx).evaluate("""
        (() => { const e = document.querySelector('[data-anvil-id="\(id)"]'); if (!e) return 'missing'; \(body) })()
        """)
        if r == "missing" { throw ToolFailure("element [\(id)] isn't on the page any more; run browser_read again") }
        return r
    }

    static let find = ToolSpec(name: "browser_find", kind: .network, signature: #"{"text": str}"#,
                               summary: "numbered elements whose label or text contains the words (quicker than reading the whole page)", group: .web) { a, ctx in
        guard let q = a["text"]?.string ?? a["query"]?.string else { return .fail("missing text") }
        let page = try await browser(ctx).readPage()
        let hits = page.components(separatedBy: "\n").filter { $0.hasPrefix("[") && $0.localizedCaseInsensitiveContains(q) }
        return .ok(hits.isEmpty ? "no element mentions \"\(q)\" (try browser_read)" : hits.joined(separator: "\n"))
    }
    static let key = ToolSpec(name: "browser_key", kind: .network, signature: #"{"key": "Enter|Escape|Tab|ArrowDown|...", optional "id": int}"#,
                              summary: "press a key on an element (or the focused one): submit, close dialogs, move through menus", group: .web) { a, ctx in
        guard let k = a["key"]?.string else { return .fail("missing key") }
        let lit = JSON.string(k).compact
        let target = a["id"]?.int.map { "document.querySelector('[data-anvil-id=\"\($0)\"]')" } ?? "document.activeElement || document.body"
        let r = try await browser(ctx).evaluate("""
        (() => { const e = \(target); if (!e) return 'missing'; e.focus && e.focus();
          for (const t of ['keydown', 'keypress', 'keyup']) e.dispatchEvent(new KeyboardEvent(t, {key: \(lit), code: \(lit), bubbles: true, cancelable: true}));
          if (\(lit) === 'Enter' && e.form && e.form.requestSubmit) e.form.requestSubmit();
          return 'pressed ' + \(lit) + ' on ' + e.tagName.toLowerCase(); })()
        """)
        return r == "missing" ? .fail("no element to press the key on") : .ok(r)
    }
    static let select = ToolSpec(name: "browser_select", kind: .network, signature: #"{"id": int, "value": option text or value}"#,
                                 summary: "choose an option in a <select>", group: .web) { a, ctx in
        guard let id = a["id"]?.int, let v = a["value"]?.string else { return .fail("need id and value") }
        let lit = JSON.string(v).compact
        return .ok(try await onElement(ctx, id, """
        const o = Array.from(e.options || []).find(o => o.value === \(lit) || o.text.trim() === \(lit)); if (!o) return 'no option ' + \(lit);
        e.value = o.value; e.dispatchEvent(new Event('input', {bubbles: true})); e.dispatchEvent(new Event('change', {bubbles: true})); return 'selected ' + o.text;
        """))
    }
    static let hover = ToolSpec(name: "browser_hover", kind: .network, signature: #"{"id": int}"#,
                                summary: "hover an element (menus, tooltips)", group: .web) { a, ctx in
        guard let id = a["id"]?.int else { return .fail("missing id") }
        return .ok(try await onElement(ctx, id, "for (const t of ['pointerover', 'mouseover', 'mouseenter', 'pointermove', 'mousemove']) e.dispatchEvent(new MouseEvent(t, {bubbles: true})); return 'hovered ' + e.tagName.toLowerCase();"))
    }
    static let scroll = ToolSpec(name: "browser_scroll", kind: .network, signature: #"{"to": "top|bottom"} or {"id": int} or {"by": pixels}"#,
                                 summary: "scroll the page (lazy content, footers, sticky headers)", group: .web) { a, ctx in
        let js: String
        if let id = a["id"]?.int { return .ok(try await onElement(ctx, id, "e.scrollIntoView({block: 'center'}); return 'scrolled to [\(id)]';")) }
        else if let by = a["by"]?.int { js = "window.scrollBy(0, \(by)); 'scrolled to ' + Math.round(scrollY) + ' of ' + document.body.scrollHeight" }
        else if a["to"]?.string == "top" { js = "window.scrollTo(0, 0); 'at the top'" }
        else { js = "window.scrollTo(0, document.body.scrollHeight); 'at the bottom (' + document.body.scrollHeight + 'px)'" }
        return .ok(try await browser(ctx).evaluate(js))
    }
    static let wait = ToolSpec(name: "browser_wait", kind: .network, signature: #"{"text": str} or {"selector": css}, optional "timeout": seconds (default 10)"#,
                               summary: "wait until text or an element appears on the page (after clicks that load data)", group: .web) { a, ctx in
        let b = try browser(ctx)
        let timeout = min(60, a["timeout"]?.double ?? 10)
        let cond: String
        if let t = a["text"]?.string { cond = "document.body && document.body.innerText.includes(\(JSON.string(t).compact))" }
        else if let sel = a["selector"]?.string { cond = "!!document.querySelector(\(JSON.string(sel).compact))" }
        else { return .fail("need text or selector") }
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if (try? await b.evaluate("(\(cond)) ? 'yes' : 'no'")) == "yes" { return .ok("appeared after \(String(format: "%.1f", Date().timeIntervalSince(start)))s") }
            try await Task.sleep(for: .milliseconds(300))
        }
        return .fail("didn't appear within \(Int(timeout))s; check browser_read or browser_console")
    }
    static let nav = ToolSpec(name: "browser_nav", kind: .network, signature: #"{"action": "back|forward|reload"}"#,
                              summary: "go back, forward or reload", group: .web) { a, ctx in
        .ok(await (try browser(ctx)).navigate(a["action"]?.string ?? "reload"))
    }
    static let console = ToolSpec(name: "browser_console", kind: .network, signature: "{}",
                                  summary: "console logs, uncaught errors, rejected promises and failed requests since the page loaded", group: .web) { _, ctx in
        .ok(try await browser(ctx).console())
    }
    static let network = ToolSpec(name: "browser_network", kind: .network, signature: #"{optional "filter": str, optional "limit": int, optional "bodies": bool, optional "clear": bool}"#,
                                  summary: "network requests the page made since it loaded (fetch, XHR, scripts, images, media) with method, status, type, timing and size; bodies:true adds headers and response previews. Not seen: service-worker and cross-origin iframe traffic, and statuses of plain resource loads when the browser hides them", group: .web) { a, ctx in
        .ok(Fmt.clip(try await browser(ctx).network(filter: a["filter"]?.string, limit: a["limit"]?.int ?? 50, bodies: a["bodies"]?.bool ?? false, clear: a["clear"]?.bool ?? false), max: 14000))
    }
    static let viewport = ToolSpec(name: "browser_viewport", kind: .network, signature: #"{"device": "mobile|tablet|desktop"} or {"width": int, "height": int}"#,
                                   summary: "emulate a screen size to check responsive layouts (desktop fills the pane)", group: .web) { a, ctx in
        let b = try browser(ctx)
        switch a["device"]?.string?.lowercased() {
        case "mobile", "phone": return .ok(b.setViewport(width: 390, height: 844))
        case "tablet": return .ok(b.setViewport(width: 820, height: 1180))
        case "desktop": return .ok(b.setViewport(width: nil, height: nil))
        default:
            guard let w = a["width"]?.int else { return .fail("need device or width") }
            return .ok(b.setViewport(width: w, height: a["height"]?.int))
        }
    }

    static func browser(_ ctx: ToolContext) throws -> AgentBrowser {
        guard let b = ctx.browser else { throw ToolFailure("no browser in this environment") }
        return b
    }

    static let open = ToolSpec(name: "browser_open", kind: .network, signature: #"{"url": str}"#,
                               summary: "open a page in the embedded browser the owner sees in the Preview tab (dev servers, docs, any site)", group: .web) { a, ctx in
        guard let u = a["url"]?.string ?? a["value"]?.string else { return .fail("missing url") }
        let r = await (try browser(ctx)).open(u)
        return r.hasPrefix("couldn't") ? .fail(r) : .ok(r)
    }
    static let read = ToolSpec(name: "browser_read", kind: .network, signature: "{}",
                               summary: "the open page's visible text and numbered links, buttons and fields (use the numbers with browser_click and browser_type)", group: .web) { _, ctx in
        .ok(Fmt.clip(try await browser(ctx).readPage(), max: 14000))
    }
    static let click = ToolSpec(name: "browser_click", kind: .network, signature: #"{"id": int}"#,
                                summary: "click an element by its number from browser_read", group: .web) { a, ctx in
        guard let id = a["id"]?.int else { return .fail("missing id") }
        return .ok(try await browser(ctx).click(id))
    }
    static let type = ToolSpec(name: "browser_type", kind: .network, signature: #"{"id": int, "text": str, optional "submit": bool}"#,
                               summary: "type into a field by its number from browser_read (submit:true submits the form)", group: .web) { a, ctx in
        guard let id = a["id"]?.int, let t = a["text"]?.string else { return .fail("need id and text") }
        return .ok(try await browser(ctx).type(id, text: t, submit: a["submit"]?.bool ?? false))
    }
    static let eval = ToolSpec(name: "browser_eval", kind: .network, signature: #"{"js": str}"#,
                               summary: "run any JavaScript in the open page and return the result: anything the other browser tools don't cover (drag, computed styles, localStorage, app state)", group: .web) { a, ctx in
        guard let js = a["js"]?.string ?? a["code"]?.string else { return .fail("missing js") }
        return .ok(Fmt.clip(try await browser(ctx).evaluate(js), max: 8000))
    }
    static let screenshot = ToolSpec(name: "browser_screenshot", kind: .network, signature: "{}",
                                     summary: "a screenshot of the open page, attached so you can see the layout (checks visual changes)", group: .web) { _, ctx in
        let data = try await browser(ctx).screenshot()
        var r = ToolResult.ok("screenshot attached (\(data.count / 1024) KB)")
        r.image = (data, "image/jpeg")
        return r
    }
    static let styles = ToolSpec(name: "browser_styles", kind: .network, signature: #"{"selector": css, optional "props": [str]}"#,
                                 summary: "computed styles and bounding box of the first element matching a CSS selector, plus its text contrast (WCAG) against the background", group: .web) { a, ctx in
        guard let sel = a["selector"]?.string?.trimmingCharacters(in: .whitespaces), !sel.isEmpty else { return .fail("missing selector") }
        let wanted = a["props"]?.array?.compactMap(\.string) ?? []
        let raw = try await browser(ctx).evaluate(BrowserQA.styleScript(selector: sel, props: wanted.isEmpty ? BrowserQA.defaultStyleProps : wanted))
        guard let o = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] else { return .fail("couldn't read the styles of \"\(sel)\"") }
        if let err = o["error"] as? String { return .fail(err) }
        guard (o["found"] as? Bool) == true else { return .fail("no element matches \"\(sel)\" on the page (browser_find or browser_read shows what is there)") }
        var lines = (o["pairs"] as? [[Any]] ?? []).map { "\($0[0]): \($0[1])" }
        lines.append("box: \((o["box"] as? String) ?? "")")
        if (o["hasText"] as? Bool) == true, let fg = o["fg"] as? String, let size = BrowserQA.number(o["fontSize"]),
           let weight = BrowserQA.number(o["weight"]), let c = BrowserQA.textContrast(fg: fg, bg: o["bg"] as? String, fontSize: size, weight: Int(weight)) {
            let bg = (o["bg"] as? String) ?? "no opaque background found, assumed white"
            let verdict = c.ratio >= c.required ? "ok" : "low contrast (needs \(BrowserQA.trim(c.required)):1)"
            lines.append("contrast: \(String(format: "%.2f", c.ratio)):1, text \(fg) on \(bg): \(verdict)")
        }
        return .ok(lines.joined(separator: "\n"))
    }
    static let audit = ToolSpec(name: "browser_audit", kind: .network, signature: "{}",
                                summary: "quick UI audit of the open page: low text contrast, overflow past the viewport, images without alt, unnamed buttons and links, font families and sizes, console errors", group: .web) { _, ctx in
        let raw = try await browser(ctx).evaluate(BrowserQA.auditScript)
        guard let o = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] else { return .fail("couldn't audit the page (is one open? use browser_open first)") }
        return .ok(BrowserQA.auditReport(o))
    }
}
