import XCTest
#if SWIFT_PACKAGE
@testable import AnvilCore
#else
@testable import Anvil
#endif

final class EditEngineTests: XCTestCase {
    func testUniqueReplace() throws {
        let r = try EditEngine.apply("a\nb\nc\n", .init(find: "b", replace: "B"), file: "f")
        XCTAssertEqual(r.text, "a\nB\nc\n")
        XCTAssertEqual(r.count, 1)
    }

    func testAmbiguousFails() {
        XCTAssertThrowsError(try EditEngine.apply("x = 1\nx = 1\n", .init(find: "x = 1", replace: "x = 2"), file: "f")) { e in
            let m = (e as! ToolFailure).message
            XCTAssertTrue(m.contains("matches 2 places"), m)
            XCTAssertTrue(m.contains("lines 1, 2"), m)
        }
    }

    func testAllReplacesEveryMatch() throws {
        let r = try EditEngine.apply("x x x", .init(find: "x", replace: "y", all: true), file: "f")
        XCTAssertEqual(r.text, "y y y")
        XCTAssertEqual(r.count, 3)
    }

    func testNotFoundGivesHint() {
        XCTAssertThrowsError(try EditEngine.apply("func hello() {\n    return 1\n}\n", .init(find: "func hello() {\n  return 1", replace: "z"), file: "f")) { e in
            let m = (e as! ToolFailure).message
            XCTAssertTrue(m.contains("near line 1"), m)
        }
    }

    func testStripsLineNumberPrefixes() throws {
        let r = try EditEngine.apply("let a = 1\nlet b = 2\n", .init(find: "1\tlet a = 1\n2\tlet b = 2", replace: "1\tlet a = 10\n2\tlet b = 2"), file: "f")
        XCTAssertEqual(r.text, "let a = 10\nlet b = 2\n")
    }

    func testCRLFFiles() throws {
        let r = try EditEngine.apply("a\r\nb\r\n", .init(find: "a\nb", replace: "a\nc"), file: "f")
        XCTAssertEqual(r.text, "a\r\nc\r\n")
    }

    func testApplyAllIsAtomic() {
        XCTAssertThrowsError(try EditEngine.applyAll("one two", [.init(find: "one", replace: "1"), .init(find: "missing", replace: "x")], file: "f")) { e in
            XCTAssertTrue((e as! ToolFailure).message.contains("edit 2 of 2"))
        }
    }

    func testIdenticalFindReplaceFails() {
        XCTAssertThrowsError(try EditEngine.apply("a", .init(find: "a", replace: "a"), file: "f"))
    }
}

final class DiffTests: XCTestCase {
    func testScriptMarksChanges() {
        let s = DiffEngine.script(old: "a\nb\nc\n", new: "a\nB\nc\nd\n")
        XCTAssertEqual(s.map(\.kind), [.context, .remove, .add, .context, .add])
        XCTAssertEqual(s[2].newNo, 2)
        XCTAssertEqual(s[1].oldNo, 2)
    }

    func testUnifiedHunkHeaderAndContext() {
        let old = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let new = old.replacingOccurrences(of: "line 10\n", with: "line ten\n")
        let u = DiffEngine.unified(old: old, new: new, path: "f.txt")
        XCTAssertTrue(u.hasPrefix("--- a/f.txt\n+++ b/f.txt\n@@ -7,7 +7,7 @@\n"), u)
        XCTAssertTrue(u.contains("-line 10\n+line ten\n"))
        XCTAssertFalse(u.contains("line 3\n"), "only 3 lines of context")
    }

    func testSeparateHunks() {
        let old = (1...30).map { "l\($0)" }.joined(separator: "\n")
        var lines = old.components(separatedBy: "\n")
        lines[1] = "X"; lines[27] = "Y"
        XCTAssertEqual(DiffEngine.hunks(old: old, new: lines.joined(separator: "\n")).count, 2)
    }

    func testNewFileAndStats() {
        let c = FileChange(url: URL(fileURLWithPath: "/tmp/p/new.txt"), old: nil, new: "a\nb\n")
        let d = c.diff(root: URL(fileURLWithPath: "/tmp/p"))
        XCTAssertEqual(d.path, "new.txt")
        XCTAssertTrue(d.isNew)
        XCTAssertEqual(d.added, 2)
        XCTAssertTrue(d.unified.contains("@@ -0,0 +1,2 @@"), d.unified)
    }

    func testParseUnifiedRoundTrip() {
        let u = DiffEngine.unified(old: "a\nb\n", new: "a\nc\n", path: "x")
        let lines = DiffEngine.parseUnified(u)
        XCTAssertEqual(lines.filter { $0.kind == .add }.map(\.text), ["c"])
        XCTAssertEqual(lines.filter { $0.kind == .remove }.map(\.text), ["b"])
        XCTAssertEqual(lines.first { $0.kind == .add }?.newNo, 2)
    }

    func testNoChangesNoHunks() {
        XCTAssertEqual(DiffEngine.unified(old: "same\n", new: "same\n", path: "x"), "")
    }
}
