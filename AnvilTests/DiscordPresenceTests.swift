import XCTest
@testable import Anvil

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
        let a = DiscordPresence.activity(.init(working: true, model: "glm-5.3", project: "secret-app", taskStart: Date(timeIntervalSince1970: 2_000)), appStart: start)
        XCTAssertEqual(a["details"] as? String, "Working on a task")
        XCTAssertEqual(a["state"] as? String, "glm-5.3 · secret-app")
        XCTAssertEqual((a["timestamps"] as? [String: Int])?["start"], 2_000)
        let button = (a["buttons"] as? [[String: String]])?.first
        XCTAssertEqual(button?["url"], "https://github.com/deeeeone/Anvil")
        let idle = DiscordPresence.activity(.init(working: false, model: "glm-5.3", project: nil, taskStart: nil), appStart: start)
        XCTAssertEqual(idle["state"] as? String, "glm-5.3", "no project name unless given")
        XCTAssertEqual((idle["timestamps"] as? [String: Int])?["start"], 1_000)
    }

    /// A fake Discord: accepts the handshake, answers READY, records the activity it's sent, answers again.
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
        XCTAssertEqual(second[1]?["args"]?["activity"]?["details"]?.string, "Working on a task")
        let last = try XCTUnwrap(JSON.parse(lines.last!))
        XCTAssertNil(last[1]?["args"]?["activity"], "shutdown clears the presence")
    }

    func testNoDiscordIsHarmless() {
        let presence = DiscordPresence()
        presence.socketDirectories = ["/tmp/definitely-not-here-\(UUID().uuidString)"]
        presence.update(.init(working: true, model: "m", project: nil, taskStart: nil))
        presence.shutdown()   // must neither crash nor hang
    }
}
