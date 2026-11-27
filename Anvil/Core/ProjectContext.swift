import Foundation

/// What the agent is told about the project: memory files, layout and git state.
nonisolated enum ProjectContext {
    static let memoryFiles = ["AGENTS.md", "CLAUDE.md", ".claude/CLAUDE.md", "ANVIL.md"]
    static let skipDirs: Set<String> = [".git", "node_modules", ".build", "build", "DerivedData", "Pods", ".venv", "venv", "__pycache__",
                                        ".next", "dist", ".swiftpm", "target", ".gradle", ".idea", ".turbo", ".cache", "coverage", ".pytest_cache", ".mypy_cache"]

    /// Contents of AGENTS.md / CLAUDE.md in the project root (clipped), with their names.
    static func memory(_ root: URL, limit: Int = 12000) -> [(name: String, text: String)] {
        memoryFiles.compactMap { name in
            guard let t = try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8),
                  !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return (name, Fmt.clip(t, max: limit))
        }
    }

    /// Whether a test file (*.test.*, *.spec.*, or a code file under tests/, test/ or __tests__/) sits within `depth` levels.
    static func hasTestFiles(_ root: URL, depth: Int = 3) -> Bool {
        let fm = FileManager.default
        let testDirs: Set<String> = ["__tests__", "tests", "test"]
        let codeExts: Set<String> = ["ts", "tsx", "js", "jsx", "mjs", "cjs", "py", "swift", "go", "rs", "rb", "php", "kt", "java"]
        func walk(_ dir: URL, level: Int, inTests: Bool) -> Bool {
            guard level <= depth,
                  let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return false }
            for u in items {
                let name = u.lastPathComponent
                if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    if skipDirs.contains(name) { continue }
                    if walk(u, level: level + 1, inTests: inTests || testDirs.contains(name)) { return true }
                } else if codeExts.contains(u.pathExtension.lowercased()),
                          name.contains(".test.") || name.contains(".spec.") || inTests {
                    return true
                }
            }
            return false
        }
        return walk(root, level: 1, inTests: false)
    }

    /// A shallow listing of the project (2 levels, skipping vendor/build folders).
    static func layout(_ root: URL, maxEntries: Int = 120) -> String {
        var lines: [String] = []
        func walk(_ dir: URL, depth: Int, prefix: String) {
            guard lines.count < maxEntries,
                  let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
            let sorted = items.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            for u in sorted {
                if lines.count >= maxEntries { lines.append(prefix + "…"); return }
                let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir {
                    if skipDirs.contains(u.lastPathComponent) { lines.append(prefix + u.lastPathComponent + "/ (skipped)"); continue }
                    let count = (try? FileManager.default.contentsOfDirectory(atPath: u.path).count) ?? 0
                    lines.append(prefix + u.lastPathComponent + "/" + (depth >= 1 ? " (\(count) items)" : ""))
                    if depth < 1 { walk(u, depth: depth + 1, prefix: prefix + "  ") }
                } else {
                    lines.append(prefix + u.lastPathComponent)
                }
            }
        }
        walk(root, depth: 0, prefix: "")
        return lines.isEmpty ? "(empty folder)" : lines.joined(separator: "\n")
    }

    static let initPrompt = """
    Analyze this codebase and create an AGENTS.md file in the project root (or improve it if one exists). It is read by \
    coding agents at the start of every session, so keep it short and high-signal (under ~80 lines):
    1. What the project is, in two sentences.
    2. How to build, run, lint and test it (exact commands, including running a single test).
    3. Architecture: the main folders and modules and how they fit together.
    4. Conventions that aren't obvious from the code (style, naming, error handling, things to avoid).
    Read the README, package manifests, config files and a few key sources first. Don't invent commands you haven't seen evidence for. \
    If a CLAUDE.md exists, fold its content in rather than duplicating it.
    """
}
