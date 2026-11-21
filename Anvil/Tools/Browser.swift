import AppKit
import WebKit
import Observation

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
}

/// The embedded browser behind the Preview tab. Real WebKit (Safari's engine), identifying itself as Safari.
@Observable
final class BrowserController: NSObject, WKNavigationDelegate, AgentBrowser {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Safari/605.1.15"

    private(set) var url = ""
    private(set) var title = ""
    private(set) var loading = false
    private(set) var lastError: String?
    /// Opened automatically from a dev server's output (and follows the next one).
    var followsDevServer = true
    /// Emulated viewport width for responsive checks (nil = fill the pane).
    private(set) var viewportWidth: CGFloat?
    private(set) var viewportHeight: CGFloat?

    /// Captures console messages, uncaught errors, rejected promises and failed fetches from the start of every page.
    static let consoleHook = """
    (() => { if (window.__anvilLogs) return; window.__anvilLogs = [];
      const push = (level, args) => { try { window.__anvilLogs.push(level + ': ' + Array.from(args).map(a => {
          if (a instanceof Error) return a.message + (a.stack ? '\\n' + a.stack.split('\\n').slice(0, 3).join('\\n') : '');
          if (typeof a === 'object') { try { return JSON.stringify(a).slice(0, 500) } catch (e) { return String(a) } } return String(a) }).join(' ').slice(0, 1500));
          if (window.__anvilLogs.length > 300) window.__anvilLogs.shift(); } catch (e) {} };
      for (const level of ['log', 'info', 'warn', 'error', 'debug']) { const orig = console[level]; console[level] = function () { push(level, arguments); return orig.apply(console, arguments) } }
      window.addEventListener('error', e => push('uncaught', [e.message + (e.filename ? ' (' + e.filename + ':' + e.lineno + ')' : '')]));
      window.addEventListener('unhandledrejection', e => push('unhandled promise', [e.reason]));
      const f = window.fetch; if (f) window.fetch = function () { return f.apply(this, arguments).then(r => { if (!r.ok) push('network', [r.status + ' ' + r.url]); return r }, err => { push('network', ['failed ' + (arguments[0] && arguments[0].url || arguments[0]) + ': ' + err]); throw err }) };
    })();
    """
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []

    @ObservationIgnored lazy var webView: WKWebView = {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.userContentController.addUserScript(WKUserScript(source: Self.consoleHook, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        cfg.preferences.isElementFullscreenEnabled = true
        let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 860), configuration: cfg)
        w.customUserAgent = Self.userAgent
        w.navigationDelegate = self
        w.allowsBackForwardNavigationGestures = true
        w.isInspectable = true
        return w
    }()

