import SwiftUI

/// Adds a ChatGPT or Gemini account from cookies copied out of another browser. The sign-in
/// window is the normal path; this is for browsers Anvil can't read. Cookies go to the Keychain.
struct AddWebAccountSheet: View {
    let provider: Provider
    var onAdded: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var pasted = ""
    @State private var checking = false
    @State private var message = ""
    @State private var failed = false
    /// Which signed-in Google account in the browser the cookies belong to (0 is the first).
    @State private var authUser = 0

    private var site: String { provider == .chatgpt ? "ChatGPT" : "Gemini" }
    private var host: String { provider == .chatgpt ? "chatgpt.com" : "gemini.google.com" }
    private var cookies: [String: String] { WebAccounts.parseCookies(pasted) }
    private var ready: Bool { WebAccounts.looksSignedIn(provider, cookies) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Add a \(site) account from cookies", systemImage: provider.symbol)
                .font(.system(size: 15, weight: .semibold))

            Text("In a browser signed in to \(host), open DevTools → Network, click any request to \(host), and copy its **Cookie** request header. Cookie JSON from an export extension works too.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $pasted)
                .font(.system(size: 11, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    if pasted.isEmpty {
                        Text("Paste here").font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary).padding(11).allowsHitTesting(false)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                .frame(minHeight: 200)
                .onChange(of: pasted) { message = ""; failed = false }

            if provider == .gemini {
                HStack(spacing: 8) {
                    Stepper(value: $authUser, in: 0...9) {
                        Text("Account in that browser: \(authUser)").font(.caption)
                    }
                    .fixedSize()
                    .onChange(of: authUser) { message = ""; failed = false }
                    Text("0 is the first Google account signed in to that browser.")
                        .font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                }
            }

            HStack(spacing: 8) {
                if checking {
                    ProgressView().controlSize(.small)
                    Text("Checking with \(site)…").font(.caption).foregroundStyle(.secondary)
                } else if !message.isEmpty {
                    Label(message, systemImage: failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(failed ? .orange : .green).lineLimit(3)
                } else if !pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Label(ready ? "Looks signed in" : "Missing \(WebAccounts.requiredCookie(provider))",
                          systemImage: ready ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(ready ? .green : .orange)
                }
                Spacer()
            }

            HStack {
                Button("Sign in instead…") {
                    dismiss()
                    WebLoginWindow.shared.present(provider: provider) { _ in onAdded() }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add Account") { Task { await add() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ready || checking)
            }
        }
        .padding(18)
        .frame(width: 580, height: 460)
    }

    private func add() async {
        checking = true
        defer { checking = false }
        do {
            let verified = try await WebSignIn.verify(provider, cookies: cookies, authUser: provider == .gemini ? authUser : nil)
            let saved = WebAccounts.shared.save(verified, provider: provider)
            onAdded()
            if saved.added {
                failed = false
                message = verified.email.isEmpty ? "Added." : "Added \(verified.email)."
                try? await Task.sleep(for: .seconds(0.7))
                dismiss()
            } else {
                // Same person as an account already here: stay open so the account number can be changed.
                failed = true
                let who = WebAccounts.shared.account(saved.id)?.label ?? "an account"
                message = "These cookies are for \(who), which is already added, so it was refreshed."
                    + (provider == .gemini ? " In a browser with several Google accounts, pick the account number below." : "")
            }
        } catch {
            failed = true
            message = WebSignIn.message(error)
        }
    }
}
