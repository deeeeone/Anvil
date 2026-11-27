import XCTest
#if SWIFT_PACKAGE
@testable import AnvilCore
#else
@testable import Anvil
#endif

final class DiscordPresenceTests: XCTestCase {
    func testFrameLayout() {
        let d = DiscordPresence.frame(opcode: 1, json: ["a": 1])
        XCTAssertEqual(Array(d.prefix(4)), [1, 0, 0, 0], "opcode, little-endian")
        let len = Int(d[4]) | Int(d[5]) << 8
        XCTAssertEqual(len, d.count - 8)
        XCTAssertEqual(String(decoding: d.dropFirst(8), as: UTF8.self), "{\"a\":1}")
    }

    func testActivityContent() {
        let start = Date(timeIntervalSince1970: 1_000)
        let a = DiscordPresence.activity(.init(working: true, model: "glm-5.3", project: "secret-app", taskStart: Date(timeIntervalSince1970: 2_000), tool: "edit_file", summary: "Edit Sources/App.swift", showProject: true), appStart: start)
        XCTAssertEqual(a["details"] as? String, "Editing App.swift")
        XCTAssertEqual(a["state"] as? String, "Workspace: secret-app")
        XCTAssertEqual((a["timestamps"] as? [String: Int])?["start"], 2_000)
        let button = (a["buttons"] as? [[String: String]])?.first
        XCTAssertEqual(button?["url"], "https://github.com/heurica-labs/anvil")
        let assets = a["assets"] as? [String: String]
        XCTAssertEqual(assets?["large_image"], DiscordPresence.logoURL)
        XCTAssertEqual(assets?["small_image"], "https://raw.githubusercontent.com/heurica-labs/anvil/main/design/presence/working.png")
        XCTAssertEqual(assets?["small_text"], "glm-5.3")
        XCTAssertTrue(assets?["large_text"]?.hasPrefix("Anvil ") == true)
        let idle = DiscordPresence.activity(.init(working: false, model: "glm-5.3", project: nil, taskStart: nil), appStart: start)
        XCTAssertEqual(idle["details"] as? String, "Idling")
        XCTAssertEqual(idle["state"] as? String, "Ready for the next task")
        XCTAssertEqual((idle["timestamps"] as? [String: Int])?["start"], 1_000)
        XCTAssertEqual((idle["assets"] as? [String: String])?["small_image"], "https://raw.githubusercontent.com/heurica-labs/anvil/main/design/presence/idle.png")
    }

    func testDetailsPerToolKind() {
        func d(_ tool: String?, _ summary: String, thinking: Bool = false) -> String {
            DiscordPresence.details(tool: tool, summary: summary, thinking: thinking)
        }
        XCTAssertEqual(d("edit_file", "Edit Sources/Deep/AppState.swift"), "Editing AppState.swift")
        XCTAssertEqual(d("write_file", "Write notes/new file.md"), "Editing new file.md")
        XCTAssertEqual(d("multi_edit", "Edit 3 files"), "Editing a file")
        XCTAssertEqual(d("replace_lines", "replace_lines {\"path\":\"a.swift\"}"), "Editing a file")
        XCTAssertEqual(d("shell", "$ npm run build --silent"), "Running npm")
        XCTAssertEqual(d("start_process", "Start dev: npm run dev"), "Running npm")
        XCTAssertEqual(d("shell", "Verify: swift test"), "Running a command")
        XCTAssertEqual(d("browser_open", "Open https://docs.example.com/page?x=1"), "Browsing docs.example.com")
        XCTAssertEqual(d("browser_read", "Read the page"), "Browsing the web")
        XCTAssertEqual(d("fetch_url", "Fetch https://example.org/a"), "Browsing example.org")
        XCTAssertEqual(d("read_file", "Read Sources/A.swift"), "Coding")
        XCTAssertEqual(d("edit_file", "Edit a.swift", thinking: true), "Thinking")
        XCTAssertEqual(d(nil, ""), "Coding")
    }

    func testPrivacyOffHidesEverything() {
        let working = DiscordPresence.State(working: true, model: "m", project: "secret-app", taskStart: nil,
                                            tool: "shell", summary: "$ curl -H token=abc https://private.example.com", showProject: false)
        let lines = DiscordPresence.lines(working)
        XCTAssertEqual(lines.details, "Coding")
        XCTAssertEqual(lines.state, "Working on a task")
        let all = [lines.details, lines.state].joined(separator: " ")
        for secret in ["secret-app", "curl", "private.example.com", "token"] {
            XCTAssertFalse(all.contains(secret), secret)
        }
        let idle = DiscordPresence.lines(.init(working: false, model: "m", project: "secret-app", taskStart: nil, showProject: false))
        XCTAssertEqual(idle.details, "Idling")
        XCTAssertEqual(idle.state, "Ready for the next task")
    }

