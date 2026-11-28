import XCTest
#if SWIFT_PACKAGE
@testable import AnvilCore
#else
@testable import Anvil
#endif

final class WebAccountTests: XCTestCase {
    func testParsesCookieHeaderAndJSON() {
        let header = WebAccounts.parseCookies("Cookie: _puid=user-1; __Secure-next-auth.session-token=abc.def; oai-sc=xyz")
        XCTAssertEqual(header["_puid"], "user-1")
        XCTAssertEqual(header["__Secure-next-auth.session-token"], "abc.def")

        let json = #"[{"name":"__Secure-1PSID","value":"psid","domain":".google.com"},{"name":"__Secure-1PSIDTS","value":"ts"}]"#
        let parsed = WebAccounts.parseCookies(json)
        XCTAssertEqual(parsed["__Secure-1PSID"], "psid")
        XCTAssertEqual(parsed["__Secure-1PSIDTS"], "ts")
    }

    func testSignedInNeedsTheSessionCookie() {
        XCTAssertFalse(WebAccounts.looksSignedIn(.chatgpt, ["_puid": "x"]))
        XCTAssertTrue(WebAccounts.looksSignedIn(.chatgpt, ["__Secure-next-auth.session-token": "x"]))
        XCTAssertTrue(WebAccounts.looksSignedIn(.chatgpt, ["__Secure-next-auth.session-token.0": "x", "__Secure-next-auth.session-token.1": "y"]))
        XCTAssertFalse(WebAccounts.looksSignedIn(.gemini, ["NID": "x"]))
        XCTAssertTrue(WebAccounts.looksSignedIn(.gemini, ["__Secure-1PSID": "x"]))
    }

    func testSHA3Vector() {
        let digest = SHA3.hash(Data()).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, "a69f73cca23a9ac5c8b567dc185a756e97c982164fe25859e0d1dcc1475c80a615b2123af1f5f94c11e3e9402c3ac558f500199d95b6d3e301758586281dcd26")
    }

    func testProofOfWorkMeetsTarget() {
        let seed = "test-seed"
        let difficulty = "00ff"
        let proof = ChatGPTWebClient.solve(seed: seed, difficulty: difficulty, dpl: "dpl-test", scripts: [])
        XCTAssertTrue(proof.hasPrefix("gAAAAAB"))
        let body = String(proof.dropFirst("gAAAAAB".count))
        let digest = SHA3.hash(Data(seed.utf8) + Data(body.utf8))
        XCTAssertLessThanOrEqual(digest.first!, 0x00)
        if digest.first! == 0 { XCTAssertLessThanOrEqual(digest[digest.startIndex + 1], 0xff) }
    }

    @MainActor
    func testAccountStoreKeepsUsagePerAccountAndDeletesCookies() async {        let store = WebAccounts.shared
        let marker = "test-\(UUID().uuidString)"
        store.add(provider: .chatgpt, name: marker, detail: "test", cookies: ["__Secure-next-auth.session-token": "t"])
        guard let account = store.accounts(for: .chatgpt).first(where: { $0.name == marker }) else {
            return XCTFail("account was not added")
        }
        defer { store.delete(account.id) }

        XCTAssertEqual(store.cookies(account.id)["__Secure-next-auth.session-token"], "t")
        store.record(account.id, prompt: 100, completion: 20)
        store.record(account.id, prompt: 10, completion: 2, error: "boom")
        let updated = store.account(account.id)
        XCTAssertEqual(updated?.callsToday, 1)
        XCTAssertEqual(updated?.tokensToday, 132)
        XCTAssertEqual(updated?.usage[WebAccount.day.string(from: Date())]?.errors, 1)
        XCTAssertEqual(updated?.lastError, "boom")

        store.resetUsage(account.id)
        XCTAssertEqual(store.account(account.id)?.tokensToday, 0)
        store.delete(account.id)
        XCTAssertNil(store.account(account.id))
        XCTAssertTrue(store.cookies(account.id).isEmpty)
    }
}

extension WebAccountTests {
    func testSafariCookieImportWhenAvailable() throws {
        guard SafariCookies.file != nil else { throw XCTSkip("Safari has no cookie file here") }
        let cookies: [String: String]
        do { cookies = try SafariCookies.cookies(for: .gemini) }
        catch { throw XCTSkip("No Full Disk Access for Safari cookies: \(error.localizedDescription)") }
        guard !cookies.isEmpty else { throw XCTSkip("Safari has no Google cookies here") }
        XCTAssertNotNil(cookies["__Secure-1PSID"])
    }
}

