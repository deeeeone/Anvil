import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Observation

/// Runs the local servers provider plugins declare (`"server"` in anvil-provider.json), so a plugin can
/// bring its own API: setup once, start on first use, stop when Anvil quits.
@Observable
final class ProviderServers {
    static let shared = ProviderServers()

    enum State: Equatable { case stopped, settingUp, starting, running, failed(String) }

    private(set) var states: [String: State] = [:]
    @ObservationIgnored private var processes: [String: Process] = [:]
    @ObservationIgnored private var starting: [String: Task<Void, Error>] = [:]
    @ObservationIgnored private var sessionFingerprints: [String: String] = [:]

    func state(_ id: String) -> State { states[id] ?? .stopped }

    static func logFile(_ p: InstalledProvider) -> URL { p.folder.appendingPathComponent(".anvil-server.log") }
    private static func setupMarker(_ p: InstalledProvider) -> URL { p.folder.appendingPathComponent(".anvil-setup-done") }

    /// Changes to the spec or the setup script rerun setup.
    private static func setupFingerprint(_ p: InstalledProvider) -> String {
        var parts = [(try? String(contentsOf: p.folder.appendingPathComponent(ProviderSpec.fileName), encoding: .utf8)) ?? ""]
        for arg in p.spec.server?.setup ?? [] {
            if let s = try? String(contentsOf: p.folder.appendingPathComponent(arg), encoding: .utf8) { parts.append(s) }
        }
        var h: UInt64 = 1469598103934665603
        for b in parts.joined(separator: "\u{0}").utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return String(h, radix: 16)
    }

    /// Makes sure the plugin's server answers, setting it up and starting it if needed.
    func ensureRunning(_ p: InstalledProvider) async throws {
        guard let srv = p.spec.server, ProviderPlugins.shared.baseURL(p) == (p.spec.baseURL ?? "") else { return }
        // A new or rotated sign-in must restart the server with the new session.
        let session = ProviderPlugins.shared.session(p.id)
        let fingerprint = Self.sessionFingerprint(session)
        if sessionFingerprints[p.id] != fingerprint {
            if processes[p.id] != nil { stop(p.id) }
            sessionFingerprints[p.id] = fingerprint
        }
        if await Self.answers(srv.ready) { states[p.id] = .running; return }
        if let t = starting[p.id] { return try await t.value }
        let task = Task { try await self.start(p, srv) }
        starting[p.id] = task
        defer { starting[p.id] = nil }
        try await task.value
    }

