import SwiftUI

/// Signed-in web accounts for one provider: sign in once, and Anvil keeps the session fresh.
/// Several accounts per provider are allowed; requests start on the first and fall through.
struct AccountsSection: View {
    @Environment(AppState.self) private var app
    let provider: Provider
    @State private var pasting = false

    private var site: String { provider == .chatgpt ? "ChatGPT" : "Gemini" }

    var body: some View {
        let list = WebAccounts.shared.accounts(for: provider)
        Section {
            if list.isEmpty {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider == .chatgpt ? "Use your ChatGPT plan" : "Use Gemini with your Google account").fontWeight(.medium)
                        Text(provider == .chatgpt ? "Sign in once. No API key or proxy needed." : "Free. Sign in once, no API key or proxy needed.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Sign in to \(site)…") { signIn() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 4)
            } else {
                ForEach(list) { account in
                    AccountRow(account: account, showsOrder: list.count > 1)
                }
                HStack {
                    Button { signIn() } label: { Label("Add another account", systemImage: "plus") }
                        .buttonStyle(.borderless)
                    Spacer()
                }
            }
        } header: {
            Label(provider.label, systemImage: provider.symbol)
        } footer: {
            HStack(alignment: .firstTextBaseline) {
                Text(provider == .chatgpt
                     ? "Talks to chatgpt.com the way the website does. Unofficial, so it can break when OpenAI changes the site. Sessions stay in your Keychain."
                     : "Talks to gemini.google.com the way the website does. Unofficial; Google may rate-limit busy accounts, so a second one helps. Sessions stay in your Keychain.")
                Spacer(minLength: 8)
                Button("Paste cookies…") { pasting = true }
                    .buttonStyle(.link).fixedSize()
                    .help("Add an account from cookies copied out of another browser")
            }
            .font(.caption)
        }
        .sheet(isPresented: $pasting) {
            AddWebAccountSheet(provider: provider) { app.resetAgents() }
        }
    }

    private func signIn() {
        WebLoginWindow.shared.present(provider: provider) { _ in app.resetAgents() }
    }
}

private struct AccountRow: View {
    let account: WebAccount
    let showsOrder: Bool
    @Environment(AppState.self) private var app
    @State private var renaming = false
    @State private var draft = ""
    @State private var checking = false
    @State private var checked = false
    @State private var confirmRemove = false