extension WebAccountTests {
    func testChatGPTSafariCookiesLive() async throws {
        guard let c = try? SafariCookies.cookies(for: .chatgpt), WebAccounts.looksSignedIn(.chatgpt, c) else {
            throw XCTSkip("Safari has no ChatGPT session here")
        }
        let client = ChatGPTWebClient(accountID: UUID(), cookies: c)
        do {
            let id = try await client.identity()
            print("LIVE identity ok:", id)
        } catch {
            print("LIVE identity failed:", error)
            throw error
        }
    }
}

extension WebAccountTests {
    func testChatGPTConversationLive() async throws {
        guard let c = try? SafariCookies.cookies(for: .chatgpt), WebAccounts.looksSignedIn(.chatgpt, c) else {
            throw XCTSkip("Safari has no ChatGPT session here")
        }
        let client = ChatGPTWebClient(accountID: UUID(), cookies: c)
        var streamed = ""
        do {
            let r = try await client.chat([.user("Reply with exactly: hello")], model: "chatgpt/auto", onText: { streamed = $0 }, shouldStop: nil)
            print("LIVE reply:", r.text.prefix(120), "streamed:", streamed.count)
            XCTAssertFalse(r.text.isEmpty)
        } catch {
            print("LIVE chat failed:", error)
            throw error
        }
    }
}

extension WebAccountTests {
    func testGeminiLive() async throws {
        guard let c = try? SafariCookies.cookies(for: .gemini), WebAccounts.looksSignedIn(.gemini, c) else {
            throw XCTSkip("Safari has no Gemini session here")
        }
        print("LIVE gemini cookies:", c.keys.sorted())
        print("LIVE psid len:", (c["__Secure-1PSID"] ?? "").count, "ts:", (c["__Secure-1PSIDTS"] ?? "").count)
        let client = GeminiWebClient(accountID: UUID(), cookies: c)
        do {
            _ = try await client.prepare()
            var streamed = ""
            let text = try await client.chat("Reply with exactly: hello", model: "gemini-pro-thinking", onText: { streamed = $0 }, shouldStop: nil)
            print("LIVE gemini:", text.prefix(160), "streamed:", streamed.count)
            XCTAssertFalse(text.isEmpty)
        } catch {
            print("LIVE gemini failed:", error)
            throw error
        }
    }
}

extension WebAccountTests {
    func testGeminiRawProbe() async throws {
        guard let c = try? SafariCookies.cookies(for: .gemini) else { throw XCTSkip() }
        let cookieHeader = c.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        print("LIVE cookieheader:", cookieHeader)
        var req = URLRequest(url: URL(string: "https://gemini.google.com/app")!)
        req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        req.setValue(ChatGPTWebClient.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let html = String(decoding: data, as: UTF8.self)
        print("LIVE probe status:", (resp as? HTTPURLResponse)?.statusCode ?? 0, "url:", resp.url?.absoluteString ?? "", "len:", data.count, "SNlM0e:", html.contains("SNlM0e"))
        print("LIVE head:", html.prefix(200))
    }
}

extension WebAccountTests {
    func testGeminiCookieDuplicates() throws {
        guard let f = SafariCookies.file else { throw XCTSkip() }
        guard let data = try? Data(contentsOf: f) else { throw XCTSkip("Safari's cookies aren't readable here (needs Full Disk Access)") }
        let recs = SafariCookies.parse(data)
        let wanted = recs.filter { $0.name == "__Secure-1PSID" || $0.name == "SAPISID" || $0.name == "__Secure-1PSIDTS" }
        for r in wanted { print("DUP", r.name, r.domain, r.path, r.value.prefix(10), r.expiry) }
    }
}

extension WebAccountTests {
    func testGeminiDomains() throws {
        guard let f = SafariCookies.file else { throw XCTSkip() }
        guard let data = try? Data(contentsOf: f) else { throw XCTSkip("Safari's cookies aren't readable here (needs Full Disk Access)") }
        let recs = SafariCookies.parse(data)
        var counts: [String: Int] = [:]
        for r in recs { counts[r.domain, default: 0] += 1 }
        for (d, n) in counts.sorted(by: { $0.key < $1.key }) where d.contains("google") { print("DOM", d, n) }
        for r in recs where r.domain.contains("gemini") { print("GEM", r.name, r.domain, r.path, r.value) }
    }
}

extension WebAccountTests {
    func testGeminiImageLive() async throws {
        guard let c = try? SafariCookies.cookies(for: .gemini), WebAccounts.looksSignedIn(.gemini, c) else {
            throw XCTSkip("Safari has no Gemini session here")
        }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        let client = GeminiWebClient(accountID: UUID(), cookies: c)
        do {
            _ = try await client.prepare()
            let text = try await client.chat("What is in this image? Answer in one short sentence.", images: [(png, "image/png")], model: "gemini-pro-thinking", onText: nil, shouldStop: nil)
            print("LIVE gemini image:", text.prefix(200))
            XCTAssertFalse(text.isEmpty)
        } catch {
            print("LIVE gemini image failed:", error)
            throw error
        }
    }
}

extension WebAccountTests {
    func testSigningInAgainRefreshesInsteadOfDuplicating() async {
        let store = WebAccounts.shared
        let email = "test-\(UUID().uuidString.prefix(8))@example.com".lowercased()
        var first = WebSignIn.Verified(accountID: UUID(), email: email, detail: "\(email) · Plus plan",
                                       cookies: ["__Secure-next-auth.session-token": "old"])
        let id = store.save(first, provider: .chatgpt).id
        defer { store.delete(id) }
        store.markError(id, "signed out")
        XCTAssertTrue(store.account(id)?.needsAttention ?? false)
        XCTAssertEqual(store.account(id)?.email, email)

        // Same person, new session, different case: same account, new cookies, error cleared.
        first.accountID = UUID()
        first.email = email.uppercased()
        first.cookies = ["__Secure-next-auth.session-token": "new"]
        let again = store.save(first, provider: .chatgpt)
        XCTAssertFalse(again.added)
        XCTAssertEqual(again.id, id)
        XCTAssertEqual(store.accounts(for: .chatgpt).filter { $0.email.lowercased() == email }.count, 1)
        XCTAssertEqual(store.cookies(id)["__Secure-next-auth.session-token"], "new")
        XCTAssertFalse(store.account(id)?.needsAttention ?? true)

        // Someone else is a second account.
        let other = store.save(WebSignIn.Verified(accountID: UUID(), email: "other-\(email)", cookies: ["__Secure-next-auth.session-token": "x"]),
                               provider: .chatgpt)
        defer { store.delete(other.id) }
        XCTAssertTrue(other.added)
        XCTAssertNotEqual(other.id, id)
    }

