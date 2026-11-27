import Foundation

/// Discord Rich Presence, styled like VS Code's: "Editing AppState.swift" / "Workspace: my-app" on your Discord profile,
/// with the Anvil logo, a status badge and a button to the repo.
/// It speaks Discord's local IPC protocol (a Unix socket the Discord app opens in the temp folder), so nothing
/// leaves your Mac except what Discord itself shows. It does nothing when Discord isn't running and retries quietly.
///
/// File names, hosts, commands and the project name are only shown when the owner turns project names on.
nonisolated final class DiscordPresence: @unchecked Sendable {
    static let shared = DiscordPresence()
    /// The default Discord application the presence belongs to (its name comes from the Developer Portal; the owner can change it in Settings).
    static let clientID = "918234595579805776"
    static let repoURL = "https://github.com/heurica-labs/anvil"
    /// The large image: a public URL, so no art has to be uploaded to the Developer Portal. It loads once the repo is public.
    static let logoURL = "https://raw.githubusercontent.com/heurica-labs/anvil/main/design/anvil-icon-1024.png"
    /// Status badges (small image), one per state, in design/presence/.
    static func badgeURL(_ name: String) -> String { "https://raw.githubusercontent.com/heurica-labs/anvil/main/design/presence/\(name).png" }
    /// Discord rate-limits SET_ACTIVITY, so updates are spaced at least this far apart.
    static let minInterval: TimeInterval = 5

    struct State: Equatable, Sendable {
        var working: Bool
        var model: String
        var project: String?
        var taskStart: Date?
        /// The tool of the step running now (nil between steps), its summary, and whether the model is being waited on.
        var tool: String? = nil
        var summary: String = ""
        var thinking: Bool = false
        /// The owner's "include project names" setting. When false, nothing from the project reaches Discord.
        var showProject: Bool = false
    }

    /// What the profile says: the first line, the second line, and which status badge to show.
    struct Lines: Equatable, Sendable {
        var details: String
        var state: String
        var badge: String
    }

    /// The Discord application ID used for the handshake (changing it reconnects).
    var clientID = DiscordPresence.clientID

    /// Where to look for Discord's socket (tests point this at a fake one).
    var socketDirectories: [String] = {
        var dirs = [NSTemporaryDirectory(), "/tmp"]
        if let x = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"] { dirs.append(x) }
        return dirs
    }()

    private let queue = DispatchQueue(label: "anvil.discord-presence")
    private let appStart = Date()
    private var fd: Int32 = -1
    private var wanted: State?
    private var retry: DispatchWorkItem?
    private var throttle: DispatchWorkItem?
    private var lastSent: Date?

    // MARK: Public

    /// Shows this state, or removes the presence when nil (turned off, or quitting). `clientID` is the Discord application
    /// to show it under; a different one reconnects. Updates come at most every `minInterval` seconds; the newest state wins.
    func update(_ state: State?, clientID id: String = DiscordPresence.clientID) {
        queue.async { [self] in
            let wantedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
            let newID = wantedID.isEmpty ? Self.clientID : wantedID
            if newID != clientID { clientID = newID; close() }
            wanted = state
            throttle?.cancel()
            throttle = nil
            let wait = state == nil ? 0 : Self.throttleWait(now: Date(), last: lastSent)
            guard wait > 0 else { push(); return }
            let item = DispatchWorkItem { [weak self] in
                self?.throttle = nil
                self?.push()
            }
            throttle = item
            queue.asyncAfter(deadline: .now() + wait, execute: item)
        }
    }

    /// Clears the presence and closes the connection (blocks briefly so it happens before the app exits).
    func shutdown() {
        queue.sync { [self] in
            wanted = nil
            retry?.cancel()
            throttle?.cancel()
            throttle = nil
            if fd >= 0 { _ = send(opcode: 1, json: Self.activityCommand(nil, pid: ProcessInfo.processInfo.processIdentifier)); close() }
        }
    }

    // MARK: Pure decisions (tested directly)

    /// Seconds to wait before the next SET_ACTIVITY may go out (0 = send now).
    static func throttleWait(now: Date, last: Date?) -> TimeInterval {
        guard let last else { return 0 }
        return max(0, minInterval - now.timeIntervalSince(last))
    }

    /// The first line, the second line and the badge, from what the agent is doing.
    /// Without `showProject`, nothing from the project (file names, hosts, commands, folder) is used.
    static func lines(_ s: State) -> Lines {
        let working = s.working
        let badge = !working ? "idle" : (s.thinking ? "thinking" : "working")
        let project = s.showProject ? (s.project?.isEmpty == false ? s.project : nil) : nil
        let state: String
        if let project { state = "Workspace: \(project)" }
        else { state = working ? "Working on a task" : "Ready for the next task" }
        guard working else { return Lines(details: "Idling", state: state, badge: badge) }
        guard s.showProject else { return Lines(details: "Coding", state: state, badge: badge) }
        return Lines(details: details(tool: s.tool, summary: s.summary, thinking: s.thinking), state: state, badge: badge)
    }

    /// "Editing AppState.swift", "Running npm", "Browsing example.com", "Thinking" or "Coding" (project names on).
    static func details(tool: String?, summary: String, thinking: Bool) -> String {
        if thinking { return "Thinking" }
        guard let tool else { return "Coding" }
        switch tool {
        case "edit_file", "write_file", "replace_lines", "multi_edit":
            // Summaries read "Edit <path>" or "Write <path>"; anything else (several files, replace_lines) has no single name.
            for verb in ["Edit ", "Write "] where summary.hasPrefix(verb) {
                let rest = summary.dropFirst(verb.count).trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty, !rest.hasSuffix("files") {
                    return "Editing \((rest as NSString).lastPathComponent)"
                }
            }
            return "Editing a file"
        case "shell", "start_process":
            var command = summary
            if command.hasPrefix("$ ") { command = String(command.dropFirst(2)) }
            else if tool == "start_process", let colon = command.range(of: ": ") { command = String(command[colon.upperBound...]) }
            else { return "Running a command" }
            guard let first = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).first, !first.isEmpty else { return "Running a command" }
            return "Running \(first)"
        case _ where tool.hasPrefix("browser_") || tool == "fetch_url" || tool == "web_search":
            return "Browsing \(host(in: summary) ?? "the web")"
        default:
            return "Coding"
        }
    }

    /// The host of the first web address in a step summary, if any.
    static func host(in text: String) -> String? {
        guard let r = text.range(of: #"https?://([^/\s:?#"']+)"#, options: .regularExpression) else { return nil }
        let url = text[r]
        guard let host = URLComponents(string: String(url))?.host, !host.isEmpty else { return nil }
        return host
    }

    // MARK: Protocol

    /// Discord's frame: 4-byte opcode and 4-byte length (both little-endian), then JSON.
    static func frame(opcode: UInt32, json: [String: Any]) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        var d = Data()
        withUnsafeBytes(of: opcode.littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(body.count).littleEndian) { d.append(contentsOf: $0) }
        d.append(body)
        return d
    }

    static func activity(_ s: State, appStart: Date) -> [String: Any] {
        let lines = lines(s)
        return [
            "details": lines.details,
            "state": lines.state,
            "timestamps": ["start": Int((s.working ? (s.taskStart ?? appStart) : appStart).timeIntervalSince1970)],
            "assets": [
                "large_image": logoURL,
                "large_text": "Anvil \(AppInfo.version), a native macOS coding agent",
                "small_image": badgeURL(lines.badge),
                "small_text": s.model,
            ],
            "buttons": [["label": "Anvil on GitHub", "url": repoURL]],
        ]
    }

    static func activityCommand(_ activity: [String: Any]?, pid: Int32) -> [String: Any] {
        var args: [String: Any] = ["pid": Int(pid)]
        if let activity { args["activity"] = activity }
        return ["cmd": "SET_ACTIVITY", "args": args, "nonce": UUID().uuidString]
    }

    // MARK: Connection (all on `queue`)

    private func push() {
        retry?.cancel()
        lastSent = Date()
        guard let s = wanted else {
            if fd >= 0 { _ = send(opcode: 1, json: Self.activityCommand(nil, pid: ProcessInfo.processInfo.processIdentifier)) }
            return
        }
        if fd < 0, !connect() { scheduleRetry(); return }
        let command = Self.activityCommand(Self.activity(s, appStart: appStart), pid: ProcessInfo.processInfo.processIdentifier)
        if !send(opcode: 1, json: command) {
            close()
            if connect(), send(opcode: 1, json: command) { return }   // Discord restarted: one immediate retry
            close()
            scheduleRetry()
        }
    }

    private func scheduleRetry() {
        let item = DispatchWorkItem { [weak self] in self?.push() }
        retry = item
        queue.asyncAfter(deadline: .now() + 30, execute: item)
    }

    private func connect() -> Bool {
        for dir in socketDirectories {
            for i in 0..<10 {
                let path = (dir as NSString).appendingPathComponent("discord-ipc-\(i)")
                guard FileManager.default.fileExists(atPath: path), let s = openSocket(path) else { continue }
                fd = s
                let hello: [String: Any] = ["v": 1, "client_id": clientID]
                if send(opcode: 0, json: hello) { return true }
                close()
            }
        }
        return false
    }

    private func openSocket(_ path: String) -> Int32? {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { Darwin.close(s); return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
            buf[bytes.count] = 0
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { Darwin.close(s); return nil }
        return s
    }

    /// Sends a frame and reads Discord's reply (ready or acknowledgement). False when the connection is gone.
    private func send(opcode: UInt32, json: [String: Any]) -> Bool {
        guard fd >= 0 else { return false }
        let data = Self.frame(opcode: opcode, json: json)
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, data.count) }
        guard written == data.count else { return false }
        return readFrame() != nil
    }

    private func readFrame() -> (UInt32, Data)? {
        var header = [UInt8](repeating: 0, count: 8)
        guard readExactly(&header, 8) else { return nil }
        let op = header[0..<4].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
        let len = Int(header[4..<8].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) })
        guard len < 1_000_000 else { return nil }
        var body = [UInt8](repeating: 0, count: len)
        guard len == 0 || readExactly(&body, len) else { return nil }
        if op == 2 { return nil }   // Discord closed the connection
        return (op, Data(body))
    }

    private func readExactly(_ buf: inout [UInt8], _ n: Int) -> Bool {
        var got = 0
        while got < n {
            let r = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + got, n - got) }
            if r <= 0 { return false }
            got += r
        }
        return true
    }

    private func close() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
    }
}