    var body: some View {
        let store = WebAccounts.shared
        let active = store.isActive(account.id)
        HStack(alignment: .center, spacing: 10) {
            if showsOrder {
                Button { store.select(account.id) } label: {
                    Image(systemName: active ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(active ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help(active ? "Requests start on this account" : "Start requests on this account")
            }

            VStack(alignment: .leading, spacing: 2) {
                if renaming {
                    TextField("Name", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { store.rename(account.id, to: draft); renaming = false }
                        .onExitCommand { renaming = false }
                } else {
                    HStack(spacing: 6) {
                        Text(account.label).fontWeight(.medium)
                        if !account.enabled { Text("Paused").font(.caption2).foregroundStyle(.secondary) }
                    }
                }
                if let detail = subtitle { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                if let until = account.cooldownUntil, account.isResting, account.enabled {
                    Text("Resting until \(until.formatted(date: .omitted, time: .shortened)) (usage limit)")
                        .font(.caption).foregroundStyle(.secondary)
                } else if account.needsAttention, account.enabled {
                    Label(account.lastError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange).lineLimit(2)
                } else {
                    Text(usageLine).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()

            if checking {
                ProgressView().controlSize(.small)
            } else if checked {
                Label("Signed in", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
            } else if account.needsAttention, account.enabled, !account.isResting {
                Button("Sign in again") { reconnect() }
            }

            Menu {
                if showsOrder, !active { Button("Use this account first") { store.select(account.id) } }
                Button("Check sign-in") { Task { await check() } }
                Button("Sign in again…") { reconnect() }
                Divider()
                Button("Rename") { draft = account.label; renaming = true }
                Button(account.enabled ? "Pause" : "Resume") { store.setEnabled(account.id, !account.enabled) }
                Button("Reset usage") { store.resetUsage(account.id) }
                Divider()
                Button("Remove…", role: .destructive) { confirmRemove = true }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .opacity(account.enabled ? 1 : 0.55)
        .confirmationDialog("Remove \(account.label)?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) {
                store.delete(account.id)
                app.resetAgents()
            }
        } message: {
            Text("Anvil forgets this session. You can sign in again any time.")
        }
    }

    /// Plan or address, when it adds something the name doesn't already say.
    private var subtitle: String? {
        let parts = account.detail.components(separatedBy: " · ").filter { !$0.isEmpty && $0 != account.label && $0 != "Google account" }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var usageLine: String {
        guard account.callsTotal > 0 else { return "Not used yet" }
        let week = account.week
        var parts = ["Today \(account.callsToday) calls", "7 days \(week.calls) calls, ~\(Fmt.tokens(week.tokens)) tokens"]
        if let last = account.lastUsedLabel { parts.append("last used \(last)") }
        return parts.joined(separator: " · ")
    }

    private func reconnect() {
        WebLoginWindow.shared.present(provider: account.provider, reconnecting: account) { _ in app.resetAgents() }
    }

    /// Checks the stored session; if it has expired, quietly tries Safari's session for the same person.
    private func check() async {
        let store = WebAccounts.shared
        checking = true
        defer { checking = false }
        do {
            let v = try await WebSignIn.verify(account.provider, cookies: store.cookies(account.id), accountID: account.id, authUser: account.authUser)
            store.save(v, provider: account.provider, replacing: account.id)
        } catch {
            if let fresh = await WebSignIn.safariSession(matching: account) {
                store.save(fresh, provider: account.provider, replacing: account.id)
            } else {
                store.markError(account.id, "Signed out: \(WebSignIn.message(error))")
                return
            }
        }
        checked = true
        try? await Task.sleep(for: .seconds(2.5))
        checked = false
    }
}

/// The old proxy path, kept for people who already run one (and as a fallback).
struct ProxyFallbackSettings: View {
    @Bindable private var s = AppSettings.shared
    @State private var gemDraft = ""

    var body: some View {
        Section {
            DisclosureGroup("Advanced: use a self-hosted proxy") {
                TextField("Gemini proxy URL", text: $s.geminiURL)
                HStack {
                    SecureField(s.geminiKey.isEmpty ? "Proxy key" : "Key saved", text: $gemDraft)
                    Button("Save") { s.geminiKey = gemDraft.trimmingCharacters(in: .whitespaces); gemDraft = "" }.disabled(gemDraft.isEmpty)
                }
                TextField("ChatGPT proxy URL", text: $s.chatgptURL)
                HStack {
                    TextField("Folder you cloned zhaees/chatgpt-proxy into", text: $s.chatgptProxyFolder)
                    Button("Choose…") {
                        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                        if panel.runModal() == .OK, let u = panel.url { s.chatgptProxyFolder = u.path }
                    }
                }
                HStack {
                    let proxy = ChatGPTProxy.shared
                    Label(proxy.running ? "Running" : (proxy.status.isEmpty ? "Not checked" : proxy.status), systemImage: proxy.running ? "checkmark.circle.fill" : "circle")
                        .font(.caption).foregroundStyle(proxy.running ? .green : .secondary)
                    Spacer()
                    Button("Check") { Task { _ = await proxy.check() } }
                    if !s.chatgptProxyFolder.isEmpty {
                        Button(proxy.running ? "Stop" : "Start") { Task { if proxy.running { proxy.stop() } else { await proxy.ensureRunning() } } }
                    }
                }
                Text("Only for people who already run one. Anvil uses a proxy only when no account is signed in, or when every account fails.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