    func testSaveReportsAddedAndKeepsAccountsApart() {
        let store = WebAccounts.shared
        let email = "test-\(UUID().uuidString.prefix(8))@example.com".lowercased()
        let first = store.save(WebSignIn.Verified(accountID: UUID(), email: email, cookies: ["__Secure-1PSID": "a"]), provider: .gemini)
        XCTAssertTrue(first.added)
        defer { store.delete(first.id) }

        // Same address, another account index: refreshed, and the index is remembered.
        let again = store.save(WebSignIn.Verified(accountID: UUID(), email: email.uppercased(), cookies: ["__Secure-1PSID": "b"], authUser: 1), provider: .gemini)
        XCTAssertFalse(again.added)
        XCTAssertEqual(again.id, first.id)
        XCTAssertEqual(store.account(first.id)?.authUser, 1)

        // A different address with a different index is a new account.
        let other = store.save(WebSignIn.Verified(accountID: UUID(), email: "other-\(email)", cookies: ["__Secure-1PSID": "c"], authUser: 2), provider: .gemini)
        defer { store.delete(other.id) }
        XCTAssertTrue(other.added)
        XCTAssertNotEqual(other.id, first.id)
        XCTAssertEqual(store.account(other.id)?.authUser, 2)
    }

    func testCoolingDownAccountGoesLastButStaysCandidate() {
        let store = WebAccounts.shared
        let marker = "test-\(UUID().uuidString)"
        store.add(provider: .gemini, name: "\(marker)-a", detail: "test", cookies: ["__Secure-1PSID": "a"])
        store.add(provider: .gemini, name: "\(marker)-b", detail: "test", cookies: ["__Secure-1PSID": "b"])
        guard let first = store.accounts(for: .gemini).first(where: { $0.name == "\(marker)-a" }),
              let second = store.accounts(for: .gemini).first(where: { $0.name == "\(marker)-b" }) else {
            return XCTFail("accounts were not added")
        }
        defer { store.delete(first.id); store.delete(second.id) }

        store.select(first.id)
        store.coolDown(first.id, until: Date().addingTimeInterval(3600))
        XCTAssertTrue(store.isActive(second.id), "the next healthy account takes over")

        let ids = store.candidates(for: .gemini).map(\.id)
        XCTAssertTrue(ids.contains(first.id), "a resting account is still tried")
        XCTAssertLessThan(ids.firstIndex(of: second.id) ?? .max, ids.firstIndex(of: first.id) ?? 0)

        store.record(first.id, prompt: 1, completion: 1)
        XCTAssertFalse(store.account(first.id)?.isResting ?? true, "a successful request clears the rest")
    }