    private func start(_ p: InstalledProvider, _ srv: ProviderSpec.Server) async throws {
        let log = Self.logFile(p)
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        var env = ProcessRunner.environment()
        env["CI"] = nil
        for (k, v) in srv.env ?? [:] { env[k] = v }
        env["ANVIL_PLUGIN_DIR"] = p.folder.path
        let session = ProviderPlugins.shared.session(p.id)
        if !session.cookies.isEmpty { env["ANVIL_PROVIDER_COOKIES"] = Self.json(session.cookies) }
        if !session.localStorage.isEmpty { env["ANVIL_PROVIDER_LOCALSTORAGE"] = Self.json(session.localStorage) }

        if let setup = srv.setup, !setup.isEmpty {
            let marker = Self.setupMarker(p)
            let want = Self.setupFingerprint(p)
            if (try? String(contentsOf: marker, encoding: .utf8)) != want {
                states[p.id] = .settingUp
                Self.append(log, "\n== setup: \(setup.joined(separator: " ")) (\(Date()))\n")
                let r = await Self.runToEnd(setup, cwd: p.folder, env: env, timeout: srv.setupTimeout ?? 900, log: log)
                guard r == 0 else {
                    let msg = "setup failed (exit \(r)). \(Self.tail(log))"
                    states[p.id] = .failed(msg)
                    throw BrainError(status: 0, code: "no_key", message: "\(p.spec.name): \(msg)")
                }
                try? want.write(to: marker, atomically: true, encoding: .utf8)
            }
        }

        states[p.id] = .starting
        Self.append(log, "\n== start: \(srv.command.joined(separator: " ")) (\(Date()))\n")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = srv.command
        proc.currentDirectoryURL = p.folder
        proc.environment = env
        let handle = try FileHandle(forWritingTo: log)
        handle.seekToEndOfFile()
        proc.standardOutput = handle
        proc.standardError = handle
        proc.standardInput = FileHandle.nullDevice
        do { try proc.run() } catch {
            states[p.id] = .failed(error.localizedDescription)
            throw BrainError(status: 0, code: "no_key", message: "\(p.spec.name) couldn't start its server: \(error.localizedDescription)")
        }
        processes[p.id] = proc
        let id = p.id
        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.processes[id] === proc else { return }
                self.processes[id] = nil
                if self.states[id] == .running { self.states[id] = .stopped }
            }
        }
        let deadline = Date().addingTimeInterval(srv.startupTimeout ?? 90)
        while Date() < deadline {
            if !proc.isRunning {
                let msg = "the server exited (status \(proc.terminationStatus)). \(Self.tail(log))"
                states[p.id] = .failed(msg)
                throw BrainError(status: 0, code: "no_key", message: "\(p.spec.name): \(msg)")
            }
            if await Self.answers(srv.ready) { states[p.id] = .running; return }
            try await Task.sleep(for: .milliseconds(500))
        }
        proc.terminate()
        let msg = "the server didn't answer at \(srv.ready) within \(Int(srv.startupTimeout ?? 90))s. \(Self.tail(log))"
        states[p.id] = .failed(msg)
        throw BrainError(status: 0, code: "upstream_timeout", message: "\(p.spec.name): \(msg)")
    }

    func stop(_ id: String) {
        if let p = processes.removeValue(forKey: id), p.isRunning { p.terminate() }
        states[id] = .stopped
    }

    func stopAll() {
        for (_, p) in processes where p.isRunning { p.terminate() }
        processes = [:]
        states = [:]
    }

    /// Forces setup to run again on the next start (e.g. after a broken install).
    func resetSetup(_ p: InstalledProvider) {
        stop(p.id)
        try? FileManager.default.removeItem(at: Self.setupMarker(p))
    }

    // MARK: Helpers

    private static func sessionFingerprint(_ s: ProviderPlugins.Session) -> String {
        var h: UInt64 = 1469598103934665603
        for part in (s.cookies.sorted { $0.key < $1.key } + s.localStorage.sorted { $0.key < $1.key }).map({ $0.key + "=" + $0.value }) {
            for b in part.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        }
        return String(h, radix: 16)
    }

    private static func json(_ d: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: d) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func answers(_ url: String) async -> Bool {
        guard let u = URL(string: url) else { return false }
        var req = URLRequest(url: u)
        req.timeoutInterval = 2
        guard let (_, resp) = try? await URLSession.shared.data(for: req), let http = resp as? HTTPURLResponse else { return false }
        return http.statusCode < 500
    }

    private static func runToEnd(_ command: [String], cwd: URL, env: [String: String], timeout: Double, log: URL) async -> Int32 {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = command
            p.currentDirectoryURL = cwd
            p.environment = env
            if let h = try? FileHandle(forWritingTo: log) { h.seekToEndOfFile(); p.standardOutput = h; p.standardError = h }
            p.standardInput = FileHandle.nullDevice
            p.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch { cont.resume(returning: 127); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
        }
    }

    private static func append(_ log: URL, _ text: String) {
        guard let h = try? FileHandle(forWritingTo: log) else { return }
        h.seekToEndOfFile()
        h.write(Data(text.utf8))
        try? h.close()
    }

    /// The last lines of the log, for error messages.
    static func tail(_ log: URL, lines: Int = 6) -> String {
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        let last = text.split(separator: "\n").suffix(lines).joined(separator: " | ")
        return last.isEmpty ? "" : "Log: " + Fmt.line(last, 500)
    }
}
