import Foundation

/// Discord Rich Presence: shows "Working on a task · model" on your Discord profile, with a button to the repo.
/// It speaks Discord's local IPC protocol (a Unix socket the Discord app opens in the temp folder), so nothing
/// leaves your Mac except what Discord itself shows. It does nothing when Discord isn't running and retries quietly.
///
/// The project name is only shown when the owner turns that on.
nonisolated final class DiscordPresence: @unchecked Sendable {
    static let shared = DiscordPresence()
    /// The Discord application the presence belongs to (its name and art come from the Developer Portal).
    static let clientID = "918234595579805776"
    static let repoURL = "https://github.com/deeeeone/Anvil"
    /// The large image: a public URL, so no art has to be uploaded to the Developer Portal. It loads once the repo is public.
    static let logoURL = "https://raw.githubusercontent.com/deeeeone/Anvil/main/design/anvil-icon-1024.png"

    struct State: Equatable, Sendable {
        var working: Bool
        var model: String
        var project: String?
        var taskStart: Date?
    }

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

    // MARK: Public

    /// Shows this state, or removes the presence when nil (turned off, or quitting).
    func update(_ state: State?) {
        queue.async { [self] in
            wanted = state
            push()
        }
    }

    /// Clears the presence and closes the connection (blocks briefly so it happens before the app exits).
    func shutdown() {
        queue.sync { [self] in
            wanted = nil
            retry?.cancel()
            if fd >= 0 { _ = send(opcode: 1, json: Self.activityCommand(nil, pid: ProcessInfo.processInfo.processIdentifier)); close() }
        }
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

    static func activity(_ s: State, appStart: Date, showProject: Bool = true) -> [String: Any] {
        var state = s.model
        if showProject, let p = s.project, !p.isEmpty { state += " · \(p)" }
        var a: [String: Any] = [
            "details": s.working ? "Working on a task" : "Ready for the next task",
            "state": state,
            "timestamps": ["start": Int((s.working ? (s.taskStart ?? appStart) : appStart).timeIntervalSince1970)],
            "assets": ["large_image": logoURL, "large_text": "Anvil, a native macOS coding agent"],
            "buttons": [["label": "Anvil on GitHub", "url": repoURL]],
        ]
        if s.working { a["assets"] = ["large_image": logoURL, "large_text": "Anvil, a native macOS coding agent"] }
        return a
    }

    static func activityCommand(_ activity: [String: Any]?, pid: Int32) -> [String: Any] {
        var args: [String: Any] = ["pid": Int(pid)]
        if let activity { args["activity"] = activity }
        return ["cmd": "SET_ACTIVITY", "args": args, "nonce": UUID().uuidString]
    }

    // MARK: Connection (all on `queue`)

    private func push() {
        retry?.cancel()
        guard let s = wanted else {
            if fd >= 0 { _ = send(opcode: 1, json: Self.activityCommand(nil, pid: ProcessInfo.processInfo.processIdentifier)) }
            return
        }
        if fd < 0, !connect() { scheduleRetry(); return }
        let command = Self.activityCommand(Self.activity(s, appStart: appStart, showProject: true), pid: ProcessInfo.processInfo.processIdentifier)
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
                let hello: [String: Any] = ["v": 1, "client_id": Self.clientID]
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
