import Foundation
import Observation

/// A user-made group in the sidebar.
nonisolated struct MetaSection: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var collapsed = false
}

/// The on-disk shape of a project's organisation (pins, sections, archive, nesting).
nonisolated struct SessionMetaData: Codable, Equatable, Sendable {
    var pinned: [UUID] = []
    var archived: Set<UUID> = []
    var unread: Set<UUID> = []
    var sections: [MetaSection] = []
    var sectionOf: [UUID: UUID] = [:]
    var nestedUnder: [UUID: UUID] = [:]
}

/// The sidebar's groups, already ordered and nested.
nonisolated struct SidebarLayout: Equatable, Sendable {
    struct Section: Equatable, Identifiable, Sendable {
        var section: MetaSection
        var rows: [SessionTree.Row]
        var id: UUID { section.id }
    }
    var pinned: [SessionTree.Row] = []
    var sections: [Section] = []
    var recents: [SessionTree.Row] = []
    var archived: [SessionTree.Row] = []
}

/// Per-project organisation of sessions, kept in `meta.json` beside the session files.
@Observable
final class SessionMeta {
    var pinned: [UUID] = [] { didSet { save() } }
    var archived: Set<UUID> = [] { didSet { save() } }
    var unread: Set<UUID> = [] { didSet { save() } }
    var sections: [MetaSection] = [] { didSet { save() } }
    var sectionOf: [UUID: UUID] = [:] { didSet { save() } }
    var nestedUnder: [UUID: UUID] = [:] { didSet { save() } }
    /// Nil for meta that is not stored anywhere (tests, or before a project opens).
    @ObservationIgnored private(set) var file: URL?

    init(file: URL? = nil, data: SessionMetaData = SessionMetaData()) {
        self.file = file
        pinned = data.pinned
        archived = data.archived
        unread = data.unread
        sections = data.sections
        sectionOf = data.sectionOf
        nestedUnder = data.nestedUnder
    }

    var data: SessionMetaData {
        SessionMetaData(pinned: pinned, archived: archived, unread: unread, sections: sections, sectionOf: sectionOf, nestedUnder: nestedUnder)
    }

    /// `meta.json` in the project's folder (next to its `sessions` folder).
    static func file(for root: URL) -> URL {
        SessionStore.folder(for: root).deletingLastPathComponent().appendingPathComponent("meta.json")
    }

    /// Reads the project's organisation; a missing or unreadable file gives empty meta.
    static func load(root: URL) -> SessionMeta { load(file: file(for: root)) }

    static func load(file: URL) -> SessionMeta {
        var decoded = SessionMetaData()
        if let d = try? Data(contentsOf: file), let v = try? JSONDecoder().decode(SessionMetaData.self, from: d) { decoded = v }
        return SessionMeta(file: file, data: decoded)
    }

    /// Writes the current state (a no-op for meta with no file).
    func save() {
        guard let file else { return }
        guard let data = try? JSONEncoder().encode(data) else { return }
        try? data.write(to: file, options: .atomic)
    }

    /// Drops ids of sessions that no longer exist, so the file doesn't keep growing with dead links.
    func prune(keeping ids: Set<UUID>) {
        let p = pinned.filter { ids.contains($0) }
        if p != pinned { pinned = p }
        let a = archived.intersection(ids)
        if a != archived { archived = a }
        let u = unread.intersection(ids)
        if u != unread { unread = u }
        let so = sectionOf.filter { ids.contains($0.key) }
        if so != sectionOf { sectionOf = so }
        let nu = nestedUnder.filter { ids.contains($0.key) && ids.contains($0.value) }
        if nu != nestedUnder { nestedUnder = nu }
    }

    /// True when making `parent` the parent of `child` would close a loop (or a session would be its own parent).
    /// `parents` maps each session to its current parent.
    static func wouldCycle(child: UUID, parent: UUID, parents: [UUID: UUID]) -> Bool {
        if parent == child { return true }
        var cur: UUID? = parent
        var steps = 0
        while let c = cur, steps <= parents.count {
            if c == child { return true }
            cur = parents[c]
            steps += 1
        }
        return false
    }

    /// Groups the sessions for the sidebar. Pinned and archived sessions appear only in their own group;
    /// sections hold unpinned sessions; everything else is Recents. `query` filters by title (case-insensitive).
    static func layout(_ list: [SessionSummary], data: SessionMetaData, query: String = "", collapsed: Set<UUID> = []) -> SidebarLayout {
        let q = query.trimmingCharacters(in: .whitespaces)
        let shown = q.isEmpty ? list : list.filter { $0.title.localizedCaseInsensitiveContains(q) }
        let live = Set(data.sections.map(\.id))
        let byID = Dictionary(shown.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let pinnedSet = Set(data.pinned)

        var out = SidebarLayout()
        let pinnedList = data.pinned.compactMap { byID[$0] }.filter { !data.archived.contains($0.id) }
        out.pinned = SessionTree.rows(pinnedList, collapsed: collapsed, nestedUnder: data.nestedUnder)

        var sectioned: [UUID: [SessionSummary]] = [:]
        var recents: [SessionSummary] = []
        var archived: [SessionSummary] = []
        for s in shown {
            if data.archived.contains(s.id) { archived.append(s); continue }
            if pinnedSet.contains(s.id) { continue }
            if let sec = data.sectionOf[s.id], live.contains(sec) { sectioned[sec, default: []].append(s) } else { recents.append(s) }
        }
        out.sections = data.sections.map { sec in
            SidebarLayout.Section(section: sec, rows: SessionTree.rows(sectioned[sec.id] ?? [], collapsed: collapsed, nestedUnder: data.nestedUnder))
        }
        out.recents = SessionTree.rows(recents, collapsed: collapsed, nestedUnder: data.nestedUnder)
        out.archived = SessionTree.rows(archived, collapsed: collapsed, nestedUnder: data.nestedUnder)
        return out
    }
}
