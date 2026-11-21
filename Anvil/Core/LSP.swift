import Foundation

/// Type-level checks after edits, through the project's own language server.
///
/// One server per (project, language) stays running for the app's lifetime. After a batch of edits the
/// agent sends each changed file to the server and waits briefly for its diagnostics. Only errors the
/// edits *introduced* are reported: the file's errors before the first edit are the baseline, so a
/// project the server can't fully understand (missing build settings, unresolved imports) doesn't flood
/// the model with noise it can't fix.
nonisolated enum LSP {
    struct Diagnostic: Hashable, Sendable {
        var line: Int        // 1-based
        var message: String
        var source: String
        /// Identity without the line number, so moved code doesn't look like a new error.
        var key: String { source + "|" + message }
    }

    /// A language server Anvil knows how to start, and the files it covers.
    struct Server: Sendable, Equatable {
        var name: String
        var executable: String
        var args: [String]
        var languageID: @Sendable (String) -> String
        /// How long to wait for diagnostics after the first open (servers index the project first) and later.
        var firstWait: Double
        var wait: Double
        static func == (a: Server, b: Server) -> Bool { a.name == b.name && a.executable == b.executable }
    }

    /// The server for a file in `root`, if one is installed and the project looks like that language's project.
    static func server(for url: URL, root: URL) -> Server? {
        let fm = FileManager.default
        func has(_ f: String) -> Bool { fm.fileExists(atPath: root.appendingPathComponent(f).path) }
        switch url.pathExtension.lowercased() {
        case "ts", "tsx", "mts", "cts", "js", "jsx", "mjs", "cjs":
            let js = ["js", "jsx", "mjs", "cjs"].contains(url.pathExtension.lowercased())
            if js && !has("jsconfig.json") && !has("tsconfig.json") { return nil }
            let language: @Sendable (String) -> String = { ext in
                switch ext { case "tsx": return "typescriptreact"; case "jsx": return "javascriptreact"
                case "js", "mjs", "cjs": return "javascript"; default: return "typescript" }
            }
            // TypeScript 7 (the native port) has its own server and no tsserver.js for typescript-language-server.
            let tsc = root.appendingPathComponent("node_modules/.bin/tsc").path
            if typeScriptMajor(root) ?? 0 >= 7, fm.isExecutableFile(atPath: tsc) {
                return Server(name: "tsgo", executable: tsc, args: ["--lsp", "--stdio"], languageID: language, firstWait: 12, wait: 5)
            }
            guard let exe = find("typescript-language-server", root: root) else { return nil }
            return Server(name: "typescript", executable: exe, args: ["--stdio"], languageID: language, firstWait: 12, wait: 5)
        case "py", "pyi":
            if let exe = find("basedpyright-langserver", root: root) ?? find("pyright-langserver", root: root) {
                return Server(name: "pyright", executable: exe, args: ["--stdio"], languageID: { _ in "python" }, firstWait: 10, wait: 4)
            }
            return nil
        case "go":
            guard has("go.mod"), let exe = find("gopls", root: root) else { return nil }
            return Server(name: "gopls", executable: exe, args: [], languageID: { _ in "go" }, firstWait: 15, wait: 5)
        case "rs":
            guard has("Cargo.toml"), let exe = find("rust-analyzer", root: root) else { return nil }
            return Server(name: "rust-analyzer", executable: exe, args: [], languageID: { _ in "rust" }, firstWait: 30, wait: 10)
        case "swift":
            // Without a package sourcekit-lsp has no build settings and reports imports as errors.
            guard has("Package.swift") else { return nil }
            let exe = find("sourcekit-lsp", root: root) ?? "/usr/bin/sourcekit-lsp"
            guard fm.isExecutableFile(atPath: exe) else { return nil }
            return Server(name: "sourcekit-lsp", executable: exe, args: [], languageID: { _ in "swift" }, firstWait: 20, wait: 6)
        default:
            return nil
        }
    }

    /// Major version of the project's own TypeScript, if it has one.
    static func typeScriptMajor(_ root: URL) -> Int? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("node_modules/typescript/package.json")),
              let v = JSON.parse(String(decoding: data, as: UTF8.self))?["version"]?.string else { return nil }
        return Int(v.split(separator: ".").first ?? "")
    }

    /// Errors (severity 1) from a list of LSP diagnostics.
    static func parse(_ list: [JSON]) -> [Diagnostic] {
        list.compactMap { d -> Diagnostic? in
            guard (d["severity"]?.int ?? 1) == 1, let msg = d["message"]?.string else { return nil }
            let line = (d["range"]?["start"]?["line"]?.int ?? 0) + 1
            return Diagnostic(line: line, message: Fmt.line(msg, 300), source: d["source"]?.string ?? "")
        }
    }

    /// The project's own copy (node_modules/.bin, .venv/bin) first, then the usual install folders.
    static func find(_ name: String, root: URL) -> String? {
        let local = ["node_modules/.bin", ".venv/bin", "venv/bin"].map { root.appendingPathComponent($0).appendingPathComponent(name).path }
        let global = ProcessRunner.environment()["PATH", default: ""].split(separator: ":").map { "\($0)/\(name)" }
        return (local + global).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Errors (severity 1) the server reports for `text` as the contents of `url`; nil when the server
    /// didn't answer in time or couldn't start.
    static func errors(_ url: URL, text: String, root: URL, server: Server) async -> [Diagnostic]? {
        guard let conn = await Connections.shared.connection(root: root, server: server) else { return nil }
        return await conn.diagnostics(url, text: text)
    }

    /// Lines for the observation: errors in `after` whose identity isn't in `baseline`.
    static func introduced(after: [Diagnostic], baseline: Set<String>, path: String, limit: Int = 8) -> [String] {
        after.filter { !baseline.contains($0.key) }.sorted { $0.line < $1.line }.prefix(limit)
            .map { "\(path):\($0.line): \($0.message)\($0.source.isEmpty ? "" : " [\($0.source)]")" }
    }

    static func stopAll() { Task { await Connections.shared.stopAll() } }

    // MARK: Connections

    actor Connections {
        static let shared = Connections()
        private var live: [String: Connection] = [:]
        private var broken: Set<String> = []

        func connection(root: URL, server: Server) async -> Connection? {
            let key = root.standardizedFileURL.path + "|" + server.name
            if let c = live[key], await c.isAlive { return c }
            guard !broken.contains(key) else { return nil }
            let c = Connection(root: root, server: server)
            if await c.start() { live[key] = c; return c }
            broken.insert(key)   // not installed properly, or it crashed on start: don't retry every batch
            return nil
        }

        func stopAll() async {
            for c in live.values { await c.stop() }
            live = [:]
        }
    }

    /// One running server, spoken to over stdio with Content-Length framing.
    actor Connection {
        let root: URL
        let server: Server
        private var process: Process?
        private var input: FileHandle?
        private var nextID = 1
        private var pending: [Int: CheckedContinuation<JSON?, Never>] = [:]
        private var versions: [String: Int] = [:]
        private var published: [String: (gen: Int, items: [Diagnostic])] = [:]
        private var opened = false
        /// The server answers textDocument/diagnostic (pull) instead of only pushing diagnostics.
        private var pull = false
        private let reader = FrameReader()

        init(root: URL, server: Server) {
            self.root = root
            self.server = server
        }

        var isAlive: Bool { process?.isRunning ?? false }

        func start() async -> Bool {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: server.executable)
            p.arguments = server.args
            p.currentDirectoryURL = root
            p.environment = ProcessRunner.environment()
            let inPipe = Pipe(), outPipe = Pipe()
            p.standardInput = inPipe
            p.standardOutput = outPipe
            p.standardError = FileHandle.nullDevice
            let reader = self.reader
            outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
                let data = h.availableData
                if data.isEmpty { h.readabilityHandler = nil; return }
                for message in reader.feed(data) {
                    Task { await self?.handle(message) }
                }
            }
            do { try p.run() } catch { return false }
            process = p
            input = inPipe.fileHandleForWriting
            let uri = root.absoluteString
            let initialize = await request("initialize", .object([
                "processId": .number(Double(ProcessInfo.processInfo.processIdentifier)),
                "rootUri": .string(uri),
                "rootPath": .string(root.path),
                "workspaceFolders": .array([.object(["uri": .string(uri), "name": .string(root.lastPathComponent)])]),
                "capabilities": .object([
                    "textDocument": .object([
                        "publishDiagnostics": .object(["relatedInformation": .bool(false)]),
                        "diagnostic": .object(["dynamicRegistration": .bool(false)]),
                        "synchronization": .object(["didSave": .bool(true), "dynamicRegistration": .bool(false)]),
                    ]),
                    "workspace": .object(["configuration": .bool(true), "workspaceFolders": .bool(true)]),
                ]),
            ]), timeout: 30)
            guard let initialize, initialize["capabilities"] != nil else { stop(); return false }
            pull = initialize["capabilities"]?["diagnosticProvider"].map { if case .null = $0 { return false } else { return true } } ?? false
            notify("initialized", .object([:]))
            return true
        }

        func stop() {
            if let p = process, p.isRunning {
                notify("exit", .null)
                p.terminate()
            }
            process = nil
            input = nil
            for (_, c) in pending { c.resume(returning: nil) }
            pending = [:]
        }

        /// Sends the file's text and waits for the server's next diagnostics for it.
        func diagnostics(_ url: URL, text: String) async -> [Diagnostic]? {
            guard isAlive else { return nil }
            let uri = url.standardizedFileURL.absoluteString
            let key = Self.key(uri)
            let gen = published[key]?.gen ?? 0
            let first = !opened
            opened = true
            if let v = versions[uri] {
                versions[uri] = v + 1
                notify("textDocument/didChange", .object([
                    "textDocument": .object(["uri": .string(uri), "version": .number(Double(v + 1))]),
                    "contentChanges": .array([.object(["text": .string(text)])]),
                ]))
            } else {
                versions[uri] = 1
                notify("textDocument/didOpen", .object(["textDocument": .object([
                    "uri": .string(uri), "languageId": .string(server.languageID(url.pathExtension.lowercased())),
                    "version": .number(1), "text": .string(text),
                ])]))
            }
            // rust-analyzer and gopls run their full checks on save.
            notify("textDocument/didSave", .object(["textDocument": .object(["uri": .string(uri)])]))
            if pull {
                let r = await request("textDocument/diagnostic", .object(["textDocument": .object(["uri": .string(uri)])]),
                                      timeout: first ? server.firstWait : server.wait)
                if let items = r?["items"]?.array { return LSP.parse(items) }
                // Fall back to whatever the server pushes.
            }
            let deadline = Date().addingTimeInterval(first ? server.firstWait : server.wait)
            while Date() < deadline {
                if let p = published[key], p.gen > gen {
                    // Some servers publish an early empty set, then the real one: give it a moment to settle.
                    try? await Task.sleep(for: .milliseconds(p.items.isEmpty ? 600 : 250))
                    return published[key]?.items ?? p.items
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return nil
        }

        /// Closes a file so the next check of it starts fresh (used for baselines of old text).
        func close(_ url: URL) {
            let uri = url.standardizedFileURL.absoluteString
            guard versions[uri] != nil else { return }
            versions[uri] = nil
            notify("textDocument/didClose", .object(["textDocument": .object(["uri": .string(uri)])]))
        }

        /// The same file can come back as /tmp/x or /private/tmp/x, encoded differently: compare real paths.
        static func key(_ uri: String) -> String {
            guard let u = URL(string: uri), u.isFileURL else { return uri }
            return u.resolvingSymlinksInPath().standardizedFileURL.path
        }

        private func request(_ method: String, _ params: JSON, timeout: Double) async -> JSON? {
            let id = nextID
            nextID += 1
            send(.object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method), "params": params]))
            return await withCheckedContinuation { cont in
                pending[id] = cont
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    await self?.expire(id)
                }
            }
        }

        private func expire(_ id: Int) {
            pending.removeValue(forKey: id)?.resume(returning: nil)
        }

        private func notify(_ method: String, _ params: JSON) {
            send(.object(["jsonrpc": .string("2.0"), "method": .string(method), "params": params]))
        }

        private func send(_ message: JSON) {
            guard let input else { return }
            let body = Data(message.compact.utf8)
            var frame = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
            frame.append(body)
            try? input.write(contentsOf: frame)
        }

        private func handle(_ message: JSON) {
            let method = message["method"]?.string
            if let id = message["id"]?.int, method == nil {
                // An error reply (the server couldn't start, or doesn't support the request) counts as no answer.
                pending.removeValue(forKey: id)?.resume(returning: message["error"] == nil ? (message["result"] ?? .null) : nil)
                return
            }
            if let method, let id = message["id"] {
                // A request from the server: answer so it doesn't wait (configuration gets one null per item).
                let result: JSON = method == "workspace/configuration"
                    ? .array((message["params"]?["items"]?.array ?? []).map { _ in JSON.null })
                    : .null
                send(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
                return
            }
            guard method == "textDocument/publishDiagnostics", let params = message["params"],
                  let uri = params["uri"]?.string else { return }
            let items = LSP.parse(params["diagnostics"]?.array ?? [])
            let key = Self.key(uri)
            published[key] = ((published[key]?.gen ?? 0) + 1, items)
        }
    }

    /// Splits a byte stream into LSP messages (`Content-Length: n\r\n\r\n` + n bytes of JSON).
    final class FrameReader: @unchecked Sendable {
        private var buffer = Data()
        private let lock = NSLock()

        func feed(_ data: Data) -> [JSON] {
            lock.lock(); defer { lock.unlock() }
            buffer.append(data)
            var out: [JSON] = []
            let separator = Data("\r\n\r\n".utf8)
            while let range = buffer.range(of: separator) {
                let header = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
                let length = header.split(separator: "\r\n").compactMap { line -> Int? in
                    let parts = line.split(separator: ":", maxSplits: 1)
                    guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" else { return nil }
                    return Int(parts[1].trimmingCharacters(in: .whitespaces))
                }.first
                guard let length else { buffer.removeSubrange(buffer.startIndex..<range.upperBound); continue }
                let start = range.upperBound
                guard buffer.distance(from: start, to: buffer.endIndex) >= length else { break }
                let end = buffer.index(start, offsetBy: length)
                if let j = JSON.parse(String(decoding: buffer[start..<end], as: UTF8.self)) { out.append(j) }
                buffer.removeSubrange(buffer.startIndex..<end)
            }
            return out
        }
    }
}
