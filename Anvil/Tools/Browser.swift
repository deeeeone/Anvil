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
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []

    @ObservationIgnored lazy var webView: WKWebView = {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
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
            return '[' + (i + 1) + '] ' + e.tagName.toLowerCase() + (e.type ? '(' + e.type + ')' : '') + ' "' + label + '"' + (e.href ? ' -> ' + e.getAttribute('href') : '');
          });
          const text = (document.body ? document.body.innerText : '').replace(/\\n{3,}/g, '\\n\\n').slice(0, 7000);
          return 'url: ' + location.href + '\\ntitle: ' + document.title + '\\n\\ntext:\\n' + text + '\\n\\nelements:\\n' + items.join('\\n');
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

    func screenshot() async throws -> Data {
        let img = try await webView.takeSnapshot(configuration: nil)
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { throw ToolFailure("couldn't capture the page") }
        return jpg
    }
}

/// The agent's browser tools (only registered when the app provides a browser).
enum BrowserTools {
    static func all() -> [ToolSpec] { [open, read, click, type, eval, screenshot] }

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
                               summary: "run JavaScript in the open page and return the result (check console state, read computed styles, test behaviour)", group: .web) { a, ctx in
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
