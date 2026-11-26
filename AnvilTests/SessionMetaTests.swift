import XCTest
@testable import Anvil

final class SessionMetaTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("SessionMetaTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func summary(_ id: UUID, _ title: String, parent: UUID? = nil) -> SessionSummary {
        SessionSummary(id: id, title: title, updated: Date(), cost: 0, parentID: parent)
    }

    func testMetaRoundTripsThroughJSON() {
        let file = dir.appendingPathComponent("meta.json")
        let a = UUID(), b = UUID(), sec = MetaSection(name: "Work", collapsed: true)
        let m = SessionMeta(file: file)
        m.pinned = [b, a]
        m.archived = [a]
        m.unread = [b]
        m.sections = [sec]
        m.sectionOf = [b: sec.id]
        m.nestedUnder = [a: b]
        m.save()

        let back = SessionMeta.load(file: file)
        XCTAssertEqual(back.data, m.data)
        XCTAssertEqual(back.sections.first?.name, "Work")
        XCTAssertEqual(back.sections.first?.collapsed, true)
        XCTAssertEqual(back.pinned, [b, a], "pin order is kept")
    }

    func testMissingFileLoadsEmpty() {
        let meta = SessionMeta.load(file: dir.appendingPathComponent("absent.json"))
        XCTAssertEqual(meta.data, SessionMetaData())
    }

    func testChangesSaveAutomatically() {
        let file = dir.appendingPathComponent("auto.json")
        let m = SessionMeta(file: file)
        let id = UUID()
        m.pinned = [id]
        XCTAssertEqual(SessionMeta.load(file: file).pinned, [id])
    }

    func testPruneDropsDeletedSessions() {
        let keep = UUID(), gone = UUID(), sec = UUID()
        let m = SessionMeta(data: SessionMetaData(pinned: [gone, keep], archived: [gone], unread: [gone, keep],
                                                  sections: [], sectionOf: [gone: sec, keep: sec],
                                                  nestedUnder: [keep: gone, gone: keep]))
        m.prune(keeping: [keep])
        XCTAssertEqual(m.pinned, [keep])
        XCTAssertEqual(m.archived, [])
        XCTAssertEqual(m.unread, [keep])
        XCTAssertEqual(m.sectionOf, [keep: sec])
        XCTAssertEqual(m.nestedUnder, [:], "a link to a deleted session is dropped")
    }

    func testWouldCycle() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let parents = [b: a, c: b]   // c under b under a
        XCTAssertTrue(SessionMeta.wouldCycle(child: a, parent: a, parents: parents), "a session can't be its own parent")
        XCTAssertTrue(SessionMeta.wouldCycle(child: a, parent: c, parents: parents), "a parent may not sit under its own child")
        XCTAssertTrue(SessionMeta.wouldCycle(child: a, parent: b, parents: parents))
        XCTAssertFalse(SessionMeta.wouldCycle(child: c, parent: a, parents: parents))
        XCTAssertFalse(SessionMeta.wouldCycle(child: d, parent: c, parents: parents))
    }

    func testLayoutGroupsPinnedSectionsRecentsAndArchived() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID(), sec = MetaSection(name: "Work")
        let list = [summary(a, "pinned one"), summary(b, "in work"), summary(c, "old"), summary(d, "parent"), summary(e, "child")]
        let data = SessionMetaData(pinned: [a], archived: [c], sections: [sec], sectionOf: [b: sec.id], nestedUnder: [e: d])
        let layout = SessionMeta.layout(list, data: data)

        XCTAssertEqual(layout.pinned.map(\.id), [a])
        XCTAssertEqual(layout.sections.count, 1)
        XCTAssertEqual(layout.sections[0].rows.map(\.id), [b])
        XCTAssertEqual(layout.recents.map(\.id), [d, e], "nested session follows its parent")
        XCTAssertEqual(layout.recents.first?.childCount, 1)
        XCTAssertEqual(layout.recents.last?.depth, 1)
        XCTAssertEqual(layout.archived.map(\.id), [c])
    }

    func testArchivedAndPinnedSessionsAppearOnlyOnce() {
        let a = UUID(), b = UUID()
        let list = [summary(a, "a"), summary(b, "b")]
        let layout = SessionMeta.layout(list, data: SessionMetaData(pinned: [a], archived: [a, b]))
        let shown = layout.pinned.map(\.id) + layout.recents.map(\.id) + layout.archived.map(\.id) + layout.sections.flatMap { $0.rows.map(\.id) }
        XCTAssertEqual(shown.count, 2, "each session is shown exactly once")
        XCTAssertEqual(Set(shown), [a, b])
        XCTAssertEqual(layout.pinned.map(\.id), [], "an archived session is not shown under Pinned")
        XCTAssertEqual(layout.archived.map(\.id), [a, b])
    }

    func testSearchFiltersByTitle() {
        let a = UUID(), b = UUID()
        let list = [summary(a, "Fix the Login bug"), summary(b, "Refactor cache")]
        let layout = SessionMeta.layout(list, data: SessionMetaData(), query: "login")
        XCTAssertEqual(layout.recents.map(\.id), [a])
    }

    func testSectionFallsBackToRecentsWhenSectionIsGone() {
        let a = UUID()
        let layout = SessionMeta.layout([summary(a, "a")], data: SessionMetaData(sectionOf: [a: UUID()]))
        XCTAssertEqual(layout.recents.map(\.id), [a])
        XCTAssertTrue(layout.sections.isEmpty)
    }
}