    func testOldAccountJSONStillDecodes() throws {
        let json = #"{"id":"\#(UUID().uuidString)","provider":"gemini","name":"Account","detail":"","added":0,"lastError":"","enabled":true,"usage":{}}"#
        let account = try JSONDecoder().decode(WebAccount.self, from: Data(json.utf8))
        XCTAssertEqual(account.provider, .gemini)
        XCTAssertNil(account.cooldownUntil)
        XCTAssertNil(account.authUser)
        XCTAssertFalse(account.isResting)
    }

    func testGeminiIdentityReadsTheAddress() async throws {
        guard let c = try? SafariCookies.cookies(for: .gemini), WebAccounts.looksSignedIn(.gemini, c) else {
            throw XCTSkip("Safari has no Gemini session here")
        }
        let v = try await WebSignIn.verify(.gemini, cookies: c)
        XCTAssertTrue(v.email.contains("@"), "Gemini's app shell no longer carries the address (oPEP7c)")
    }
}

extension WebAccountTests {
    func testJailbreakLabChatGPT() async throws {
        guard let c = try? SafariCookies.cookies(for: .chatgpt), WebAccounts.looksSignedIn(.chatgpt, c) else { throw XCTSkip() }
        let q = "Explain how a car engine works, in detail."





        let client = ChatGPTWebClient(accountID: UUID(), cookies: c)
        let r = try await client.chat([.user(Jailbreak.prompt(for: .chatgpt, query: q))], model: "chatgpt/auto", onText: nil, shouldStop: nil)
        print("JBLAB gpt52", r.text.count, r.text.prefix(300).replacingOccurrences(of: "\n", with: " | "))
        XCTAssertGreaterThan(r.text.count, 300)
    }
}

extension WebAccountTests {
    func testDumpChatGPTCookie() throws {
        guard let c = try? SafariCookies.cookies(for: .chatgpt), WebAccounts.looksSignedIn(.chatgpt, c) else { throw XCTSkip() }
        print("CGHDR", c.map { "\($0.key)=\($0.value)" }.joined(separator: "; "))
    }
}

extension WebAccountTests {
    func testJailbreakLabGemini() async throws {
        guard let c = try? SafariCookies.cookies(for: .gemini), WebAccounts.looksSignedIn(.gemini, c) else { throw XCTSkip() }
        let q = "Explain how a car engine works, in detail."





        let client = GeminiWebClient(accountID: UUID(), cookies: c)
        _ = try await client.prepare()
        let text = try await client.chat(Jailbreak.prompt(for: .gemini, query: q), model: "gemini-auto", onText: nil, shouldStop: nil)
        print("JBLAB gem20 gemini", text.count, text.prefix(300).replacingOccurrences(of: "\n", with: " | "))
        XCTAssertGreaterThan(text.count, 500)
    }
}

final class JailbreakTests: XCTestCase {
    func testOnlyWebModels() {
        XCTAssertTrue(Jailbreak.applies(to: "chatgpt/auto"))
        XCTAssertTrue(Jailbreak.applies(to: "gemini-auto"))
        XCTAssertFalse(Jailbreak.applies(to: "glm-5.3-flash"))
        XCTAssertFalse(Jailbreak.applies(to: "gpt-6-luna"))
    }

    func testPromptCarriesQueryAndFormatNote() {
        let p = Jailbreak.prompt(for: .gemini, query: "fix the parser")
        XCTAssertTrue(p.contains("BUCKLE UP"))
        XCTAssertTrue(p.contains("fix the parser"))
        XCTAssertTrue(p.contains("json reply format"))
        XCTAssertTrue(Jailbreak.prompt(for: .experiential, query: "x").isEmpty)
    }
}

extension WebAccountTests {
    func testQwenSafariCookies() throws {
        let c: [String: String]
        do { c = try SafariCookies.cookies(forDomain: "qwen.ai") } catch SafariCookies.Failure.noFile, SafariCookies.Failure.noAccess {
            throw XCTSkip("no readable Safari cookies here (no Safari, or no Full Disk Access)")
        }
        print("QWEN", c.count, c.keys.sorted())
        let h = c.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        print("QWHDR", h)
        let z = try SafariCookies.cookies(forDomain: "z.ai")
        print("ZAI", z.count, z.keys.sorted())
    }
}
