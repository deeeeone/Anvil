import Foundation

/// What a session is doing, as the sidebar shows it. Waiting on the owner wins over running.
enum SessionActivity: Equatable {
    case running, needsYou
}

/// Sidebar organisation: pins, sections, unread, archive and nesting.
extension AppState {
    func togglePin(_ id: UUID) {
        if let i = meta.pinned.firstIndex(of: id) { meta.pinned.remove(at: i) } else { meta.pinned.append(id) }
    }

    /// Renames the session in its file. A session with a live controller is edited through it, so nothing is overwritten.
    func rename(_ id: UUID, to name: String) {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let project else { return }
        if let c = controller(for: id) {
            c.session.title = t
            c.saveNow()
        } else if var s = SessionStore.load(id, root: project) {
            s.title = t
            try? SessionStore.save(s)
        }
        refreshSessions()
    }

    func setUnread(_ id: UUID, _ unread: Bool) {
        if unread { meta.unread.insert(id) } else { meta.unread.remove(id) }
    }

    /// A request finished in a session the owner isn't looking at.
    func markFinished(_ id: UUID) {
        // A session on screen (either pane) was seen as it finished.
        guard !panes.contains(id) else { return }
        meta.unread.insert(id)
    }

    /// The owner opened the session, so it is no longer unread.
    func markSeen(_ id: UUID) {
        if meta.unread.contains(id) { meta.unread.remove(id) }
    }

    /// Archiving also unpins, so an archived session shows only under Archived.
    func archive(_ id: UUID) {
        meta.archived.insert(id)
        meta.pinned.removeAll { $0 == id }
        // An archived session leaves the split; a lone pane keeps showing it until something else is picked.
        if panes.isSplit && panes.contains(id) { closePane(id) }
    }

    func unarchive(_ id: UUID) {
        meta.archived.remove(id)
    }

    /// Makes a section and returns its id (the sidebar then renames it in place).
    @discardableResult
    func createSection(name: String) -> UUID {
        let s = MetaSection(name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New Section" : name)
        meta.sections.append(s)
        return s.id
    }

    func renameSection(_ id: UUID, to name: String) {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let i = meta.sections.firstIndex(where: { $0.id == id }) else { return }
        meta.sections[i].name = t
    }

    func toggleSection(_ id: UUID) {
        guard let i = meta.sections.firstIndex(where: { $0.id == id }) else { return }
        meta.sections[i].collapsed.toggle()
    }

    /// Deleting a section moves its sessions back to Recents; no session is lost.
    func deleteSection(_ id: UUID) {
        meta.sections.removeAll { $0.id == id }
        meta.sectionOf = meta.sectionOf.filter { $0.value != id }
    }

    /// Puts the session in a section (nil = Recents). Moving unpins it so the move is visible.
    func move(_ id: UUID, toSection section: UUID?) {
        meta.pinned.removeAll { $0 == id }
        if let section { meta.sectionOf[id] = section } else { meta.sectionOf[id] = nil }
    }

    /// Shows `id` under `parent` in the sidebar (nil = not nested). Refuses itself and loops.
    func nest(_ id: UUID, under parent: UUID?) {
        guard let parent else { meta.nestedUnder[id] = nil; return }
        guard !SessionMeta.wouldCycle(child: id, parent: parent, parents: nestingParents) else { return }
        meta.nestedUnder[id] = parent
    }

    /// Each session's parent as the sidebar shows it: its nesting, else its sub-session parent.
    var nestingParents: [UUID: UUID] {
        var parents = meta.nestedUnder
        for s in sessions where s.parentID != nil && parents[s.id] == nil { parents[s.id] = s.parentID }
        return parents
    }

    /// The sidebar's groups for the current project, filtered by `query`.
    func organizedRows(query: String = "", collapsed: Set<UUID> = []) -> SidebarLayout {
        SessionMeta.layout(sessions, data: meta.data, query: query, collapsed: collapsed)
    }
}
