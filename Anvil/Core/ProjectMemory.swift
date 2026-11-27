import Foundation

/// What Anvil learns about a project across sessions: the commands that build and test it, and lessons from failures.
nonisolated struct ProjectMemory: Codable, Equatable, Sendable {
    var testCommand: String?
    var buildCommand: String?
    var lessons: [String] = []

    static func file(_ root: URL) -> URL {
        Paths.dir(Paths.sub("projects").appendingPathComponent(SessionStore.projectKey(root))).appendingPathComponent("memory.json")
    }

    static func load(_ root: URL) -> ProjectMemory {
        guard let d = try? Data(contentsOf: file(root)), let m = try? JSONDecoder().decode(ProjectMemory.self, from: d) else { return ProjectMemory() }
        return m
    }

    func save(_ root: URL) {
        if let d = try? JSONEncoder().encode(self) { try? d.write(to: Self.file(root), options: .atomic) }
    }

    mutating func addLesson(_ s: String) {
        let t = Fmt.line(s, 220)
        guard !lessons.contains(t) else { return }
        lessons.append(t)
        if lessons.count > 8 { lessons.removeFirst(lessons.count - 8) }
    }

    /// Is this shell command a test run? (so a passing one can be remembered and re-run automatically)
    static func isTestCommand(_ cmd: String) -> Bool {
        let c = cmd.lowercased()
        let patterns = [#"\bpytest\b"#, #"-m\s+unittest\b"#, #"\b(npm|yarn|pnpm|bun)\s+(run\s+)?test\b"#, #"\bjest\b"#, #"\bvitest\b"#, #"\bmocha\b"#,
                        #"\bgo\s+test\b"#, #"\bcargo\s+test\b"#, #"\bswift\s+test\b"#, #"xcodebuild\b.*\btest\b"#, #"\bnode\s+--test\b"#,
                        #"\bmake\s+(test|check)\b"#, #"\brspec\b"#, #"\bphpunit\b"#, #"\bmix\s+test\b"#, #"\bdotnet\s+test\b"#, #"\bgradlew?\s+test\b"#, #"\bdeno\s+test\b"#]
        return patterns.contains { c.range(of: $0, options: .regularExpression) != nil }
    }

    static func isBuildCommand(_ cmd: String) -> Bool {
        let c = cmd.lowercased()
        let patterns = [#"\b(npm|yarn|pnpm|bun)\s+(run\s+)?(build|typecheck|lint)\b"#, #"\btsc\b"#, #"\bswift\s+build\b"#, #"\bcargo\s+(build|check)\b"#, #"\bgo\s+(build|vet)\b"#,
                        #"\bxcodebuild\b"#, #"\bmake\b"#, #"\bmvn\b"#, #"\bgradlew?\s+build\b"#, #"\bpy_compile\b"#, #"\bruff\b"#, #"\bmypy\b"#, #"\beslint\b"#]
        return patterns.contains { c.range(of: $0, options: .regularExpression) != nil }
    }

    /// The likely test command from the project's files, before any has run.
    // MARK: Checks that fit the change

    /// Which languages a command checks ("" = can't tell, e.g. make or a custom script: trust it).
    static func languages(of cmd: String) -> Set<String> {
        let c = cmd.lowercased()
        if c.range(of: #"\b(pytest|unittest|py_compile|mypy|ruff|python3?)\b"#, options: .regularExpression) != nil { return ["py"] }
        if c.range(of: #"\b(npm|yarn|pnpm|bun|npx|node|jest|vitest|mocha|tsc|eslint|next|vite|deno)\b"#, options: .regularExpression) != nil {
            return ["js", "jsx", "ts", "tsx", "mjs", "cjs", "css", "scss", "html", "json", "vue", "svelte", "md", "mdx"]
        }
        if c.contains("cargo") { return ["rs", "toml"] }
        if c.range(of: #"\bgo\s"#, options: .regularExpression) != nil { return ["go"] }
        if c.contains("swift ") || c.contains("xcodebuild") { return ["swift", "plist"] }
        return []
    }

    /// Whether running `cmd` says anything about files with these paths.
    static func covers(_ cmd: String, changed: [String]) -> Bool {
        let langs = languages(of: cmd)
        guard !langs.isEmpty else { return true }
        let exts = Set(changed.map { URL(fileURLWithPath: $0).pathExtension.lowercased() }.filter { !$0.isEmpty })
        return exts.isEmpty || !exts.isDisjoint(with: langs)
    }

    private static let manifests = ["package.json", "Cargo.toml", "go.mod", "Package.swift", "pyproject.toml", "setup.py"]

    /// The folder (inside `root`) that holds the project the changed files belong to: the nearest manifest above them.
    static func projectDir(for changed: [String], root: URL) -> URL {
        let fm = FileManager.default
        var counts: [String: Int] = [:]
        let rootPath = root.standardizedFileURL.path
        for f in changed {
            var dir = URL(fileURLWithPath: f).deletingLastPathComponent().standardizedFileURL
            var found = rootPath
            while dir.path.hasPrefix(rootPath) {
                if manifests.contains(where: { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }) { found = dir.path; break }
                if dir.path == rootPath { break }
                dir = dir.deletingLastPathComponent()
            }
            counts[found, default: 0] += 1
        }
        return URL(fileURLWithPath: counts.max { $0.value < $1.value }?.key ?? rootPath)
    }

    /// The command that checks a request's changes, run from the project root. nil = nothing fits; ask the model.
    static func verifyCommand(changed: [String], root: URL, remembered: String?) -> String? {
        guard !changed.isEmpty else { return remembered ?? guessTestCommand(root) }
        let dir = projectDir(for: changed, root: root)
        let atRoot = dir.standardizedFileURL.path == root.standardizedFileURL.path
        if atRoot, let r = remembered, covers(r, changed: changed) { return r }
        let prefix = atRoot ? "" : "cd \(shellQuote(Paths.display(dir, root: root))) && "
        if let t = guessTestCommand(dir), covers(t, changed: changed) { return prefix + t }
        if let b = buildCommand(dir), covers(b, changed: changed) { return prefix + b }
        // Plain Python files with no tests: at least make sure they compile.
        let py = changed.filter { $0.hasSuffix(".py") }
        if !py.isEmpty, py.count == changed.count {
            return "python3 -m py_compile " + py.map { shellQuote(Paths.display(URL(fileURLWithPath: $0), root: root)) }.joined(separator: " ")
        }
        return nil
    }

    /// A build or type-check for a project folder, installing JavaScript dependencies first when they're missing.
    static func buildCommand(_ dir: URL) -> String? {
        let fm = FileManager.default
        func has(_ p: String) -> Bool { fm.fileExists(atPath: dir.appendingPathComponent(p).path) }
        if has("package.json") {
            let pm = has("pnpm-lock.yaml") ? "pnpm" : has("yarn.lock") ? "yarn" : has("bun.lockb") || has("bun.lock") ? "bun" : "npm"
            let install = depsInstalled(dir) ? "" : (pm == "npm" ? "npm install --no-audit --no-fund && " : "\(pm) install && ")
            if let d = try? Data(contentsOf: dir.appendingPathComponent("package.json")), let j = JSON.parse(String(decoding: d, as: UTF8.self)) {
                for script in ["build", "typecheck", "lint"] where j["scripts"]?[script]?.string != nil {
                    return install + (pm == "npm" ? "npm run \(script)" : "\(pm) run \(script)")
                }
            }
            if has("tsconfig.json") { return install + "npx tsc --noEmit" }
            return nil
        }
        if has("Cargo.toml") { return "cargo check" }
        if has("go.mod") { return "go build ./..." }
        if has("Package.swift") { return "swift build" }
        return nil
    }

    /// JavaScript dependencies count as installed only when the folder's own node_modules/.bin exists.
    static func depsInstalled(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent("node_modules/.bin").path)
    }

    private static func shellQuote(_ s: String) -> String {
        s.range(of: #"^[A-Za-z0-9_./~-]+$"#, options: .regularExpression) != nil ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func guessTestCommand(_ root: URL) -> String? {
        let fm = FileManager.default
        func has(_ p: String) -> Bool { fm.fileExists(atPath: root.appendingPathComponent(p).path) }
        if has("package.json"), let d = try? Data(contentsOf: root.appendingPathComponent("package.json")),
           let j = JSON.parse(String(decoding: d, as: UTF8.self)), let t = j["scripts"]?["test"]?.string, !t.contains("no test specified") {
            return has("pnpm-lock.yaml") ? "pnpm test" : has("yarn.lock") ? "yarn test" : has("bun.lockb") ? "bun test" : "npm test"
        }
        // Test files without a test script: run them with the runner the project depends on.
        if has("package.json"), ProjectContext.hasTestFiles(root) {
            let pkg = (try? Data(contentsOf: root.appendingPathComponent("package.json"))).flatMap { JSON.parse(String(decoding: $0, as: UTF8.self)) }
            func dep(_ n: String) -> Bool { pkg?["devDependencies"]?[n] != nil || pkg?["dependencies"]?[n] != nil }
            if dep("vitest") { return "npx vitest run" }
            if dep("jest") { return "npx jest" }
            if dep("tsx") { return "npx tsx --test" }
            return "node --test"
        }
        if has("Cargo.toml") { return "cargo test" }
        if has("go.mod") { return "go test ./..." }
        if has("Package.swift") { return "swift test" }
        if has("pytest.ini") || has("conftest.py") || has("tests/conftest.py") { return has(".venv/bin/python") ? ".venv/bin/python -m pytest -q" : "python3 -m pytest -q" }
        if has("pyproject.toml"), let t = try? String(contentsOf: root.appendingPathComponent("pyproject.toml"), encoding: .utf8), t.contains("pytest") {
            return has(".venv/bin/python") ? ".venv/bin/python -m pytest -q" : "python3 -m pytest -q"
        }
        if has("Makefile"), let t = try? String(contentsOf: root.appendingPathComponent("Makefile"), encoding: .utf8), t.range(of: #"(?m)^test:"#, options: .regularExpression) != nil { return "make test" }
        let pyTests = (try? fm.contentsOfDirectory(atPath: root.path))?.filter { $0.hasPrefix("test_") && $0.hasSuffix(".py") } ?? []
        if !pyTests.isEmpty { return "python3 -m unittest -q" }
        return nil
    }
}

/// A compact symbol outline of the project (files and their top-level functions, classes, types), so the model
/// can jump straight to the right code. Regex-based: fast, no dependencies, good enough for navigation.
nonisolated enum RepoMap {
    static let rules: [String: [String]] = [
        "py": [#"^(?:async\s+)?def\s+([A-Za-z_]\w*)\s*\("#, #"^class\s+([A-Za-z_]\w*)"#, #"^    (?:async\s+)?def\s+([A-Za-z_]\w*)\s*\("#],
        "js": [#"^(?:export\s+)?(?:default\s+)?(?:async\s+)?function\s*\*?\s*([A-Za-z_$][\w$]*)"#, #"^(?:export\s+)?(?:default\s+)?class\s+([A-Za-z_$][\w$]*)"#,
               #"^(?:export\s+)?(?:const|let)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s*)?(?:\([^)]*\)|[A-Za-z_$][\w$]*)\s*=>"#],
        "swift": [#"^\s*(?:public\s+|private\s+|fileprivate\s+|internal\s+|open\s+|final\s+|static\s+|nonisolated\s+|@\w+\s+)*(?:func|class|struct|enum|protocol|actor|extension)\s+([A-Za-z_][\w.]*)"#],
        "go": [#"^func\s+(?:\([^)]*\)\s*)?([A-Za-z_]\w*)"#, #"^type\s+([A-Za-z_]\w*)"#],
        "rs": [#"^\s*(?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?(?:fn|struct|enum|trait|impl)\s+([A-Za-z_]\w*)"#],
        "rb": [#"^\s*(?:def|class|module)\s+([A-Za-z_][\w.?!]*)"#],
        "java": [#"^\s*(?:public|private|protected)?\s*(?:static\s+)?(?:final\s+)?(?:class|interface|enum|record)\s+([A-Za-z_]\w*)"#,
                 #"^\s+(?:public|private|protected)\s+(?:static\s+)?[\w<>\[\],\s]+\s+([a-z]\w*)\s*\("#],
        "kt": [#"^\s*(?:fun|class|object|interface)\s+([A-Za-z_][\w.]*)"#],
        "php": [#"^\s*(?:function|class|interface|trait)\s+([A-Za-z_]\w*)"#],
        "c": [#"^[A-Za-z_][\w\s\*]*\s\**([A-Za-z_]\w*)\s*\([^;]*$"#],
    ]
    static let aliases = ["ts": "js", "tsx": "js", "jsx": "js", "mjs": "js", "cjs": "js", "cpp": "c", "cc": "c", "h": "c", "hpp": "c", "m": "c", "kts": "kt"]

    static func language(_ ext: String) -> String? {
        let e = ext.lowercased()
        let l = aliases[e] ?? e
        return rules[l] == nil ? nil : l
    }

    static func symbols(in text: String, language: String) -> [String] {
        guard let pats = rules[language] else { return [] }
        let res = pats.compactMap { try? NSRegularExpression(pattern: $0, options: [.anchorsMatchLines]) }
        var out: [String] = []
        let ns = NSString(string: text)
        for (i, re) in res.enumerated() {
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges > 1 {
                let name = ns.substring(with: m.range(at: 1))
                if ["if", "for", "while", "switch", "return", "main"].contains(name) && language == "c" { continue }
                // Indented Python defs are methods: mark them.
                out.append(language == "py" && i == 2 ? "." + name : name)
            }
        }
        // Keep source order.
        var seen = Set<String>()
        let ordered = out.compactMap { s -> (Int, String)? in
            let key = s.hasPrefix(".") ? String(s.dropFirst()) : s
            guard let r = text.range(of: key) else { return nil }
            return (text.distance(from: text.startIndex, to: r.lowerBound), s)
        }.sorted { $0.0 < $1.0 }.map(\.1)
        return ordered.filter { seen.insert($0).inserted }
    }

    /// "path: sym, sym, ..." lines for source files under `root`, capped at `limit` characters.
    static func build(_ root: URL, limit: Int = 7000) -> String {
        let files = FileTools.walk(root).filter { language($0.pathExtension) != nil }
        guard !files.isEmpty else { return "" }
        let base = root.standardizedFileURL.path + "/"
        // Tests and big generated files last; short paths (entry points) first.
        let sorted = files.sorted { a, b in
            let ta = a.path.lowercased().contains("test"), tb = b.path.lowercased().contains("test")
            if ta != tb { return !ta }
            return a.pathComponents.count == b.pathComponents.count ? a.path < b.path : a.pathComponents.count < b.pathComponents.count
        }
        var out = ""
        var shown = 0
        for f in sorted {
            guard let lang = language(f.pathExtension),
                  let data = try? Data(contentsOf: f), data.count < 400_000, !data.prefix(2000).contains(0) else { continue }
            let syms = symbols(in: String(decoding: data, as: UTF8.self), language: lang)
            let rel = f.standardizedFileURL.path.hasPrefix(base) ? String(f.standardizedFileURL.path.dropFirst(base.count)) : f.lastPathComponent
            var line = rel + (syms.isEmpty ? "" : ": " + syms.prefix(40).joined(separator: ", ") + (syms.count > 40 ? ", …" : ""))
            if line.count > 400 { line = String(line.prefix(399)) + "…" }
            if out.count + line.count > limit {
                out += "… (\(sorted.count - shown) more files; use repo_map with a path)\n"
                break
            }
            out += line + "\n"
            shown += 1
        }
        return out
    }
}

/// Fast syntax checks after an edit, so the model sees a broken file in the same observation instead of a turn later.
nonisolated enum Diagnostics {
    /// The command that checks one file, or nil when there is no fast check for its type.
    static func command(for url: URL) -> [String]? {
        let p = url.path
        switch url.pathExtension.lowercased() {
        case "py": return ["/usr/bin/env", "python3", "-c", "import ast,sys; ast.parse(open(sys.argv[1]).read(), sys.argv[1])", p]
        case "js", "mjs", "cjs": return ["/usr/bin/env", "node", "--check", p]
        case "json": return ["/usr/bin/env", "python3", "-c", "import json,sys; json.load(open(sys.argv[1]))", p]
        case "sh", "bash", "zsh": return [ProcessRunner.shellPath, "-n", p]
        case "rb": return ["/usr/bin/env", "ruby", "-c", p]
        case "swift": return ["/usr/bin/env", "swiftc", "-parse", p]
        case "php": return ["/usr/bin/env", "php", "-l", p]
        case "go": return ["/usr/bin/env", "gofmt", "-e", "-l", p]
        default: return nil
        }
    }

    /// nil = fine (or no check available); otherwise the error, trimmed.
    static func check(_ url: URL) async -> String? {
        guard FileManager.default.fileExists(atPath: url.path), let cmd = command(for: url) else { return nil }
        let r = await ProcessRunner.run(cmd[0], Array(cmd.dropFirst()), timeout: 20)
        if r.timedOut || r.status == 127 { return nil }   // tool missing or too slow: don't block on it
        if r.status == 0 { return nil }
        let msg = r.combined.replacingOccurrences(of: url.path, with: url.lastPathComponent)
        if msg.contains("No such file or directory") && msg.contains("env:") { return nil }
        return Fmt.clip(msg, max: 1200)
    }
}
