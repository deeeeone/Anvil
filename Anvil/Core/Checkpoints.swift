import Foundation

/// The original content of a file before a task first touched it (`original == nil`: the file didn't exist).
nonisolated struct FileSnapshot: Codable, Equatable, Sendable {
    var path: String
    var original: String?
}

/// Every file a task (one request) changed, so the whole task can be undone.
nonisolated struct Checkpoint: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var created = Date()
    var label: String
    var files: [FileSnapshot] = []
    var restored = false

    /// Remember a file's pre-task content (only the first time this task touches it).
    mutating func record(_ url: URL, before: String?) {
        let p = url.standardizedFileURL.path
        guard !files.contains(where: { $0.path == p }) else { return }
        files.append(FileSnapshot(path: p, original: before))
    }

    /// Puts every file back the way it was before the task. Returns the paths it restored.
    @discardableResult
    func restore() throws -> [String] {
        var done: [String] = []
        for f in files {
            let url = URL(fileURLWithPath: f.path)
            if let o = f.original {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try o.write(to: url, atomically: true, encoding: .utf8)
            } else if FileManager.default.fileExists(atPath: f.path) {
                try FileManager.default.removeItem(at: url)
            }
            done.append(f.path)
        }
        return done
    }
}

nonisolated enum Checkpoints {
    /// Undo back to (and including) checkpoint `id`: newest first, so files end up as they were before that task.
    static func rewind(_ list: inout [Checkpoint], to id: UUID) throws -> [String] {
        guard let idx = list.firstIndex(where: { $0.id == id }) else { return [] }
        var paths: [String] = []
        for i in stride(from: list.count - 1, through: idx, by: -1) where !list[i].restored {
            paths += try list[i].restore()
            list[i].restored = true
        }
        return Array(Set(paths)).sorted()
    }
}
