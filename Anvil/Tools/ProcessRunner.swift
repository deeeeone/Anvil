import Foundation

nonisolated struct ProcessOutput: Sendable {
    var status: Int32
    var stdout: String
    var stderr: String
    var timedOut: Bool
    var cancelled = false

    var combined: String {
        var s = stdout
        if !stderr.isEmpty { s += (s.isEmpty ? "" : "\n") + stderr }
        if timedOut { s += "\n[timed out]" }
        if cancelled { s += "\n[stopped]" }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Thread-safe text buffer that keeps the newest `limit` characters.
nonisolated final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private var dropped = 0
    let limit: Int
    init(limit: Int = 400_000) { self.limit = limit }

    func append(_ s: String) {
        lock.withLock {
            text += s
            // Trimming walks the whole string by characters, so do it rarely: only once the buffer has grown to twice
            // the limit (utf8.count is O(1)). Trimming on every append made a 200MB build log take minutes.
            if text.utf8.count > limit * 2 {
                let cut = text.count - limit
                if cut > 0 { dropped += cut; text = String(text.suffix(limit)) }
            }
        }
    }
    var value: String {
        lock.withLock {
            guard text.utf8.count > limit else { return text }
            return String(text.suffix(limit))
        }
    }
    var droppedChars: Int { lock.withLock { dropped } }
}

nonisolated enum ProcessRunner {
    static var basePath: String {
        let h = Paths.home.path
        return "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:\(h)/.local/bin:\(h)/.cargo/bin:\(h)/.bun/bin:\(h)/go/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    }

    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = basePath + ":" + (env["PATH"] ?? "")
        env["TERM"] = "dumb"
        env["NO_COLOR"] = "1"
        env["GIT_PAGER"] = "cat"
        env["PAGER"] = "cat"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["CI"] = env["CI"] ?? "1"
        // Edits a second apart with the same size leave stale .pyc files (Python checks mtime in whole seconds).
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env.removeValue(forKey: "ANVIL_API_KEY"); env.removeValue(forKey: "ANVIL_GEMINI_KEY")   // never leak the provider key into project commands
        return env
    }

    /// Runs an executable to completion (no streaming).
    static func run(_ executable: String, _ args: [String], stdin: String? = nil, cwd: URL? = nil, timeout: Double = 60) async -> ProcessOutput {
        await stream(executable, args, stdin: stdin, cwd: cwd, timeout: timeout, onOutput: nil)
    }

    /// Runs a shell command in `cwd`, calling `onOutput` with chunks as they arrive. Stops (whole process tree) on timeout or task cancellation.
    static func shell(_ command: String, cwd: URL, timeout: Double, onOutput: (@Sendable (String) -> Void)? = nil) async -> ProcessOutput {
        await stream("/bin/zsh", ["-c", command], cwd: cwd, timeout: timeout, onOutput: onOutput)
    }

    static func stream(_ executable: String, _ args: [String], stdin: String? = nil, cwd: URL? = nil, timeout: Double,
                       onOutput: (@Sendable (String) -> Void)?) async -> ProcessOutput {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        p.environment = environment()
        p.currentDirectoryURL = cwd ?? Paths.home
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let inp = Pipe()
        p.standardInput = stdin == nil ? FileHandle.nullDevice : inp
        let outBuf = OutputBuffer(), errBuf = OutputBuffer()
        let flags = RunFlags()
        let group = DispatchGroup()
        for (pipe, buf) in [(out, outBuf), (err, errBuf)] {
            group.enter()
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { h.readabilityHandler = nil; group.leave(); return }
                let s = String(decoding: d, as: UTF8.self)
                buf.append(s)
                onOutput?(s)
            }
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<ProcessOutput, Never>) in
                p.terminationHandler = { proc in
                    // Let the pipes drain (children holding them open are given a moment).
                    DispatchQueue.global().async {
                        _ = group.wait(timeout: .now() + 2)
                        out.fileHandleForReading.readabilityHandler = nil
                        err.fileHandleForReading.readabilityHandler = nil
                        cont.resume(returning: ProcessOutput(status: proc.terminationStatus, stdout: outBuf.value, stderr: errBuf.value,
                                                             timedOut: flags.timedOut, cancelled: flags.cancelled))
                    }
                }
                do { try p.run() } catch {
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    cont.resume(returning: ProcessOutput(status: -1, stdout: "", stderr: error.localizedDescription, timedOut: false))
                    return
                }
                flags.pid = p.processIdentifier
                if let stdin {
                    inp.fileHandleForWriting.write(Data(stdin.utf8))
                    try? inp.fileHandleForWriting.close()
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if p.isRunning { flags.timedOut = true; killTree(p.processIdentifier) }
                }
            }
        } onCancel: {
            flags.cancelled = true
            if let pid = flags.pid { killTree(pid) }
        }
    }

    /// Terminates a process and all its descendants (dev servers spawn children that outlive their parent).
    static func killTree(_ pid: Int32, signal sig: Int32 = SIGTERM) {
        for child in children(of: pid) { killTree(child, signal: sig) }
        kill(pid, sig)
        if sig == SIGTERM {
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if kill(pid, 0) == 0 { kill(pid, SIGKILL) } }
        }
    }

    static func children(of pid: Int32) -> [Int32] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-P", "\(pid)"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").compactMap { Int32($0) }
    }
}

