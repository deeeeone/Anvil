import XCTest
@testable import Anvil

/// NotebookLM protocol helpers, exercised on fixtures only (no network).
final class NotebookLMTests: XCTestCase {
    func testEncodeBatchShape() throws {
        let params = JSON.array([.string("Hi"), .null])
        let body = NotebookLMClient.encodeBatch(rpc: "CCqFvf", params: params, at: "tok+en/1")
        XCTAssertTrue(body.hasSuffix("&"))
        let parts = String(body.dropLast()).components(separatedBy: "&at=")
        XCTAssertEqual(parts.count, 2)
        let freq = String(parts[0].dropFirst("f.req=".count)).removingPercentEncoding ?? ""
        let decoded = try XCTUnwrap(JSON.parse(freq))
        XCTAssertEqual(decoded.array?.count, 1)
        let item = try XCTUnwrap(decoded[0]?[0])
        XCTAssertEqual(item[0]?.string, "CCqFvf")
        XCTAssertEqual(item[1].flatMap { JSON.parse($0.string ?? "") }, params)
        XCTAssertEqual(item[2], JSON.null)
        XCTAssertEqual(item[3]?.string, "generic")
        XCTAssertEqual(parts[1].removingPercentEncoding, "tok+en/1")
    }

    func testParseTokens() {
        let html = #"<script>window.WIZ = {"SNlM0e":"AT-fake-token:123","FdrFJe":"-7788","cfb2h":"boq_labs-tailwind_20261101"};</script>"#
        let tokens = NotebookLMClient.parseTokens(html)
        XCTAssertEqual(tokens?.at, "AT-fake-token:123")
        XCTAssertEqual(tokens?.fsid, "-7788")
        XCTAssertEqual(tokens?.bl, "boq_labs-tailwind_20261101")
        XCTAssertNil(NotebookLMClient.parseTokens("<html><body>landing-header-signin</body></html>"))
    }

    func testParseBatchReadsTheWrbFrame() throws {
        let body = ")]}'\n\n123\n[[\"wrb.fr\",\"CCqFvf\",\"[\\\"t\\\",null,\\\"nb-1\\\"]\",null,null,null,\"generic\"]]\n"
        let result = try XCTUnwrap(NotebookLMClient.parseBatch(body, rpc: "CCqFvf"))
        XCTAssertEqual(result[2]?.string, "nb-1")
        XCTAssertNil(NotebookLMClient.parseBatch(body, rpc: "wXbhsf"))
    }

    func testParseStreamAnswerPicksLongestChunk() {
        func frame(_ inner: String) -> String {
            JSON.array([.array([.string("wrb.fr"), .string("GenerateFreeFormStreamed"), .string(inner), .null, .null, .null, .string("generic")])]).compact
        }
        let body = ")]}'\n\n" + frame("[[\"The backup runs at\"]]") + "\n"
            + frame("[[\"The backup runs at 02:00 nightly.\"]]") + "\n" + frame("[[\"The b\"]]") + "\n"
        XCTAssertEqual(NotebookLMClient.parseStreamAnswer(body), "The backup runs at 02:00 nightly.")
    }