    func testLinesWithProjectOn() {
        let edit = DiscordPresence.lines(.init(working: true, model: "m", project: "ad-platform", taskStart: nil, tool: "edit_file", summary: "Edit docs/AGENT_FEATURES.md", showProject: true))
        XCTAssertEqual(edit.details, "Editing AGENT_FEATURES.md")
        XCTAssertEqual(edit.state, "Workspace: ad-platform")
        XCTAssertEqual(edit.badge, "working")
        let thinking = DiscordPresence.lines(.init(working: true, model: "m", project: "ad-platform", taskStart: nil, thinking: true, showProject: true))
        XCTAssertEqual(thinking.details, "Thinking")
        XCTAssertEqual(thinking.badge, "thinking")
        let idle = DiscordPresence.lines(.init(working: false, model: "m", project: "ad-platform", taskStart: nil, showProject: true))
        XCTAssertEqual(idle.details, "Idling")
        XCTAssertEqual(idle.state, "Workspace: ad-platform")
        XCTAssertEqual(idle.badge, "idle")
    }

    func testThrottleSpacesUpdates() {
        let t0 = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(DiscordPresence.throttleWait(now: t0, last: nil), 0, "first update goes out now")
        XCTAssertEqual(DiscordPresence.throttleWait(now: t0, last: t0.addingTimeInterval(-5)), 0, "5 s after the last one is allowed")
        XCTAssertEqual(DiscordPresence.throttleWait(now: t0, last: t0.addingTimeInterval(-2)), 3, accuracy: 0.001)
        XCTAssertEqual(DiscordPresence.throttleWait(now: t0, last: t0.addingTimeInterval(-60)), 0)
    }

    /// A fake Discord: accepts the handshake, answers READY, records the activity it's sent, answers again.
#if canImport(Darwin) // TODO(linux): DiscordPresence talks over a Unix socket only on Darwin; the Linux socket layer is not ported yet.
    func testTalksToAFakeDiscord() throws {
        let dir = URL(fileURLWithPath: "/tmp/dp-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("log.jsonl")
        let script = dir.appendingPathComponent("fake.py")
        try """
        import socket, struct, json, os, sys
        d = sys.argv[1]
        p = os.path.join(d, "discord-ipc-0")
        s = socket.socket(socket.AF_UNIX); s.bind(p); s.listen(1)
        open(os.path.join(d, "ready"), "w").write("1")
        c, _ = s.accept()
        def read():
            h = c.recv(8, socket.MSG_WAITALL)
            if len(h) < 8: return None
            op, n = struct.unpack("<II", h)
            return op, json.loads(c.recv(n, socket.MSG_WAITALL))
        def write(op, obj):
            b = json.dumps(obj).encode(); c.sendall(struct.pack("<II", op, len(b)) + b)
        log = open(os.path.join(d, "log.jsonl"), "a")
        for _ in range(4):
            m = read()
            if m is None: break
            log.write(json.dumps(m) + "\\n"); log.flush()
            write(1, {"cmd": "SET_ACTIVITY", "data": {}, "evt": None, "nonce": m[1].get("nonce")} if m[0] == 1 else {"cmd": "DISPATCH", "evt": "READY"})
        """.write(to: dir.appendingPathComponent("fake.py"), atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", script.path, dir.path]
        try p.run()
        defer { p.terminate() }
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: dir.appendingPathComponent("ready").path) { Thread.sleep(forTimeInterval: 0.1) }

        let presence = DiscordPresence()
        presence.socketDirectories = [dir.path]
        presence.update(.init(working: true, model: "glm-5.3", project: nil, taskStart: Date()))
        presence.update(.init(working: false, model: "glm-5.3", project: nil, taskStart: nil))
        presence.shutdown()

        var lines: [String] = []
        for _ in 0..<50 {
            lines = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            if lines.count >= 4 { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertGreaterThanOrEqual(lines.count, 3, "\(lines)")
        let first = try XCTUnwrap(JSON.parse(lines[0]))
        XCTAssertEqual(first[0]?.int, 0, "handshake first")
        XCTAssertEqual(first[1]?["client_id"]?.string, "918234595579805776")
        let second = try XCTUnwrap(JSON.parse(lines[1]))
        XCTAssertEqual(second[0]?.int, 1)
        XCTAssertEqual(second[1]?["cmd"]?.string, "SET_ACTIVITY")
        XCTAssertEqual(second[1]?["args"]?["activity"]?["details"]?.string, "Coding")
        let last = try XCTUnwrap(JSON.parse(lines.last!))
        XCTAssertNil(last[1]?["args"]?["activity"], "shutdown clears the presence")
    }
#endif

    func testNoDiscordIsHarmless() {
        let presence = DiscordPresence()
        presence.socketDirectories = ["/tmp/definitely-not-here-\(UUID().uuidString)"]
        presence.update(.init(working: true, model: "m", project: nil, taskStart: nil))
        presence.shutdown()   // must neither crash nor hang
    }
}