    static func normalize(_ s: String) -> URL? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if t.hasPrefix("/") { return URL(fileURLWithPath: t) }
        if !t.contains("://") {
            t = (t.hasPrefix("localhost") || t.hasPrefix("127.0.0.1") || t.hasPrefix("0.0.0.0") ? "http://" : "https://") + t
        }
        return URL(string: t.replacingOccurrences(of: "://0.0.0.0", with: "://localhost"))
    }

    /// Loads a page and waits for it (up to 20 s). Returns a one-line status.
    @discardableResult
    func open(_ s: String) async -> String {
        guard let u = Self.normalize(s) else { return "bad url" }
        url = u.absoluteString
        lastError = nil
        loading = true
        if u.isFileURL { webView.loadFileURL(u, allowingReadAccessTo: u.deletingLastPathComponent()) }
        else { webView.load(URLRequest(url: u)) }
        await waitForLoad(timeout: 20)
        if let e = lastError { return "couldn't load \(u.absoluteString): \(e)" }
        return "loaded \(webView.url?.absoluteString ?? u.absoluteString) (\"\(webView.title ?? "")\")"
    }

    func reload() { loading = true; webView.reload() }

    func waitForLoad(timeout: Double) async {
        guard loading else { return }
        await withTaskGroup(of: Void.self) { g in
            g.addTask { @MainActor in await withCheckedContinuation { self.waiters.append($0) } }
            g.addTask { try? await Task.sleep(for: .seconds(timeout)) }
            await g.next()
            g.cancelAll()
            self.resumeWaiters()
        }
    }

    private func resumeWaiters() {
        let w = waiters
        waiters = []
        w.forEach { $0.resume() }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            loading = false
            url = webView.url?.absoluteString ?? url
            title = webView.title ?? ""
            resumeWaiters()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { loading = false; lastError = error.localizedDescription; resumeWaiters() }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { loading = false; lastError = error.localizedDescription; resumeWaiters() }
    }

    // MARK: Agent control

    func evaluate(_ js: String) async throws -> String {
        let v = try await webView.evaluateJavaScript(js)
        if let s = v as? String { return s }
        if let v, JSONSerialization.isValidJSONObject(v), let d = try? JSONSerialization.data(withJSONObject: v) { return String(decoding: d, as: UTF8.self) }
        return v.map { "\($0)" } ?? "undefined"
    }

    /// Visible text plus numbered interactive elements (links, buttons, fields) the agent can click or type into.
    func readPage() async throws -> String {
        guard !url.isEmpty else { return "no page open; use browser_open first" }
        let js = """
        (() => {
          const vis = e => { const r = e.getBoundingClientRect(); const s = getComputedStyle(e); return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none'; };
          const els = [...document.querySelectorAll('a[href],button,input,textarea,select,[role=button],[role=link],[onclick],summary')].filter(vis).slice(0, 150);
          els.forEach((e, i) => e.setAttribute('data-anvil-id', String(i + 1)));
          const items = els.map((e, i) => {
            const label = (e.innerText || e.value || e.placeholder || e.getAttribute('aria-label') || e.title || e.name || '').trim().replace(/\\s+/g, ' ').slice(0, 80);
            const st = [e.disabled ? 'disabled' : '', e.checked ? 'checked' : '', (e.tagName === 'INPUT' || e.tagName === 'TEXTAREA') && e.value ? 'value="' + String(e.value).slice(0, 40) + '"' : '', e.tagName === 'SELECT' ? 'selected="' + (e.options[e.selectedIndex] || {}).text + '"' : ''].filter(Boolean).join(' ');
            return '[' + (i + 1) + '] ' + e.tagName.toLowerCase() + (e.type ? '(' + e.type + ')' : '') + ' "' + label + '"' + (e.href ? ' -> ' + e.getAttribute('href') : '') + (st ? ' ' + st : '');
          });
          const text = (document.body ? document.body.innerText : '').replace(/\\n{3,}/g, '\\n\\n').slice(0, 7000);
          const errs = (window.__anvilLogs || []).filter(l => /^(error|uncaught|unhandled|network)/.test(l)).length;
          return 'url: ' + location.href + '\\ntitle: ' + document.title + '\\nviewport: ' + innerWidth + 'x' + innerHeight + (errs ? '\\nconsole: ' + errs + ' error(s), see browser_console' : '') + '\\n\\ntext:\\n' + text + '\\n\\nelements:\\n' + items.join('\\n');
        })()
        """
        return try await evaluate(js)
    }

    func click(_ id: Int) async throws -> String {
        let before = webView.url
        let r = try await evaluate("""
        (() => { const e = document.querySelector('[data-anvil-id="\(id)"]'); if (!e) return 'missing';
          e.scrollIntoView({block: 'center'}); e.click(); return 'clicked ' + e.tagName.toLowerCase(); })()
        """)
        guard r != "missing" else { throw ToolFailure("element [\(id)] isn't on the page any more; run browser_read again") }
        try? await Task.sleep(for: .milliseconds(400))
        if loading { await waitForLoad(timeout: 15) }
        let moved = webView.url != before ? ", now at \(webView.url?.absoluteString ?? "")" : ""
        return r + moved
    }

    func type(_ id: Int, text: String, submit: Bool) async throws -> String {
        let lit = JSON.string(text).compact
        let r = try await evaluate("""
        (() => { const e = document.querySelector('[data-anvil-id="\(id)"]'); if (!e) return 'missing';
          e.focus();
          const proto = e.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
          const setter = Object.getOwnPropertyDescriptor(proto, 'value');
          if (setter && setter.set) setter.set.call(e, \(lit)); else e.value = \(lit);
          e.dispatchEvent(new Event('input', {bubbles: true})); e.dispatchEvent(new Event('change', {bubbles: true}));
          if (\(submit ? "true" : "false")) { if (e.form && e.form.requestSubmit) e.form.requestSubmit(); else e.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', bubbles: true})); }
          return 'typed into ' + e.tagName.toLowerCase(); })()
        """)
        guard r != "missing" else { throw ToolFailure("element [\(id)] isn't on the page any more; run browser_read again") }
        if submit { try? await Task.sleep(for: .milliseconds(400)); if loading { await waitForLoad(timeout: 15) } }
        return r
    }

    func navigate(_ action: String) async -> String {
        switch action {
        case "back": guard webView.canGoBack else { return "no page to go back to" }; loading = true; webView.goBack()
        case "forward": guard webView.canGoForward else { return "no page to go forward to" }; loading = true; webView.goForward()
        default: reload()
        }
        await waitForLoad(timeout: 15)
        return "\(action): now at \(webView.url?.absoluteString ?? url)"
    }

    /// Emulates a viewport (the Preview tab shows the page at that size). nil width restores filling the pane.
    func setViewport(width: Int?, height: Int?) -> String {
        viewportWidth = width.map { CGFloat($0) }
        viewportHeight = height.map { CGFloat($0) }
        if webView.window == nil { webView.frame = NSRect(x: 0, y: 0, width: viewportWidth ?? 1280, height: viewportHeight ?? 860) }
        return width.map { "viewport set to \($0)x\(height ?? Int(webView.frame.height)); read or screenshot again to see the layout" } ?? "viewport fills the pane again"
    }

    func console() async throws -> String {
        let logs = try await evaluate("JSON.stringify(window.__anvilLogs || [])")
        let list = JSON.parse(logs)?.array?.compactMap(\.string) ?? []
        return list.isEmpty ? "console is empty (no logs, errors or failed requests since the page loaded)" : list.suffix(80).joined(separator: "\n")
    }

    func screenshot() async throws -> Data {
        let img = try await webView.takeSnapshot(configuration: nil)
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { throw ToolFailure("couldn't capture the page") }
        return jpg
    }
}

/// The agent's browser tools (only registered when the app provides a browser).
enum BrowserTools {
    static func all() -> [ToolSpec] { [open, read, find, click, type, key, select, hover, scroll, wait, nav, console, viewport, eval, screenshot] }

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
}
