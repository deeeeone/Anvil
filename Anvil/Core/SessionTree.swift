import Foundation

/// Lays the session list out as a tree: sub-sessions sit under the session that started them.
nonisolated enum SessionTree {
    struct Row: Identifiable, Equatable, Sendable {
        var summary: SessionSummary
        var depth: Int
        /// How many sub-sessions hang under this row (shown even while collapsed).
        var childCount: Int
        var id: UUID { summary.id }
    }

    /// `list` keeps its order (newest first); a child whose parent isn't in the list is shown at the top level.
    static func rows(_ list: [SessionSummary], collapsed: Set<UUID> = []) -> [Row] {
        let ids = Set(list.map(\.id))
        var children: [UUID: [SessionSummary]] = [:]
        var top: [SessionSummary] = []
        for s in list {
            if let p = s.parentID, p != s.id, ids.contains(p) { children[p, default: []].append(s) } else { top.append(s) }
        }
        var out: [Row] = []
        var seen = Set<UUID>()
        /// Under a collapsed row: not shown, and not mistaken for an orphan below.
        func hide(_ s: SessionSummary) {
            guard seen.insert(s.id).inserted else { return }
            (children[s.id] ?? []).forEach(hide)
        }
        func add(_ s: SessionSummary, depth: Int) {
            guard seen.insert(s.id).inserted else { return }
            let kids = children[s.id] ?? []
            out.append(Row(summary: s, depth: depth, childCount: kids.count))
            if collapsed.contains(s.id) { kids.forEach(hide) } else { kids.forEach { add($0, depth: depth + 1) } }
        }
        top.forEach { add($0, depth: 0) }
        list.forEach { add($0, depth: 0) }   // anything only reachable through a parent cycle
        return out
    }
}
