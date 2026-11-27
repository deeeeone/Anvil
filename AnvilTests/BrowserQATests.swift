import XCTest
@testable import Anvil

final class BrowserQATests: XCTestCase {
    func testSupersededNavigationIsNotAFailure() {
        XCTAssertTrue(BrowserQA.isSupersededNavigation(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)))
        XCTAssertTrue(BrowserQA.isSupersededNavigation(NSError(domain: "WebKitErrorDomain", code: 102)))
        XCTAssertFalse(BrowserQA.isSupersededNavigation(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)))
        XCTAssertFalse(BrowserQA.isSupersededNavigation(NSError(domain: "WebKitErrorDomain", code: 101)))
    }

    func testNotFoundHeuristic() {
        XCTAssertTrue(BrowserQA.looksLikeNotFound(title: "404", text: ""))
        XCTAssertTrue(BrowserQA.looksLikeNotFound(title: "Next.js", text: "This page could not be found."))
        XCTAssertFalse(BrowserQA.looksLikeNotFound(title: "App", text: "Diff not found"), "an app message is not a 404 page")
        XCTAssertTrue(BrowserQA.looksLikeNotFound(title: "App", text: "404 | Page not found"))
        XCTAssertFalse(BrowserQA.looksLikeNotFound(title: "JSON Diff", text: "Paste two documents to compare them"))
    }

    func testDescribeLoadedReportsRedirectsAnd404() {
        XCTAssertEqual(BrowserQA.describeLoaded(requested: "http://localhost:3001/diff", final: "http://localhost:3001/diff",
                                                title: "JSON Diff", notFound: false),
                       "loaded http://localhost:3001/diff (\"JSON Diff\")")
        // A trailing slash on the root is not a redirect.
        XCTAssertFalse(BrowserQA.describeLoaded(requested: "http://localhost:3001", final: "http://localhost:3001/",
                                                title: "Home", notFound: false).contains("redirected"))
        let moved = BrowserQA.describeLoaded(requested: "http://localhost:3001/diff", final: "http://localhost:3001/",
                                             title: "Home", notFound: false)
        XCTAssertTrue(moved.contains("redirected to http://localhost:3001/ from http://localhost:3001/diff"), moved)
        let missing = BrowserQA.describeLoaded(requested: "http://localhost:3001/diff", final: "http://localhost:3001/diff",
                                               title: "Not found", notFound: true)
        XCTAssertTrue(missing.hasSuffix("looks like a 404 page"), missing)
    }

    func testParseColorReadsRgbAndRgba() {
        XCTAssertEqual(BrowserQA.parseColor("rgb(119, 119, 119)"), BrowserQA.RGBA(r: 119, g: 119, b: 119, a: 1))
        XCTAssertEqual(BrowserQA.parseColor("rgba(0, 0, 0, 0.5)"), BrowserQA.RGBA(r: 0, g: 0, b: 0, a: 0.5))
        XCTAssertEqual(BrowserQA.parseColor("rgb(10 20 30 / 50%)")?.a, 0.5)
        XCTAssertNil(BrowserQA.parseColor("transparent-ish"))
    }

    func testContrastRatios() {
        let black = BrowserQA.RGBA(r: 0, g: 0, b: 0, a: 1), white = BrowserQA.RGBA(r: 255, g: 255, b: 255, a: 1)
        XCTAssertEqual(BrowserQA.contrastRatio(black, white), 21, accuracy: 0.001)
        XCTAssertEqual(BrowserQA.contrastRatio(white, white), 1, accuracy: 0.001)
        let grey = BrowserQA.parseColor("rgb(119, 119, 119)")!
        XCTAssertEqual(BrowserQA.contrastRatio(grey, white), 4.48, accuracy: 0.01)
        let low = BrowserQA.textContrast(fg: "rgb(119, 119, 119)", bg: nil, fontSize: 14, weight: 400)
        XCTAssertEqual(low?.required, 4.5)
        XCTAssertLessThan(low?.ratio ?? 0, 4.5, "#777 on white fails AA for body text")
        // Translucent text is blended over the background before measuring.
        let faded = BrowserQA.textContrast(fg: "rgba(0, 0, 0, 0.1)", bg: "rgb(255, 255, 255)", fontSize: 16, weight: 400)
        XCTAssertLessThan(faded?.ratio ?? 21, 1.5)
    }

    func testRequiredContrastThresholds() {
        XCTAssertEqual(BrowserQA.requiredContrast(fontSize: 24, weight: 400), 3.0, "24px is large text")
        XCTAssertEqual(BrowserQA.requiredContrast(fontSize: 18.66, weight: 700), 3.0, "18.66px bold is large text")
        XCTAssertEqual(BrowserQA.requiredContrast(fontSize: 18.66, weight: 400), 4.5)
        XCTAssertEqual(BrowserQA.requiredContrast(fontSize: 16, weight: 700), 4.5)
    }

    func testAuditReportFormatsFacts() {
        let facts: [String: Any] = [
            "url": "http://localhost:3001/diff", "title": "JSON Diff", "viewportWidth": 1280, "documentWidth": 1400,
            "textTotal": 2, "samples": [
                ["fg": "rgb(119, 119, 119)", "bg": NSNull(), "fontSize": 14, "weight": 400, "font": "Inter", "text": "Faint hint"],
                ["fg": "rgb(0, 0, 0)", "bg": NSNull(), "fontSize": 16, "weight": 400, "font": "Inter", "text": "Body"],
            ],
            "overflowCount": 1, "overflowExamples": ["div.wide ends at 1400px"],
            "imagesTotal": 3, "imagesNoAlt": 1, "controlsTotal": 4, "controlsUnnamed": 1, "unnamedExamples": ["button"],
            "consoleErrors": 2,
        ]
        let report = BrowserQA.auditReport(facts)
        XCTAssertTrue(report.contains("low text contrast: 1 of 2"), report)
        XCTAssertTrue(report.contains("\"Faint hint\""), report)
        XCTAssertTrue(report.contains("horizontal overflow: 1 elements"), report)
        XCTAssertTrue(report.contains("images without alt: 1 of 3"), report)
        XCTAssertTrue(report.contains("Inter (2)"), report)
        XCTAssertTrue(report.contains("console errors: 2 (see browser_console)"), report)
        XCTAssertLessThan(report.count, 3000)
    }

    func testAllContainsTheNewTools() {
        let names = BrowserTools.all().map(\.name)
        XCTAssertTrue(names.contains("browser_styles"))
        XCTAssertTrue(names.contains("browser_audit"))
        XCTAssertTrue(BrowserTools.all().filter { $0.name == "browser_styles" || $0.name == "browser_audit" }.allSatisfy { $0.group == .web && $0.kind == .network })
    }

    func testStylesAndAuditOnARealPage() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("anvil-qa-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let page = dir.appendingPathComponent("qa.html")
        try """
        <html><head><title>QA</title></head><body style="background:#fff">
        <h1>Heading</h1>
        <p id="low" style="color:#777;font-size:14px">Faint hint</p>
        <img src="missing.png">
        <button></button>
        <div style="width:2000px">wide</div>
        </body></html>
        """.write(to: page, atomically: true, encoding: .utf8)
        let b = BrowserController()
        let status = await b.open(page.path)
        XCTAssertTrue(status.hasPrefix("loaded"), status)
        let again = await b.open(page.path)
        XCTAssertTrue(again.hasPrefix("loaded"), "opening the page already shown reloads it: \(again)")
        let ctx = ToolContext(root: dir, processes: ProcessManager(), host: nil)
        ctx.browser = b

        let styles = try await BrowserTools.styles.run!(.object(["selector": .string("#low")]), ctx)
        XCTAssertTrue(styles.ok, styles.output)
        XCTAssertTrue(styles.output.contains("color: rgb(119, 119, 119)"), styles.output)
        XCTAssertTrue(styles.output.contains("contrast: 4.48:1"), styles.output)
        XCTAssertTrue(styles.output.contains("low contrast (needs 4.5:1)"), styles.output)

        let missing = try await BrowserTools.styles.run!(.object(["selector": .string("#nope")]), ctx)
        XCTAssertFalse(missing.ok)

        let audit = try await BrowserTools.audit.run!(.object([:]), ctx)
        XCTAssertTrue(audit.ok, audit.output)
        XCTAssertTrue(audit.output.contains("low text contrast: 1 of"), audit.output)
        XCTAssertTrue(audit.output.contains("images without alt: 1 of 1"), audit.output)
        XCTAssertTrue(audit.output.contains("buttons and links without an accessible name: 1 of 1"), audit.output)
        XCTAssertTrue(audit.output.contains("overflow: 1 elements"), audit.output)
    }

    func testOpenReportsA404Page() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("anvil-404-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let page = dir.appendingPathComponent("missing.html")
        try "<html><head><title>Not Found</title></head><body><h1>This page could not be found.</h1></body></html>"
            .write(to: page, atomically: true, encoding: .utf8)
        let status = await BrowserController().open(page.path)
        XCTAssertTrue(status.hasPrefix("loaded"), status)
        XCTAssertTrue(status.contains("looks like a 404 page"), status)
    }
}
