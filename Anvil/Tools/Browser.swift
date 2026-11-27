#if canImport(WebKit)
import AppKit
import WebKit
import Observation


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
        // A web view in no window (headless runs, or the Preview tab hidden) doesn't render, and its snapshot comes back
        // blank white. Park it in an off-screen window for the shot, then take it out again.
        var parked: NSWindow?
        if webView.window == nil {
            let size = NSSize(width: viewportWidth ?? 1280, height: viewportHeight ?? 860)
            let w = NSWindow(contentRect: NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: size), styleMask: .borderless, backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            webView.frame = NSRect(origin: .zero, size: size)
            w.contentView?.addSubview(webView)
            w.orderBack(nil)
            parked = w
            try? await Task.sleep(for: .milliseconds(500))   // first paint
        }
        defer { if let w = parked { webView.removeFromSuperview(); w.orderOut(nil) } }
        let img = try await webView.takeSnapshot(configuration: nil)
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { throw ToolFailure("couldn't capture the page") }
        return jpg
    }
}
#endif