    func testParseNotebooksAcceptsBothShapes() throws {
        let flat = try XCTUnwrap(JSON.parse(#"[["Anvil memory: Tools",[],"nb-1"],["Recipes",[],"nb-2"]]"#))
        XCTAssertEqual(NotebookLMClient.parseNotebooks(flat).map(\.id), ["nb-1", "nb-2"])
        let nested = try XCTUnwrap(JSON.parse(#"[[["Anvil memory: Tools",[],"nb-1"]]]"#))
        XCTAssertEqual(NotebookLMClient.parseNotebooks(nested).map(\.id), ["nb-1"])
    }

    func testParseSourcesWalksNestedShapes() throws {
        let result = try XCTUnwrap(JSON.parse(#"[[[["3F2504E0-4F89-11D3-9A0C-0305E82C3301"],"Design doc",[1]]],[[[1732000000,0],"not a source"]],[[["9B1DEB4D-3B7D-4BAD-9BDD-2B0D7B3DCB6D"],"Standup"]]]"#))
        let sources = NotebookLMClient.parseSources(result)
        XCTAssertEqual(sources.map(\.id), ["3F2504E0-4F89-11D3-9A0C-0305E82C3301", "9B1DEB4D-3B7D-4BAD-9BDD-2B0D7B3DCB6D"])
        XCTAssertEqual(sources.map(\.title), ["Design doc", "Standup"])
    }

    func testSourceEvictionKeepsNotebookUnderLimit() {
        XCTAssertEqual(NotebookLMClient.sourcesToEvict(count: 44, recorded: ["a"]), [])
        XCTAssertEqual(NotebookLMClient.sourcesToEvict(count: 45, recorded: ["a", "b"]), ["a"])
        XCTAssertEqual(NotebookLMClient.sourcesToEvict(count: 47, recorded: ["a", "b", "c"]), ["a", "b", "c"])
        XCTAssertEqual(NotebookLMClient.sourcesToEvict(count: 50, recorded: []), [])
    }

    func testRedactorRemovesSecrets() {
        let secrets = [
            "sk-proj-abcdefghijklmnopqrstuvwxyz012345",
            "sk-ant-api03-abcdefghijklmnop0123456789",
            "AIzaSyD-abcdefghijklmnopqrstuvwxyz12345",
            "ghp_abcdefghijklmnopqrstuvwxyz0123456789",
            "github_pat_11ABCDEFG0123456789_abcdefghijklmnop",
            "xoxb-1234567890-abcdefghij",
            "AKIAIOSFODNN7EXAMPLE",
            "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
        ]
        for secret in secrets {
            let out = Redactor.redact("key was \(secret) in the log")
            XCTAssertFalse(out.contains(secret), secret)
            XCTAssertTrue(out.contains("[redacted]"), secret)
        }
        XCTAssertEqual(Redactor.redact("Authorization: Bearer abcdef123456TOKEN"), "Authorization: [redacted]")
        XCTAssertEqual(Redactor.redact("Cookie: SID=abc123; HSID=xyz"), "Cookie: [redacted]")
        XCTAssertEqual(Redactor.redact("Set-Cookie: session=abc123"), "Set-Cookie: [redacted]")
        XCTAssertEqual(Redactor.redact("export api_key=hunter2supersecret"), "export api_key=[redacted]")
        XCTAssertEqual(Redactor.redact(#"{"password": "hunter2"}"#), #"{"password": "[redacted]"}"#)
    }

    func testSetOSIDFormReadsActionAndFields() throws {
        let html = #"<html><body><form method="post" action="https://notebooklm.google.com/accounts/SetOSID?hl=en&amp;authuser=0"><input type="hidden" name="authuser" value="0"><input type="hidden" name="continue" value="https://notebook.google.com/?a=1&amp;b=2"><input type="hidden" name="nojssubmit" value="1"><input type="hidden" name="osidt" value="tok&quot;x"><input type="submit"></form></body></html>"#
        let form = try XCTUnwrap(NotebookLMClient.setOSIDForm(html))
        XCTAssertEqual(form.action.absoluteString, "https://notebooklm.google.com/accounts/SetOSID?hl=en&authuser=0")
        XCTAssertEqual(form.fields["authuser"], "0")
        XCTAssertEqual(form.fields["continue"], "https://notebook.google.com/?a=1&b=2")
        XCTAssertEqual(form.fields["nojssubmit"], "1")
        XCTAssertEqual(form.fields["osidt"], "tok\"x")
        XCTAssertNil(NotebookLMClient.setOSIDForm("<form action=\"https://accounts.google.com/ServiceLogin\"></form>"))
    }

    func testParseSetCookiesSplitsJoinedHeaders() {
        let cookies = NotebookLMClient.parseSetCookies("SID=abc; Path=/; Expires=Wed, 21 Oct 2026 07:28:00 GMT, OSID=xyz; Path=/")
        XCTAssertEqual(cookies.map { $0.name }, ["SID", "OSID"])
        XCTAssertEqual(cookies.map { $0.value }, ["abc", "xyz"])
    }

    func testPlanLimits() {
        XCTAssertEqual(NotebookPlan.named("free").chats, 50)
        XCTAssertEqual(NotebookPlan.named("free").askCap, 40)
        XCTAssertEqual(NotebookPlan.named("free").evictAt, 45)
        XCTAssertEqual(NotebookPlan.named("plus").sources, 100)
        XCTAssertEqual(NotebookPlan.named("plus").askCap, 160)
        XCTAssertEqual(NotebookPlan.named("pro").evictAt, 295)
        XCTAssertEqual(NotebookPlan.named("ultra").askCap, 2000)
        XCTAssertEqual(NotebookPlan.named("nonsense"), .free)
    }

    func testDailyBudgetCounter() {
        let full = DailyCount(day: "2026-11-25", count: 40)
        XCTAssertEqual(MemoryRules.budgetLeft(full, today: "2026-11-25", limit: 40), 0)
        XCTAssertEqual(MemoryRules.budgetLeft(full, today: "2026-11-26", limit: 40), 40)
        XCTAssertEqual(MemoryRules.budgetLeft(DailyCount(day: "2026-11-25", count: 3), today: "2026-11-25", limit: 40), 37)
        XCTAssertEqual(MemoryRules.spend(full, today: "2026-11-25"), DailyCount(day: "2026-11-25", count: 41))
        XCTAssertEqual(MemoryRules.spend(full, today: "2026-11-26"), DailyCount(day: "2026-11-26", count: 1))
    }

    func testUploadDecision() {
        XCTAssertFalse(MemoryRules.shouldUpload(tokens: 59_999, freshChars: 40_000))
        XCTAssertFalse(MemoryRules.shouldUpload(tokens: 60_000, freshChars: 39_999))
        XCTAssertTrue(MemoryRules.shouldUpload(tokens: 60_000, freshChars: 40_000))
    }

    func testToolOfferDecision() {
        XCTAssertTrue(MemoryRules.offerTool(attached: true, uploaded: false, tokens: 0, notebookHasUploads: false, memoryOn: false))
        XCTAssertFalse(MemoryRules.offerTool(attached: false, uploaded: false, tokens: 500, notebookHasUploads: false, memoryOn: true))
        XCTAssertTrue(MemoryRules.offerTool(attached: false, uploaded: true, tokens: 500, notebookHasUploads: false, memoryOn: true))
        XCTAssertFalse(MemoryRules.offerTool(attached: false, uploaded: true, tokens: 500, notebookHasUploads: false, memoryOn: false))
        XCTAssertTrue(MemoryRules.offerTool(attached: false, uploaded: false, tokens: 60_000, notebookHasUploads: true, memoryOn: true))
        XCTAssertFalse(MemoryRules.offerTool(attached: false, uploaded: false, tokens: 60_000, notebookHasUploads: false, memoryOn: true))
    }

    func testRedactorLeavesOrdinaryTextAlone() {
        let normal = "Ran the build and tests; all 42 passed. The task-management-system-overview is in docs. Let total = 3 and count=7 keep going."
        XCTAssertEqual(Redactor.redact(normal), normal)
    }
}