nonisolated final class RunFlags: @unchecked Sendable {
    private let lock = NSLock()
    private var _timedOut = false, _cancelled = false, _pid: Int32?
    var timedOut: Bool { get { lock.withLock { _timedOut } } set { lock.withLock { _timedOut = newValue } } }
    var cancelled: Bool { get { lock.withLock { _cancelled } } set { lock.withLock { _cancelled = newValue } } }
    var pid: Int32? { get { lock.withLock { _pid } } set { lock.withLock { _pid = newValue } } }
}

/// Long-running background processes (dev servers, watchers) the agent starts and stops by name.
@Observable
final class ProcessManager {
    final class Entry: Identifiable {
        let name: String
        let command: String
        let cwd: URL
        let started = Date()
        /// The agent (ToolContext.owner) that started it; nil when the app or the terminal started it.
        var owner: String?
        let process: Process
        let output = OutputBuffer(limit: 300_000)
        var exitCode: Int32?
        var id: String { name }
        init(name: String, command: String, cwd: URL, process: Process) { self.name = name; self.command = command; self.cwd = cwd; self.process = process }
        var running: Bool { exitCode == nil }
    }

    private(set) var entries: [Entry] = []
    /// Bumped when output arrives, so views can refresh.
    private(set) var tick = 0

    func entry(_ name: String) -> Entry? { entries.last { $0.name == name } }

    func start(name: String, command: String, cwd: URL, owner: String? = nil) throws -> Entry {
        if let old = entry(name), old.running { throw NSError(domain: "Anvil", code: 1, userInfo: [NSLocalizedDescriptionKey: "a process named \(name) is already running; stop it first or pick another name"]) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", command]
        p.environment = ProcessRunner.environment()
        p.currentDirectoryURL = cwd
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let e = Entry(name: name, command: command, cwd: cwd, process: p)
        e.owner = owner
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            e.output.append(String(decoding: d, as: UTF8.self))
            Task { @MainActor in self?.tick += 1 }
        }
        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            Task { @MainActor in e.exitCode = code; self?.tick += 1 }
        }
        try p.run()
        entries.removeAll { $0.name == name && !$0.running }
        entries.append(e)
        return e
    }

    func stop(_ name: String) -> Bool {
        guard let e = entry(name), e.running else { return false }
        ProcessRunner.killTree(e.process.processIdentifier)
        return true
    }

    func stopAll() {
        for e in entries where e.running { ProcessRunner.killTree(e.process.processIdentifier, signal: SIGKILL) }
    }

    func remove(_ name: String) { entries.removeAll { $0.name == name && !$0.running } }
}
