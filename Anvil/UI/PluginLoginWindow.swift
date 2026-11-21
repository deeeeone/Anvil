import AppKit
import WebKit

/// Sign-in for provider plugins with `"auth": {"type": "web"}`: opens the spec's login page in a throwaway
/// browser, and once the cookies (or localStorage keys) the spec names exist for its domain, saves them
/// as the plugin's session and closes. Only that domain's values are kept.
@MainActor
final class PluginLoginWindow: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    static let shared = PluginLoginWindow()

    private var window: NSWindow?
    private var webView: WKWebView?
    private var store: WKWebsiteDataStore?
    private var provider: InstalledProvider?
    private var status: NSTextField?
    private var poll: Task<Void, Never>?
    private var onDone: (() -> Void)?
    private var finished = false

    func present(_ p: InstalledProvider, onDone: @escaping () -> Void = {}) {
        close()
        guard let url = URL(string: p.spec.auth.loginURL ?? "") else { return }
        provider = p
        self.onDone = onDone
        finished = false
        let store = WKWebsiteDataStore.nonPersistent()
        self.store = store
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = store
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.customUserAgent = ChatGPTWebClient.userAgent
        web.navigationDelegate = self
        web.uiDelegate = self
        webView = web

        let label = NSTextField(wrappingLabelWithString: p.spec.auth.manual == true
            ? "Sign in below, then click I'm signed in. Anvil saves the session for \(p.spec.name)."
            : "Sign in below. Anvil saves the session for \(p.spec.name) as soon as you're in.")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        status = label
        let done = NSButton(title: "I'm signed in", target: self, action: #selector(doneTapped))
        done.bezelStyle = .rounded
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let bar = NSStackView(views: [label, done, cancel])
        bar.spacing = 10
        bar.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        let root = NSStackView(views: [web, bar])
        root.orientation = .vertical
        root.spacing = 0
        web.setContentHuggingPriority(.defaultLow, for: .vertical)
        bar.setContentHuggingPriority(.required, for: .vertical)

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 680), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "Sign in to \(p.spec.name)"
        w.contentView = root
        w.delegate = self
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        web.load(URLRequest(url: url))

        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.window != nil else { return }
                if let p = self.provider, p.spec.auth.manual != true, let s = await self.capture(), self.signedIn(s) { self.save(s); return }
            }
        }
    }

    /// The spec's cookies and localStorage keys for its domain, as they are now.
    private func capture() async -> ProviderPlugins.Session? {
        guard let p = provider, let store, let webView else { return nil }
        let domain = (p.spec.auth.domain ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        var s = ProviderPlugins.Session()
        let cookies = await withCheckedContinuation { cont in store.httpCookieStore.getAllCookies { cont.resume(returning: $0) } }
        for c in cookies {
            let d = c.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if (d == domain || d.hasSuffix("." + domain)) && !c.value.isEmpty { s.cookies[c.name] = c.value }
        }
        let keys = p.spec.auth.localStorage ?? []
        if !keys.isEmpty, let host = webView.url?.host?.lowercased(), host == domain || host.hasSuffix("." + domain) {
            let js = "JSON.stringify(Object.fromEntries(\(Self.jsArray(keys)).map(k => [k, localStorage.getItem(k) || ''])))"
            if let json = try? await webView.evaluateJavaScript(js) as? String, let obj = JSON.parse(json)?.object {
                for (k, v) in obj { if let v = v.string, !v.isEmpty { s.localStorage[k] = v } }
            }
        }
        return s
    }

    private func signedIn(_ s: ProviderPlugins.Session) -> Bool {
        guard let p = provider else { return false }
        let needCookies = p.spec.auth.cookies ?? []
        let needKeys = p.spec.auth.localStorage ?? []
        guard !needCookies.isEmpty || !needKeys.isEmpty else { return false }
        return needCookies.allSatisfy { s.cookies[$0] != nil } && needKeys.allSatisfy { s.localStorage[$0] != nil }
    }

    private func save(_ s: ProviderPlugins.Session) {
        guard let p = provider, !finished else { return }
        finished = true
        ProviderPlugins.shared.setSession(p.id, s)
        status?.stringValue = "Signed in. Closing…"
        status?.textColor = .systemGreen
        onDone?()
        Task { await ProviderPlugins.shared.refreshModels(p.id); await ModelCatalog.shared.refresh() }
        Task { try? await Task.sleep(for: .seconds(0.8)); close() }
    }

    static func jsArray(_ keys: [String]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: keys)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    @objc private func doneTapped() {
        Task {
            guard let s = await capture() else { return }
            if signedIn(s) { save(s); return }
            let p = provider
            let missing = (p?.spec.auth.cookies ?? []).filter { s.cookies[$0] == nil } + (p?.spec.auth.localStorage ?? []).filter { s.localStorage[$0] == nil }
            status?.stringValue = "Still signed out: \(missing.joined(separator: ", ")) not found yet."
            status?.textColor = .systemOrange
        }
    }

    @objc private func cancelTapped() { close() }

    private func close() {
        poll?.cancel(); poll = nil
        webView?.stopLoading(); webView = nil
        store = nil
        window?.delegate = nil
        window?.close(); window = nil
    }

    func windowWillClose(_ notification: Notification) {
        poll?.cancel(); poll = nil
        webView = nil; store = nil; window = nil
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
        return nil
    }
}
