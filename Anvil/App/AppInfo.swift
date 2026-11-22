import Foundation

/// Product identity in one place so the app is easy to rename.
nonisolated enum AppInfo {
    static let name = "Anvil"
    static let bundleID = "com.diwan.anvil"
    static let version = "0.1.0"
    /// Where Peep (the sibling desktop-pet app) keeps its provider key, for "Import key from Peep".
    static let peepKeychainService = "com.diwan.peep"
    static let peepKeychainAccount = "primaryKey"
    static var isTesting: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }
}

nonisolated enum Paths {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// ~/Library/Application Support/Anvil (overridable with ANVIL_SUPPORT_DIR for tests and headless runs).
    static var support: URL {
        if let o = ProcessInfo.processInfo.environment["ANVIL_SUPPORT_DIR"], !o.isEmpty { return dir(URL(fileURLWithPath: o)) }
        return dir(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(AppInfo.name, isDirectory: true))
    }

    static func sub(_ name: String) -> URL { dir(support.appendingPathComponent(name, isDirectory: true)) }

    @discardableResult
    static func dir(_ u: URL) -> URL {
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// Expands ~ and resolves relative paths against `base`.
    static func resolve(_ p: String, base: URL) -> URL {
        let t = p.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("~") { return URL(fileURLWithPath: (t as NSString).expandingTildeInPath).standardizedFileURL }
        if t.hasPrefix("/") { return URL(fileURLWithPath: t).standardizedFileURL }
        return base.appendingPathComponent(t).standardizedFileURL
    }

    /// Path relative to `root` when inside it, else with ~ for the home folder.
    static func display(_ u: URL, root: URL?) -> String {
        let p = u.standardizedFileURL.path
        if let root {
            let r = root.standardizedFileURL.path
            if p == r { return "." }
            if p.hasPrefix(r + "/") { return String(p.dropFirst(r.count + 1)) }
        }
        let h = home.path
        return p.hasPrefix(h) ? "~" + p.dropFirst(h.count) : p
    }

    /// The real location of a path that may not exist yet: symlinks are resolved on the deepest part that does exist
    /// (resolvingSymlinksInPath leaves a path with a missing last component untouched, which let a write through
    /// a symlink to a folder outside the project look like it was inside).
    static func realPath(_ u: URL) -> String {
        var existing = u.standardizedFileURL
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            rest.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for part in rest { resolved.appendPathComponent(part) }
        return resolved.standardizedFileURL.path
    }

    static func isInside(_ u: URL, root: URL) -> Bool {
        let p = realPath(u)
        let r = realPath(root)
        return p == r || p.hasPrefix(r.hasSuffix("/") ? r : r + "/")
    }
}

nonisolated enum Fmt {
    /// Keep the head and tail of long output.
    static func clip(_ s: String, max: Int = 9000) -> String {
        guard s.count > max else { return s }
        return String(s.prefix(max * 2 / 3)) + "\n…[\(s.count - max) chars cut]…\n" + String(s.suffix(max / 3))
    }

    /// One line, at most `max` characters.
    static func line(_ s: String, _ max: Int = 120) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return one.count > max ? String(one.prefix(max - 1)) + "…" : one
    }

    /// No em or en dashes in anything the app shows: " — " becomes ", ".
    static func plain(_ s: String) -> String {
        s.replacingOccurrences(of: " — ", with: ", ").replacingOccurrences(of: " – ", with: ", ")
            .replacingOccurrences(of: "—", with: ", ").replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: ",,", with: ",")
    }

    static func tokens(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1_000_000) : n >= 1000 ? String(format: "%.0fk", Double(n) / 1000) : "\(n)"
    }

    static func dollars(_ v: Double) -> String {
        v == 0 ? "$0" : v < 0.01 ? String(format: "$%.4f", v) : v < 1 ? String(format: "$%.3f", v) : String(format: "$%.2f", v)
    }
}
