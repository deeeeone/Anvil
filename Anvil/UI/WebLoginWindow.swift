import AppKit
import WebKit

/// A window that opens the provider's sign-in page and adds the account by itself as soon as the
/// session cookie appears: no buttons to press after signing in. Each window gets a throwaway
/// website store, so the next account doesn't inherit the previous one.
///
/// Passkeys and Google's "this browser may not be secure" check don't work in an embedded web view,
/// so "Use Safari" signs in there instead and reads the session from Safari's cookies (that needs
/// Full Disk Access, which the window asks for when it's missing).
@MainActor
final class WebLoginWindow: NSObject, NSWindowDelegate, WKUIDelegate, WKNavigationDelegate {
    static let shared = WebLoginWindow()

    private var window: NSWindow?
    private var webView: WKWebView?
    private var store: WKWebsiteDataStore?
    private var provider: Provider = .chatgpt
    /// Set when signing an existing account back in: the new session replaces its cookies.
    private var reconnecting: WebAccount?
    private var onAdded: ((UUID) -> Void)?
    private var poll: Task<Void, Never>?
    private var status: NSTextField?
    private var spinner: NSProgressIndicator?
    private var safariButton: NSButton?
    private var accessButton: NSButton?
    private var accountID = UUID()
    private var lastSeen = ""
    private var busy = false
    private var finished = false
    private var watchSafari = false
    /// Safari sessions already looked at, so the same one isn't checked every second.
    private var safariSeen: Set<String> = []

    private var site: String { provider == .chatgpt ? "ChatGPT" : "Gemini" }

    private var signInURL: URL {
        switch provider {
        case .gemini:
            return URL(string: "https://accounts.google.com/ServiceLogin?service=wise&continue=https%3A%2F%2Fgemini.google.com%2Fapp")!
        default:
            return URL(string: "https://chatgpt.com/auth/login?next=%2F")!
        }
    }

    private var hint: String {
        if let reconnecting { return "Sign in as \(reconnecting.label). Anvil picks the session up as soon as you're in." }
        return "Sign in below. Anvil adds the account as soon as you're in. Passkey or blocked? Use Safari."
    }

