import XCTest
#if SWIFT_PACKAGE
@testable import AnvilCore
#else
@testable import Anvil
#endif

final class SimulatorTests: XCTestCase {
    func testParseDevices() {
        let json = #"{"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-27-0": [{"udid": "A", "name": "iPhone 17 Pro", "state": "Shutdown"}, {"udid": "B", "name": "iPhone 17", "state": "Booted"}]}}"#
        let d = Sim.parseDevices(json)
        XCTAssertEqual(d.map(\.name), ["iPhone 17", "iPhone 17 Pro"], "booted first")
        XCTAssertEqual(d[0].runtime, "iOS 27 0")
    }

    func testParseAXeElementsBothFrameShapes() {
        let json = #"""
        [{"type": "Application", "AXLabel": "Notes", "frame": {"x": 0, "y": 0, "width": 402, "height": 874}, "children": [
           {"type": "Button", "AXLabel": "New Note", "AXUniqueId": "new", "frame": {"x": 340, "y": 60, "width": 44, "height": 44}, "children": []},
           {"type": "TextField", "AXLabel": "Search", "AXValue": "", "AXFrame": "{{16, 120}, {370, 36}}", "children": []},
           {"type": "Other", "frame": {"x": 0, "y": 0, "width": 10, "height": 10}}
        ]}]
        """#
        let els = Sim.parseElements(json)
        XCTAssertEqual(els.map(\.label), ["Notes", "New Note", "Search"], "unlabelled containers are skipped")
        XCTAssertEqual(els[1].frame.midX, 362)
        XCTAssertEqual(els[2].frame, CGRect(x: 16, y: 120, width: 370, height: 36))
        let text = Sim.describe(els)
        XCTAssertTrue(text.contains("[2] Button \"New Note\" #new @362,82"), text)
    }

    func testSimulatorToolsRegisteredAndTapNeedsDescribe() async {
        let brain = Brain(client: OpenAIClient(baseURL: URL(string: "http://localhost:1")!, apiKey: ""), model: "m", visionModel: "", effort: "", visionEffort: "")
        let agent = Agent(ctx: ToolContext(root: URL(fileURLWithPath: "/tmp"), processes: ProcessManager(), host: nil), brain: brain)
        XCTAssertNotNil(agent.tools["sim_describe"])
        XCTAssertNotNil(agent.tools["sim_screenshot"])
        XCTAssertTrue(agent.catalog.contains("[iOS Simulator]"))
    }
}

final class ResumedSessionTests: XCTestCase {
    /// A conversation from before the browser tools existed learns about them on its next request.
    func testNewToolsAreAnnouncedToOldConversations() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("anvil-resume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var sent: [[ChatMessage]] = []
        let brain = Brain(client: OpenAIClient(baseURL: URL(string: "http://localhost:1")!, apiKey: ""), model: "m", visionModel: "", effort: "high", visionEffort: "low")
        brain.override = { h, _ in sent.append(h); return "```json\n{\"say\": \"ok\", \"done\": true}\n```" }
        let ctx = ToolContext(root: dir, processes: ProcessManager(), host: TestHost())
        ctx.browser = BrowserController()
        let agent = Agent(ctx: ctx, brain: brain)
        agent.judgeEnabled = false
        agent.autoVerify = false; agent.selfReview = false; agent.streaming = false; agent.prepareWhilePlanning = false; agent.memory = ProjectMemory()
        // An old briefing that only listed read_file and shell.
        agent.briefing = "You are Anvil...\nACTIONS\n[Files]\n- read_file {\"path\": str}: read\n- shell {\"command\": str}: run\n"
        agent.messages = [.user(agent.briefing + "OWNER'S REQUEST\nmake a site"), .assistant("```json\n{\"say\": \"made\", \"done\": true}\n```")]
        _ = await agent.run(goal: "audit the site in the browser")
        let turn = sent[0].last!.text
        XCTAssertTrue(turn.contains("NEW TOOLS AVAILABLE NOW"), turn)
        XCTAssertTrue(turn.contains("- browser_open"))
        XCTAssertFalse(turn.contains("- read_file {"), "already-known tools aren't repeated")
        // Next request: nothing new to announce.
        _ = await agent.run(goal: "again")
        XCTAssertFalse(sent[1].last!.text.contains("NEW TOOLS AVAILABLE NOW"))
    }
}

final class BrowserActionTests: XCTestCase {
    func testConsoleSelectKeyWaitViewport() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("anvil-b2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let page = dir.appendingPathComponent("p.html")
        try """
        <html><body>
        <select id="s"><option value="a">Apple</option><option value="b">Banana</option></select>
        <input id="q" onkeydown="if (event.key === 'Enter') setTimeout(() => { document.getElementById('r').textContent = 'searched ' + this.value }, 300)">
        <p id="r"></p>
        <script>console.error('boom happened'); setTimeout(() => { undefinedFunction() }, 10)</script>
        </body></html>
        """.write(to: page, atomically: true, encoding: .utf8)
        let b = BrowserController()
        _ = await b.open(page.path)
        try await Task.sleep(for: .milliseconds(200))
        let ctx = ToolContext(root: dir, processes: ProcessManager(), host: nil)
        ctx.browser = b
        let read = try await b.readPage()
        XCTAssertTrue(read.contains("console: 2 error(s)"), String(read.prefix(400)).replacingOccurrences(of: "\n", with: " | "))
        let log = try await b.console()
        XCTAssertTrue(log.contains("error: boom happened"), log)
        XCTAssertTrue(log.contains("uncaught"), log)
        let sel = try await BrowserTools.select.run!(.object(["id": .number(1), "value": .string("Banana")]), ctx)
        XCTAssertEqual(sel.output, "selected Banana")
        _ = try await b.type(2, text: "graveyard", submit: false)
        _ = try await BrowserTools.key.run!(.object(["key": .string("Enter"), "id": .number(2)]), ctx)
        let waited = try await BrowserTools.wait.run!(.object(["text": .string("searched graveyard"), "timeout": .number(5)]), ctx)
        XCTAssertTrue(waited.ok, waited.output)
        XCTAssertTrue(b.setViewport(width: 390, height: 844).contains("390x844"))
        XCTAssertEqual(b.viewportWidth, 390)
        _ = b.setViewport(width: nil, height: nil)
        XCTAssertNil(b.viewportWidth)
    }
}

final class TerminalAndAwakeTests: XCTestCase {
    func testTerminalTabs() {
        let t = TerminalStore()
        XCTAssertEqual(t.tabs.map(\.title), ["Agent"])
        t.agentCommand("npm test")
        t.agentOutput("ok\n")
        t.newShell()
        XCTAssertEqual(t.tabs.count, 2)
        let shell = t.tabs[1]
        XCTAssertEqual(shell.kind, .shell)
        _ = t.view(for: shell, cwd: FileManager.default.temporaryDirectory)
        t.close(shell.id)
        XCTAssertEqual(t.tabs.count, 1)
        t.close(t.agentTab.id)
        XCTAssertEqual(t.tabs.count, 1, "the agent tab can't be closed")
    }

    func testBackgroundProcessGetsATab() throws {
        let pm = ProcessManager()
        let e = try pm.start(name: "web", command: "echo hello; sleep 2", cwd: FileManager.default.temporaryDirectory)
        e.output.append("hello\n")
        let t = TerminalStore()
        t.syncProcesses(pm.entries)
        XCTAssertTrue(t.tabs.contains { $0.kind == .process("web") })
        pm.stopAll()
    }

    func testKeepAwakeFollowsWork() {
        let was = AppSettings.shared.keepAwake
        AppSettings.shared.keepAwake = true
        defer { AppSettings.shared.keepAwake = was; KeepAwake.shared.update(working: false) }
        KeepAwake.shared.update(working: true)
        XCTAssertTrue(KeepAwake.shared.held)
        KeepAwake.shared.update(working: false)
        XCTAssertFalse(KeepAwake.shared.held)
    }
}
