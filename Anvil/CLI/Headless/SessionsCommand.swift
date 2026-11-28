import Foundation

/// Finds a session by full id or unique prefix, within one project.
enum SessionLookup {
    static func find(_ text: String, root: URL) -> UUID? {
        let p = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return nil }
        let ids = SessionStore.list(root: root).map(\.id)
        if let exact = ids.first(where: { $0.uuidString.lowercased() == p }) { return exact }
        let matches = ids.filter { $0.uuidString.lowercased().hasPrefix(p) }
        return matches.count == 1 ? matches[0] : nil
    }
}

/// `anvil sessions`: this project's sessions, newest first (or every project with --all).
enum SessionsCommand {
    struct Row {
        let id: UUID
        let title: String
        let updated: Date
        let model: String
        let project: String
    }

    /// Only the fields the list shows, so a long history is read quickly.
    private struct Head: Decodable {
        let id: UUID
        let title: String
        let updated: Date
        let model: String?
        let projectPath: String
    }

    static func run(_ options: CLIOptions) -> Int32 {
        let root = HeadlessRun.projectRoot(options.project)
        let rows = options.all ? allRows() : rows(in: root)
        guard !rows.isEmpty else {
            print(options.all ? "No sessions yet." : "No sessions in \(root.path) yet. Start one with anvil -p \"...\".")
            return ExitCode.done
        }
        let now = Date()
        print("ID        UPDATED        MODEL                        TITLE")
        for r in rows {
            let id = String(r.id.uuidString.lowercased().prefix(8))
            let when = Self.relative(r.updated, now: now)
            print(id.padding(toLength: 10, withPad: " ", startingAt: 0)
                  + when.padding(toLength: 15, withPad: " ", startingAt: 0)
                  + r.model.padding(toLength: 29, withPad: " ", startingAt: 0)
                  + r.title)
            if options.all { print("          " + r.project) }
        }
        print("\nContinue one with: anvil -p \"...\" --resume ID   (a prefix of the id is enough)")
        return ExitCode.done
    }

    static func rows(in root: URL) -> [Row] {
        decodeAll(in: SessionStore.folder(for: root))
    }

    static func allRows() -> [Row] {
        let projects = (try? FileManager.default.contentsOfDirectory(at: Paths.sub("projects"), includingPropertiesForKeys: nil)) ?? []
        return projects.flatMap { decodeAll(in: $0.appendingPathComponent("sessions")) }.sorted { $0.updated > $1.updated }
    }

    private static func decodeAll(in folder: URL) -> [Row] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return files.filter { $0.pathExtension == "json" }.compactMap { f -> Row? in
            guard let data = try? Data(contentsOf: f), let h = try? dec.decode(Head.self, from: data) else { return nil }
            return Row(id: h.id, title: h.title, updated: h.updated, model: h.model ?? AppSettings.shared.model, project: h.projectPath)
        }.sorted { $0.updated > $1.updated }
    }

    /// "just now", "5m ago", "3h ago", "2d ago", "3w ago", else the date. RelativeDateTimeFormatter is Apple-only.
    static func relative(_ date: Date, now: Date) -> String {
        let s = Int(now.timeIntervalSince(date))
        switch s {
        case ..<60: return "just now"
        case ..<3600: return "\(s / 60)m ago"
        case ..<86_400: return "\(s / 3600)h ago"
        case ..<(86_400 * 14): return "\(s / 86_400)d ago"
        case ..<(86_400 * 60): return "\(s / (86_400 * 7))w ago"
        default:
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
            return f.string(from: date)
        }
    }
}