    /// Opens the sign-in window. `reconnecting` signs an existing account back in instead of adding one.
    func present(provider: Provider, reconnecting: WebAccount? = nil, onAdded: @escaping (UUID) -> Void = { _ in }) {
        close()
        self.provider = provider
        self.reconnecting = reconnecting
        self.onAdded = onAdded
        accountID = reconnecting?.id ?? UUID()
        lastSeen = ""
        busy = false
        finished = false
        watchSafari = false
        safariSeen = []

        let store = WKWebsiteDataStore.nonPersistent()
        self.store = store
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = store
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.customUserAgent = ChatGPTWebClient.userAgent
        web.uiDelegate = self
        web.navigationDelegate = self
        web.isInspectable = true
        webView = web

        let label = NSTextField(wrappingLabelWithString: hint)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        status = label

        let spin = NSProgressIndicator()
        spin.style = .spinning
        spin.controlSize = .small
        spin.isDisplayedWhenStopped = false
        spinner = spin

        let access = NSButton(title: "Grant Access…", target: self, action: #selector(accessTapped))
        access.bezelStyle = .rounded
        access.isHidden = true
        accessButton = access

        let safari = NSButton(title: "Use Safari", target: self, action: #selector(safariTapped))
        safari.bezelStyle = .rounded
        safari.toolTip = "Sign in with Safari, where passkeys and saved passwords work. Anvil reads the session from Safari."
        safariButton = safari

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"

        let bar = NSStackView(views: [label, spin, access, safari, cancel])
        bar.orientation = .horizontal
        bar.spacing = 10
        bar.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)

        let root = NSStackView(views: [web, bar])
        root.orientation = .vertical
        root.spacing = 0
        root.distribution = .fill
        web.setContentHuggingPriority(.defaultLow, for: .vertical)
        bar.setContentHuggingPriority(.required, for: .vertical)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 680),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = reconnecting == nil ? "Sign in to \(site)" : "Sign in to \(site) again"
        window.contentView = root
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        window.minSize = NSSize(width: 560, height: 480)
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        web.load(URLRequest(url: signInURL))

        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.window != nil else { return }
                await self.tick()
            }
        }
    }

    /// Looks for a signed-in session in the window, then (once asked to) in Safari.
    private func tick() async {
        guard let store, !busy, !finished else { return }
        let found = await CookieJar.all(for: provider, from: store)
        if WebAccounts.looksSignedIn(provider, found) {
            let seen = Self.signature(provider, found)
            guard seen != lastSeen else { return }
            lastSeen = seen
            await validate(found, from: "window")
            return
        }
        guard watchSafari else { return }
        let p = provider
        let result = await Task.detached { () -> Result<[String: String], Error> in
            Result { try SafariCookies.cookies(for: p) }
        }.value
        switch result {
        case .failure(SafariCookies.Failure.noAccess):
            showAccessNeeded(true)
        case .failure:
            break
        case .success(let safari):
            showAccessNeeded(false)
            guard WebAccounts.looksSignedIn(p, safari) else { return }
            let seen = Self.signature(p, safari)
            guard !safariSeen.contains(seen) else { return }
            safariSeen.insert(seen)
            await validate(safari, from: "Safari")
        }
    }

    // MARK: Actions

    @objc private func cancelTapped() {
        finished = true
        close()
    }

    @objc private func safariTapped() {
        watchSafari = true
        safariButton?.isEnabled = false
        say("Finish signing in in Safari. Anvil picks the session up from there by itself.", tone: .info)
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") {
            NSWorkspace.shared.open([signInURL], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(signInURL)
        }
        Task { await tick() }   // Safari may already be signed in.
    }

    @objc private func accessTapped() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    private func showAccessNeeded(_ needed: Bool) {
        guard accessButton?.isHidden == needed else { return }
        accessButton?.isHidden = !needed
        if needed {
            say("To read the Safari sign-in, turn on Anvil under Full Disk Access. This window keeps waiting.", tone: .warning)
        } else {
            say("Finish signing in in Safari. Anvil picks the session up from there by itself.", tone: .info)
        }
    }

    private func validate(_ cookies: [String: String], from source: String) async {
        guard !busy, !finished else { return }
        busy = true
        spinner?.startAnimation(nil)
        say(source == "Safari" ? "Found a session in Safari. Checking it…" : "Signed in. Checking the account…", tone: .info)
        defer { busy = false; spinner?.stopAnimation(nil) }

        do {
            let verified = try await WebSignIn.verify(provider, cookies: cookies, accountID: accountID)
            let accounts = WebAccounts.shared
            var replacing: UUID?
            if let reconnecting {
                let want = reconnecting.email.lowercased()
                if want.isEmpty || verified.email.isEmpty || verified.email.lowercased() == want {
                    replacing = reconnecting.id
                }
            } else if source == "Safari",
                      let same = accounts.accounts(for: provider).first(where: { !$0.email.isEmpty && $0.email.lowercased() == verified.email.lowercased() }),
                      !same.needsAttention {
                // Safari is signed in to an account that's already here and working: wait for a different one.
                say("Safari is signed in as \(same.label), which is already added. Sign in as someone else in Safari, or Cancel.", tone: .warning)
                return
            }
            let id = accounts.save(verified, provider: provider, replacing: replacing).id
            let who = verified.email.isEmpty ? "your \(site) account" : verified.email
            if let reconnecting, replacing == nil {
                say("That's \(who), not \(reconnecting.label). Added it as another account.", tone: .success)
            } else {
                say(replacing == nil ? "Added \(who)." : "\(who) is signed in again.", tone: .success)
            }
            finished = true
            onAdded?(id)
            try? await Task.sleep(for: .seconds(0.9))
            close()
        } catch {
            say(WebSignIn.message(error), tone: .warning)
        }
    }

    private static func signature(_ provider: Provider, _ cookies: [String: String]) -> String {
        let required = WebAccounts.requiredCookie(provider)
        return cookies.keys.filter { $0 == required || $0.hasPrefix(required + ".") }.sorted()
            .map { $0 + "=" + (cookies[$0] ?? "") }.joined(separator: "|")
    }

    private enum Tone { case info, warning, success }

    private func say(_ text: String, tone: Tone) {
        status?.stringValue = text
        switch tone {
        case .info: status?.textColor = .secondaryLabelColor
        case .warning: status?.textColor = .systemOrange
        case .success: status?.textColor = .systemGreen
        }
    }

    private func close() {
        poll?.cancel()
        poll = nil
        webView?.stopLoading()
        webView = nil
        store = nil
        window?.delegate = nil
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        poll?.cancel()
        poll = nil
        webView = nil
        store = nil
        window = nil
    }

    // MARK: WebKit

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) { completionHandler() }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !finished, !busy, !watchSafari else { return }
        // Google refuses sign-in from embedded browsers on some accounts; point at Safari right away.
        let url = webView.url?.absoluteString ?? ""
        if url.contains("accounts.google.com"), url.contains("rejected") || url.contains("disallowed_useragent") {
            say("Google blocked sign-in in this window. Click Use Safari to sign in there instead.", tone: .warning)
            safariButton?.keyEquivalent = "\r"
        }
    }
}
