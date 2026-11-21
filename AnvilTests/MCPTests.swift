import XCTest
@testable import Anvil

/// A tiny Python MCP server over stdio (no network or npm needed).
final class MCPTests: XCTestCase {
    static let fakeServer = #"""
    import sys, json
    for line in sys.stdin:
        m = json.loads(line)
        if "id" not in m: continue
        meth = m["method"]
        if meth == "initialize": r = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}, "serverInfo": {"name": "fake", "version": "1"}}
        elif meth == "tools/list": r = {"tools": [{"name": "echo", "description": "Echo text back. Really.", "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}}]}
        elif meth == "tools/call": r = {"content": [{"type": "text", "text": "echo: " + m["params"]["arguments"]["text"]}]}
        else:
            print(json.dumps({"jsonrpc": "2.0", "id": m["id"], "error": {"code": -32601, "message": "nope"}}), flush=True); continue
        print("log noise on stdout", flush=True) if meth == "tools/list" else None
        print(json.dumps({"jsonrpc": "2.0", "id": m["id"], "result": r}), flush=True)
    """#

    func connect() async throws -> (MCPStdioClient, [ToolSpec]) {
        let client = MCPStdioClient(config: MCPServerConfig(name: "fake", command: "python3", args: ["-c", Self.fakeServer]))
        try client.start()
        let tools = try await MCPManager.handshake(client)
        return (client, tools.map { MCPManager.spec(server: "fake", tool: $0, client: client) })
    }

    func testHandshakeAndCatalogLine() async throws {
        let (client, specs) = try await connect()
        defer { client.stop() }
        XCTAssertEqual(specs.map(\.name), ["fake.echo"])
        XCTAssertEqual(specs[0].catalogLine, #"- fake.echo {"text": str}: Echo text back."#)
    }

    /// The agent calls an MCP tool end to end: catalog, permission check (exec asks in Ask mode), result in the observation.
    func testAgentCallsMCPTool() async throws {
        let (client, specs) = try await connect()
        defer { client.stop() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("anvil-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var sent: [[ChatMessage]] = []
        var replies = [
            "Calling it.\n```json\n{\"actions\": [{\"tool\": \"fake.echo\", \"args\": {\"text\": \"hi\"}}]}\n```",
            "```json\n{\"say\": \"It said hi.\", \"done\": true}\n```",
        ]
        let brain = Brain(client: OpenAIClient(baseURL: URL(string: "http://localhost:1")!, apiKey: ""), model: "m", visionModel: "", effort: "high", visionEffort: "low")
        brain.override = { h, _ in sent.append(h); return replies.removeFirst() }
        let host = TestHost()
        let agent = Agent(ctx: ToolContext(root: dir, processes: ProcessManager(), host: host), brain: brain, extraTools: specs)
        agent.mode = .bypass
        agent.autoVerify = false; agent.selfReview = false; agent.streaming = false; agent.memory = ProjectMemory()
        let out = await agent.run(goal: "echo hi")
        XCTAssertEqual(out.text, "It said hi.")
        XCTAssertTrue(sent[0][0].text.contains("[Connected tools (MCP servers)]"))
        XCTAssertTrue(sent[0][0].text.contains("- fake.echo"))
        XCTAssertTrue(sent[1].last!.text.contains("echo: hi"))
    }

    /// A server that connects after the conversation started: its tools are announced in the next observation.
    func testLateToolsAreAnnounced() async throws {
        let (client, specs) = try await connect()
        defer { client.stop() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("anvil-mcp2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var sent: [[ChatMessage]] = []
        var replies = [
            "```json\n{\"actions\": [{\"tool\": \"list_dir\", \"args\": {}}]}\n```",
            "```json\n{\"actions\": [{\"tool\": \"fake.echo\", \"args\": {\"text\": \"late\"}}]}\n```",
            "```json\n{\"say\": \"done\", \"done\": true}\n```",
        ]
        let brain = Brain(client: OpenAIClient(baseURL: URL(string: "http://localhost:1")!, apiKey: ""), model: "m", visionModel: "", effort: "high", visionEffort: "low")
        brain.override = { h, _ in sent.append(h); return replies.removeFirst() }
        let agent = Agent(ctx: ToolContext(root: dir, processes: ProcessManager(), host: TestHost()), brain: brain)
        agent.mode = .bypass
        agent.autoVerify = false; agent.selfReview = false; agent.streaming = false; agent.memory = ProjectMemory()
        var available: [ToolSpec] = []
        agent.toolProvider = { available }
        brain.override = { h, _ in
            sent.append(h)
            available = specs   // the server finishes connecting during the first step
            return replies.removeFirst()
        }
        _ = await agent.run(goal: "x")
        XCTAssertFalse(sent[0][0].text.contains("fake.echo"))
        XCTAssertTrue(sent[1].last!.text.contains("NEW TOOLS AVAILABLE NOW"))
        XCTAssertTrue(sent[2].last!.text.contains("echo: late"))
    }

    func testConfigSourcesMergeWithPriority() throws {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("anvil-mcpcfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        try #"{"mcpServers": {"proj-only": {"command": "echo"}, "shared": {"command": "from-project"}}}"#
            .write(to: project.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
        try MCPConfigFile.upsert(name: "shared", command: "from-anvil", args: [], env: [:])
        defer { _ = try? MCPConfigFile.remove(name: "shared") }
        let (configs, _) = MCPManager.loadConfigs(project: project)
        let byName = Dictionary(configs.map { ($0.0.name, $0) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(byName["shared"]?.0.command, "from-anvil", "Anvil's own file wins")
        XCTAssertEqual(byName["shared"]?.1, "Anvil")
        XCTAssertEqual(byName["proj-only"]?.1, "project .mcp.json")
        XCTAssertEqual(MCPManager.sources(project: project).map(\.label), ["Anvil", "project .mcp.json", "Peep", "Claude Desktop", "Claude Code"])
    }

    func testAddMCPServerToolIsAnExecWithItsCommand() throws {
        let dir = FileManager.default.temporaryDirectory
        let agent = Agent(ctx: ToolContext(root: dir, processes: ProcessManager(), host: nil),
                          brain: Brain(client: OpenAIClient(baseURL: URL(string: "http://localhost:1")!, apiKey: ""), model: "m", visionModel: "", effort: "", visionEffort: ""))
        let spec = try XCTUnwrap(agent.tools["add_mcp_server"])
        XCTAssertEqual(spec.kind, .exec)
        XCTAssertEqual(spec.command?(.object(["command": .string("npx"), "args": .array([.string("-y"), .string("pkg")])])), "npx -y pkg")
        XCTAssertNotNil(agent.tools["list_mcp_servers"])
    }
}

final class FileWatcherTests: XCTestCase {
    func testReportsChangesButNotGitChurn() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("anvil-watch-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var hits = 0
        let w = FileWatcher(path: dir.path) { hits += 1 }
        XCTAssertNotNil(w)
        try await Task.sleep(for: .milliseconds(400))
        try "x".write(to: dir.appendingPathComponent(".git/index"), atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(hits, 0, ".git churn is ignored")
        try "x".write(to: dir.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        for _ in 0..<20 where hits == 0 { try await Task.sleep(for: .milliseconds(150)) }
        XCTAssertGreaterThan(hits, 0)
        w?.stop()
    }
}
