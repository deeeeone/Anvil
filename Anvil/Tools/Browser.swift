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
    func network(filter: String?, limit: Int, bodies: Bool, clear: Bool) async throws -> String
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
    /// Records requests the page makes (fetch, XHR, resource and navigation loads) into window.__anvilNet, newest 400.
    static let networkHook = #"""
    (() => { if (window.__anvilNet) return; window.__anvilNet = [];
      const MASK = /auth|cookie|key|token|secret|session/i;
      const textish = ct => /text|json|javascript|xml|html/i.test(ct || '');
      const abs = u => { try { return new URL(String(u), location.href).href } catch (e) { return String(u) } };
      const hdrs = h => { const o = {};
        try { if (!h) return o;
          if (typeof Headers !== 'undefined' && h instanceof Headers) h.forEach((v, k) => { o[k] = v });
          else if (Array.isArray(h)) h.forEach(p => { o[p[0]] = p[1] });
          else if (typeof h === 'object') Object.keys(h).forEach(k => { o[k] = h[k] });
          for (const k of Object.keys(o)) o[k] = MASK.test(k) ? '***' : String(o[k]).slice(0, 300);
        } catch (e) {}
        return o };
      const keep = e => { try { const n = window.__anvilNet; n.push(e); if (n.length > 400) n.splice(0, n.length - 400) } catch (x) {} return e };
      const begin = (type, method, url, headers, b) => keep({ t: Date.now(), method: String(method || 'GET').toUpperCase(), url: abs(url), type: type,
        status: null, ok: null, ms: null, ct: '', size: null, reqHeaders: hdrs(headers), reqBody: typeof b === 'string' ? b.slice(0, 1000) : undefined, err: '' });
      try {
        const f = window.fetch;
        if (f) window.fetch = function (input, init) {
          let e = null, start = 0;
          try {
            const req = typeof Request !== 'undefined' && input instanceof Request ? input : null;
            e = begin('fetch', (init && init.method) || (req && req.method), req ? req.url : input, (init && init.headers) || (req && req.headers), init && init.body);
            start = performance.now();
          } catch (x) { e = null }
          const p = f.apply(this, arguments);
          if (!e) return p;
          return p.then(r => {
            try {
              e.status = r.status; e.ok = r.ok; e.ms = Math.round(performance.now() - start);
              e.ct = r.headers.get('content-type') || '';
              const len = Number(r.headers.get('content-length')) || null;
              e.size = len;
              if (textish(e.ct) && !(len > 1000000)) r.clone().text().then(t => { e.size = e.size || t.length; e.body = t.slice(0, 2000) }, () => {});
            } catch (x) {}
            return r;
          }, err => {
            try { e.err = String((err && err.message) || err); e.ms = Math.round(performance.now() - start) } catch (x) {}
            throw err;
          });
        };
      } catch (e) {}
      try {
        const X = window.XMLHttpRequest;
        if (X) {
          const open = X.prototype.open, setH = X.prototype.setRequestHeader, send = X.prototype.send;
          X.prototype.open = function (method, url) {
            try { this.__anvil = { method: method, url: url, reqHeaders: {} } } catch (x) {}
            return open.apply(this, arguments);
          };
          X.prototype.setRequestHeader = function (k, v) {
            try { if (this.__anvil) this.__anvil.reqHeaders[k] = MASK.test(k) ? '***' : String(v).slice(0, 300) } catch (x) {}
            return setH.apply(this, arguments);
          };
          X.prototype.send = function (b) {
            try {
              const d = this.__anvil;
              if (d) {
                const e = begin('xhr', d.method, d.url, d.reqHeaders, b);
                const start = performance.now();
                this.addEventListener('loadend', () => { try {
                  e.status = this.status || null; e.ok = this.status >= 200 && this.status < 300;
                  e.ms = Math.round(performance.now() - start);
                  if (!this.status) e.err = 'failed';
                  e.ct = this.getResponseHeader('content-type') || '';
                  const len = Number(this.getResponseHeader('content-length')) || null;
                  e.size = len;
                  if (textish(e.ct) && (this.responseType === '' || this.responseType === 'text') && typeof this.responseText === 'string') { e.size = e.size || this.responseText.length; e.body = this.responseText.slice(0, 2000) }
                } catch (x) {} });
              }
            } catch (x) {}
            return send.apply(this, arguments);
          };
        }
      } catch (e) {}
      try {
        if (window.PerformanceObserver) {
          const po = new PerformanceObserver(list => {
            for (const p of list.getEntries()) { try {
              const t = Math.round(performance.timeOrigin + p.startTime);
              if ((window.__anvilNet || []).some(x => (x.type === 'fetch' || x.type === 'xhr') && x.url === p.name && Math.abs(x.t - t) < 1000)) continue;
              const status = p.responseStatus || null;
              const type = p.entryType === 'navigation' ? 'navigation' : p.initiatorType === 'xmlhttprequest' ? 'xhr' : p.initiatorType;
              keep({ t: t, method: 'GET', url: p.name, type: type, status: status, ok: status ? status < 400 : null, ms: Math.round(p.duration),
                ct: '', size: Math.round(p.transferSize || p.encodedBodySize || 0) || null, err: '' });
            } catch (x) {} }
          });
          try { po.observe({ entryTypes: ['resource', 'navigation'], buffered: true }) }
          catch (x) { try { po.observe({ type: 'resource', buffered: true }) } catch (y) {} }
        }
      } catch (e) {}
    })();
    """#
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []

    @ObservationIgnored lazy var webView: WKWebView = {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.userContentController.addUserScript(WKUserScript(source: Self.consoleHook, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        cfg.userContentController.addUserScript(WKUserScript(source: Self.networkHook, injectionTime: .atDocumentStart, forMainFrameOnly: false))
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
        let requested = u.absoluteString
        url = requested
        lastError = nil
        loading = true
        // Opening the page already on screen reloads it, instead of WebKit treating the same load as a no-op.
        if u.isFileURL { webView.loadFileURL(u, allowingReadAccessTo: u.deletingLastPathComponent()) }
        else if let shown = webView.url?.absoluteString, BrowserQA.sameURL(shown, requested) { webView.reloadFromOrigin() }
        else { webView.load(URLRequest(url: u)) }
        await waitForLoad(timeout: 20)
        if let e = lastError { return "couldn't load \(requested): \(e)" }
        if loading { return "still loading \(requested) after 20s; browser_read or browser_console shows where it got to" }
        let text = (try? await evaluate("document.body ? document.body.innerText.slice(0, 3000) : ''")) ?? ""
        return BrowserQA.describeLoaded(requested: requested, final: webView.url?.absoluteString ?? requested,
                                        title: webView.title ?? "", notFound: BrowserQA.looksLikeNotFound(title: webView.title ?? "", text: text))
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
        MainActor.assumeIsolated { failed(webView, error) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { failed(webView, error) }
    }

    /// A navigation replaced by another one (-999, or "Frame load interrupted") isn't a failure: the replacement's
    /// didFinish ends the wait. If nothing is loading any more, nothing will finish, so the wait ends here.
    private func failed(_ webView: WKWebView, _ error: Error) {
        guard !BrowserQA.isSupersededNavigation(error) else {
            if !webView.isLoading { loading = false; resumeWaiters() }
            return
        }
        loading = false
        lastError = error.localizedDescription
        resumeWaiters()
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

    /// Requests the page made since it loaded, newest last. filter: url substring, "status>=400" or "type=xhr".
    func network(filter: String?, limit: Int, bodies: Bool, clear: Bool) async throws -> String {
        let raw = try await evaluate("(() => { const n = JSON.stringify(window.__anvilNet || []); if (\(clear)) window.__anvilNet = []; return n })()")
        let all = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [[String: Any]] ?? []
        let f = (filter ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        var needle = f
        var statusTest: (op: String, n: Int)?
        var wantType: String?
        if f.hasPrefix("status") {
            let rest = f.dropFirst(6).trimmingCharacters(in: .whitespaces)
            if let op = [">=", "<=", ">", "<", "="].first(where: { rest.hasPrefix($0) }),
               let n = Int(rest.dropFirst(op.count).trimmingCharacters(in: .whitespaces)) { statusTest = (op, n); needle = "" }
        } else if f.hasPrefix("type=") {
            wantType = String(f.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            needle = ""
        }
        let hits = all.filter { e in
            if !needle.isEmpty && !((e["url"] as? String) ?? "").lowercased().contains(needle) { return false }
            if let w = wantType, (e["type"] as? String) != w { return false }
            if let s = statusTest {
                guard let code = Self.num(e, "status") else { return false }
                let ok: Bool
                switch s.op {
                case ">=": ok = code >= s.n
                case "<=": ok = code <= s.n
                case ">": ok = code > s.n
                case "<": ok = code < s.n
                default: ok = code == s.n
                }
                if !ok { return false }
            }
            return true
        }
        guard !all.isEmpty else { return "no requests recorded since the page loaded" }
        guard !hits.isEmpty else { return "no request matches \"\(filter ?? "")\"" }
        let picked = Array(hits.suffix(max(1, limit)))
        let head = picked.count < hits.count ? "showing the last \(picked.count) of \(hits.count) requests\n" : ""
        return head + picked.map { Self.netLine($0, bodies: bodies) }.joined(separator: "\n")
    }

    private static func num(_ e: [String: Any], _ k: String) -> Int? { (e[k] as? NSNumber)?.intValue }

    /// One request: method, status, type, timing, size, url; with bodies, headers and response preview indented under it.
    private static func netLine(_ e: [String: Any], bodies: Bool) -> String {
        let err = (e["err"] as? String) ?? ""
        let status = num(e, "status").map { String($0) } ?? (err.isEmpty ? "-" : "failed")
        let ms = num(e, "ms").map { "\($0)ms" } ?? "-"
        let size = num(e, "size").map { $0 < 1024 ? "\($0)B" : String(format: "%.1fkB", Double($0) / 1024) } ?? "-"
        var line = "\((e["method"] as? String) ?? "GET") \(status) \((e["type"] as? String) ?? "?") \(ms) \(size) \((e["url"] as? String) ?? "")"
        if !err.isEmpty { line += " (\(err))" }
        guard bodies else { return line }
        func oneLine(_ s: String) -> String { s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
        var out = [line]
        if let h = e["reqHeaders"] as? [String: String], !h.isEmpty {
            out.append("    request headers: " + h.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "; "))
        }
        if let b = e["reqBody"] as? String, !b.isEmpty { out.append("    request body: " + oneLine(b)) }
        if let b = e["body"] as? String, !b.isEmpty {
            let ct = (e["ct"] as? String) ?? ""
            out.append("    response" + (ct.isEmpty ? "" : " (\(ct))") + ": " + oneLine(b))
        }
        return out.joined(separator: "\n")
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
