import XCTest
@testable import Anvil

/// The provider standard: anvil-provider.json, presets, installing, and both plugin kinds end to end.
final class ProviderPluginTests: XCTestCase {
    private var savedRoot: URL!
    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("anvil-plugins-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        savedRoot = ProviderPlugins.shared.root
        ProviderPlugins.shared.root = tmp
        ProviderPlugins.shared.reload()
    }

    override func tearDown() async throws {
        for p in ProviderPlugins.shared.installed { ProviderPlugins.shared.remove(p.id) }
        ProviderPlugins.shared.root = savedRoot
        ProviderPlugins.shared.reload()
        try? FileManager.default.removeItem(at: tmp)
    }

    private var repoRoot: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    private func spec(_ json: String) throws -> ProviderSpec {
        try JSONDecoder().decode(ProviderSpec.self, from: Data(json.utf8))
    }

    // MARK: Spec

    func testPresetsAndExamplesAreValid() throws {
        let folders = ["Anvil/Providers/Presets"]
        var count = 0
        for f in folders {
            for url in try FileManager.default.contentsOfDirectory(at: repoRoot.appendingPathComponent(f), includingPropertiesForKeys: nil) where url.pathExtension == "json" {
                let s = try ProviderSpec.load(url)
                XCTAssertEqual(s.problems(), [], url.lastPathComponent)
                count += 1
            }
        }
        XCTAssertGreaterThanOrEqual(count, 8)
        for example in ["zai", "process-template", "website-template"] {
            let s = try ProviderSpec.load(repoRoot.appendingPathComponent("examples/providers/\(example)/anvil-provider.json"))
            XCTAssertEqual(s.problems(), [], example)
        }
    }

    func testValidationExplainsMistakes() throws {
        let bad = try spec(#"{"spec": 1, "id": "ChatGPT", "name": "", "type": "openai", "baseURL": "http://api.example.com", "auth": {"type": "web"}}"#)
        let p = bad.problems().joined(separator: "\n")
        XCTAssertTrue(p.contains("lowercase"), p)
        XCTAssertTrue(p.contains("name is empty"), p)
        XCTAssertTrue(p.contains("https"), p)
        XCTAssertTrue(p.contains("loginURL"), p)
        XCTAssertTrue(try spec(#"{"spec":1,"id":"chatgpt","name":"x","type":"process","command":["x"],"auth":{"type":"none"}}"#).problems().joined().contains("reserved"))
        XCTAssertEqual(try spec(#"{"spec":1,"id":"local-llm","name":"x","type":"openai","baseURL":"http://localhost:8080/v1","auth":{"type":"none"}}"#).problems(), [],
                       "plain http is fine for localhost")
        XCTAssertTrue(try spec(#"{"spec":2,"id":"future","name":"x","type":"process","command":["x"],"auth":{"type":"none"}}"#).problems().joined().contains("Update Anvil"))
    }

    func testMissingFieldErrorNamesTheField() throws {
        let f = tmp.appendingPathComponent("bad/anvil-provider.json")
        try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"spec": 1, "id": "x1", "type": "openai", "auth": {"type": "none"}}"#.write(to: f, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ProviderSpec.load(f)) { e in
            XCTAssertTrue((e as? ToolFailure)?.message.contains("\"name\"") ?? false, "\(e)")
        }
    }

    func testEndpointFromSpec() throws {
        let s = try spec(#"{"spec":1,"id":"k","name":"K","type":"openai","baseURL":"https://x.dev/v4","chatPath":"/api/chat","headers":{"X-App":"anvil"},"auth":{"type":"apiKey","header":"x-api-key"},"capabilities":{"stop":false,"maxTokensField":"max_completion_tokens"}}"#)
        let e = s.endpoint()
        XCTAssertEqual(e.chatPath, "api/chat")
        XCTAssertEqual(e.authHeader, "x-api-key")
        XCTAssertEqual(e.authPrefix, "", "custom headers carry the bare key")
        XCTAssertFalse(e.sendsStop)
        XCTAssertFalse(e.sendsEffort)
        XCTAssertEqual(e.maxTokensField, "max_completion_tokens")
        XCTAssertEqual(e.headers["X-App"], "anvil")
    }

    func testGitHubSources() {
        XCTAssertEqual(GitHubSource("https://github.com/acme/anvil-zai")?.cloneURL, "https://github.com/acme/anvil-zai.git")
        let deep = GitHubSource("github.com/acme/plugins/tree/v2/providers/zai-web")
        XCTAssertEqual(deep?.ref, "v2")
        XCTAssertEqual(deep?.path, "providers/zai-web")
        XCTAssertEqual(GitHubSource("https://github.com/acme/plugins/blob/main/zai/anvil-provider.json")?.path, "zai")
        XCTAssertNil(GitHubSource("https://gitlab.com/acme/x"))
        XCTAssertNil(GitHubSource("https://github.com/acme"))
        XCTAssertNil(GitHubSource("https://github.com/acme/x/tree/main/../../etc"))
        XCTAssertNil(GitHubSource("https://github.com/acme/x/tree/--upload-pack=evil"))
    }

    // MARK: Installing and routing

    func testInstallRouteAndRemove() throws {
        // A fetched plugin (as if cloned from GitHub) is copied in on confirm.
        let fetched = FileManager.default.temporaryDirectory.appendingPathComponent("anvil-provider-test-\(UUID().uuidString.prefix(6))")
        try FileManager.default.copyItem(at: repoRoot.appendingPathComponent("examples/providers/zai"), to: fetched)
        let spec = try ProviderSpec.load(fetched.appendingPathComponent(ProviderSpec.fileName))
        let pending = PendingProvider(spec: spec, folder: fetched, source: "github.com/acme/zai @ abc1234", commit: "abc1234", linked: false, replaces: false)
        XCTAssertTrue(pending.summary.first?.contains("api.z.ai") ?? false, "\(pending.summary)")
        try ProviderPlugins.shared.confirm(pending)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fetched.path), "the download is cleaned up")

        let store = ProviderPlugins.shared
        let installed = try XCTUnwrap(store.provider("zai"))
        XCTAssertTrue(installed.fromGitHub)
        XCTAssertEqual(store.route("zai/glm-4.6")?.model, "glm-4.6")
        XCTAssertNil(store.route("chatgpt/auto"), "built-in models aren't plugins")
        XCTAssertNil(store.route("glm-5.3-flash"))
        XCTAssertFalse(store.isReady("zai"), "needs a key")
        XCTAssertFalse(AppSettings.shared.ready(model: "zai/glm-4.6"))
        XCTAssertEqual(store.modelInfo("zai/glm-4.5v")?.vision, true)
        XCTAssertTrue(ModelCatalog.shared.choices.contains { $0.id == "zai/glm-4.6" && $0.plugin == "zai" })

        store.remove("zai")
        XCTAssertNil(store.provider("zai"))
        XCTAssertNil(store.route("zai/glm-4.6"))
    }

    func testLinkedFolderAndProcessProtocol() async throws {
        let folder = repoRoot.appendingPathComponent("examples/providers/process-template")
        let pending = try ProviderPlugins.shared.inspect(folder: folder)
        XCTAssertTrue(pending.summary.joined().contains("python3 provider.py"), "the confirmation shows the command")
        try ProviderPlugins.shared.confirm(pending)
        let p = try XCTUnwrap(ProviderPlugins.shared.provider("echo"))
        XCTAssertTrue(p.linked)
        XCTAssertTrue(ProviderPlugins.shared.isReady("echo"))

        let models = try await ProviderClient(p).listModels()
        XCTAssertEqual(models.map(\.id), ["echo-1"])

        var streamed = ""
        let (text, usage) = try await ProviderClient(p).chat([.user("fix the bug\nplease")], model: "echo-1", images: false, effort: nil,
                                                             stop: nil, maxTokens: nil, onText: { streamed = $0 }, shouldStop: { _ in false })
        XCTAssertTrue(text.contains("Echo from echo-1: please"), text)
        XCTAssertEqual(streamed, text)
        XCTAssertNotNil(usage)
    }

    func testAgentRunsOnAProcessPlugin() async throws {
        try ProviderPlugins.shared.confirm(try ProviderPlugins.shared.inspect(folder: repoRoot.appendingPathComponent("examples/providers/process-template")))
        let brain = try Brain.fromSettings(model: "echo/echo-1")
        let dir = tmp.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let agent = Agent(ctx: ToolContext(root: dir, processes: ProcessManager(), host: nil), brain: brain)
        agent.autoVerify = false
        agent.selfReview = false
        let out = await agent.run(goal: "say hi")
        XCTAssertTrue(out.ok, out.text)
        XCTAssertTrue(out.text.contains("Echo from echo-1"), out.text)
    }

    func testProcessErrorsBecomeBrainErrors() async throws {
        let folder = tmp.appendingPathComponent("src/fails")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #"{"spec":1,"id":"fails","name":"Fails","type":"process","command":["python3","p.py"],"auth":{"type":"none"},"models":[{"id":"m"}]}"#
            .write(to: folder.appendingPathComponent(ProviderSpec.fileName), atomically: true, encoding: .utf8)
        try """
        import json, sys
        sys.stdin.readline()
        print(json.dumps({"type": "error", "code": "rate_limited", "message": "slow down"}))
        """.write(to: folder.appendingPathComponent("p.py"), atomically: true, encoding: .utf8)
        try ProviderPlugins.shared.confirm(try ProviderPlugins.shared.inspect(folder: folder))
        let p = try XCTUnwrap(ProviderPlugins.shared.provider("fails"))
        do {
            _ = try await ProviderClient(p).chat([.user("x")], model: "m", images: false, effort: nil, stop: nil, maxTokens: nil, onText: nil, shouldStop: { _ in false })
            XCTFail("expected an error")
        } catch let e as BrainError {
            XCTAssertEqual(e.code, "server_busy", "rate limits are retried like other providers' 429s")
            XCTAssertTrue(e.message.contains("slow down"))
        }
    }

    // MARK: "openai" plugins against a local server

    /// A tiny OpenAI-shaped server that checks the path, the auth header and the body it receives.
    private func startMockServer() throws -> (Process, Int, URL) {
        let port = Int.random(in: 20000...40000)
        let log = tmp.appendingPathComponent("requests.jsonl")
        let script = tmp.appendingPathComponent("server.py")
        try """
        import json, sys
        from http.server import BaseHTTPRequestHandler, HTTPServer
        LOG = sys.argv[2]
        class H(BaseHTTPRequestHandler):
            def log_message(self, *a): pass
            def reply(self, code, obj):
                b = json.dumps(obj).encode(); self.send_response(code); self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
            def do_GET(self):
                if self.path == "/v4/models" and self.headers.get("x-api-key") == "secret":
                    return self.reply(200, {"data": [{"id": "kimi-1"}, {"id": "kimi-2"}]})
                self.reply(401, {"error": {"message": "bad key"}})
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                open(LOG, "a").write(json.dumps({"path": self.path, "key": self.headers.get("x-api-key"), "app": self.headers.get("X-App"), "body": body}) + "\\n")
                if self.headers.get("x-api-key") != "secret": return self.reply(401, {"error": {"message": "bad key"}})
                text = 'ok\\n```json\\n{"say": "from kimi", "done": true}\\n```'
                self.reply(200, {"choices": [{"message": {"content": text}, "finish_reason": "stop"}], "usage": {"prompt_tokens": 1000000, "completion_tokens": 0}})
        HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
        """.write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", script.path, "\(port)", log.path]
        try p.run()
        return (p, port, log)
    }

    func testOpenAIPluginUsesItsEndpointAuthAndCapabilities() async throws {
        let (server, port, log) = try startMockServer()
        defer { server.terminate() }
        try await Task.sleep(for: .milliseconds(600))
        let folder = tmp.appendingPathComponent("src/kimi")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        {"spec": 1, "id": "kimi", "name": "Kimi", "type": "openai", "baseURL": "http://127.0.0.1:\(port)/v4",
         "chatPath": "chat", "headers": {"X-App": "anvil"},
         "auth": {"type": "apiKey", "header": "x-api-key"},
         "models": [{"id": "kimi-1", "input": 2.0, "output": 8.0}],
         "capabilities": {"stop": false, "streaming": false, "maxTokensField": "max_completion_tokens"}}
        """.write(to: folder.appendingPathComponent(ProviderSpec.fileName), atomically: true, encoding: .utf8)
        try ProviderPlugins.shared.confirm(try ProviderPlugins.shared.inspect(folder: folder))
        defer { ProviderPlugins.shared.setAPIKey("kimi", "") }

        XCTAssertThrowsError(try Brain.fromSettings(model: "kimi/kimi-1"), "no key yet")
        ProviderPlugins.shared.setAPIKey("kimi", "secret")
        await ProviderPlugins.shared.refreshModels("kimi")
        XCTAssertEqual(ProviderPlugins.shared.models("kimi").map(\.id), ["kimi-1", "kimi-2"], "live listing from modelsPath")
        XCTAssertEqual(ProviderPlugins.shared.modelInfo("kimi/kimi-1")?.input, 2.0, "spec prices survive live listing")

        let brain = try Brain.fromSettings(model: "kimi/kimi-1")
        var cost: Double?
        brain.onUsage = { _, _, c in cost = c }
        let reply = try await brain.reply([.user("hi")], maxTokens: 50)
        XCTAssertTrue(reply.contains("from kimi"), reply)
        XCTAssertEqual(cost ?? -1, 2.0, accuracy: 0.0001, "1M prompt tokens at $2/M")

        let line = try XCTUnwrap(try String(contentsOf: log, encoding: .utf8).split(separator: "\n").last)
        let sent = try XCTUnwrap(JSON.parse(String(line)))
        XCTAssertEqual(sent["path"]?.string, "/v4/chat")
        XCTAssertEqual(sent["key"]?.string, "secret")
        XCTAssertEqual(sent["app"]?.string, "anvil")
        XCTAssertEqual(sent["body"]?["model"]?.string, "kimi-1", "the plugin prefix is stripped")
        XCTAssertNil(sent["body"]?["stop"], "stop:false means no stop sequences are sent")
        XCTAssertNil(sent["body"]?["reasoning_effort"])
        XCTAssertEqual(sent["body"]?["max_completion_tokens"]?.int, 50)
    }
}

extension ProviderPluginTests {
    /// Fetches the Z.ai example from this repository on GitHub (needs network, and git access if the repo is private).
    func testFetchFromGitHubLive() async throws {
        let pending: PendingProvider
        do { pending = try await ProviderPlugins.shared.fetch("https://github.com/deeeeone/Anvil/tree/main/examples/providers/zai") }
        catch { throw XCTSkip("couldn't reach GitHub: \(error)") }
        XCTAssertEqual(pending.spec.id, "zai")
        XCTAssertNotNil(pending.commit)
        XCTAssertTrue(pending.source.hasPrefix("github.com/deeeeone/Anvil@main/examples/providers/zai @ "), pending.source)
        try ProviderPlugins.shared.confirm(pending)
        let installed = try XCTUnwrap(ProviderPlugins.shared.provider("zai"))
        XCTAssertTrue(installed.fromGitHub)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.folder.appendingPathComponent(".git").path))
    }
}

extension ProviderPluginTests {
    /// A plugin that brings its own local server: setup runs once, the server starts on first use, stops on request.
    func testLocalServerPluginStartsOnDemand() async throws {
        let port = Int.random(in: 41000...49000)
        let folder = tmp.appendingPathComponent("src/localsrv")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "#!/bin/sh\necho installed >> setup-count.txt\n".write(to: folder.appendingPathComponent("setup.sh"), atomically: true, encoding: .utf8)
        try """
        import json, os
        from http.server import BaseHTTPRequestHandler, HTTPServer
        class H(BaseHTTPRequestHandler):
            def log_message(self, *a): pass
            def reply(self, obj):
                b = json.dumps(obj).encode(); self.send_response(200); self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
            def do_GET(self): self.reply({"data": [{"id": "tiny"}]})
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                self.reply({"choices": [{"message": {"content": "pong " + json.dumps(body.get("enable_thinking"))}, "finish_reason": "stop"}]})
        HTTPServer(("127.0.0.1", int(os.environ["PORT"])), H).serve_forever()
        """.write(to: folder.appendingPathComponent("server.py"), atomically: true, encoding: .utf8)
        try """
        {"spec": 1, "id": "localsrv", "name": "Local server", "type": "openai", "baseURL": "http://127.0.0.1:\(port)/v1",
         "server": {"setup": ["sh", "setup.sh"], "command": ["python3", "server.py"], "env": {"PORT": "\(port)"},
                    "ready": "http://127.0.0.1:\(port)/v1/models", "startupTimeout": 20},
         "auth": {"type": "none"}, "body": {"enable_thinking": false}, "models": [{"id": "tiny"}],
         "capabilities": {"stop": false, "streaming": false}, "free": true}
        """.write(to: folder.appendingPathComponent(ProviderSpec.fileName), atomically: true, encoding: .utf8)
        let pending = try ProviderPlugins.shared.inspect(folder: folder)
        XCTAssertTrue(pending.summary.joined().contains("Runs a local server"), "\(pending.summary)")
        try ProviderPlugins.shared.confirm(pending)
        let p = try XCTUnwrap(ProviderPlugins.shared.provider("localsrv"))
        defer { ProviderServers.shared.stop("localsrv") }
        XCTAssertEqual(ProviderServers.shared.state("localsrv"), .stopped)

        let brain = try Brain.fromSettings(model: "localsrv/tiny")
        let first = try await brain.oneShot("ping")
        XCTAssertEqual(first, "pong false", "the spec's extra body field reached the server")
        XCTAssertEqual(ProviderServers.shared.state("localsrv"), .running)
        _ = try await brain.oneShot("ping again")
        let setups = try String(contentsOf: folder.appendingPathComponent("setup-count.txt"), encoding: .utf8)
        XCTAssertEqual(setups.split(separator: "\n").count, 1, "setup runs once")

        ProviderServers.shared.stop("localsrv")
        try await Task.sleep(for: .milliseconds(500))
        let stillUp = await ProviderServers.answers("http://127.0.0.1:\(port)/v1/models")
        XCTAssertFalse(stillUp, "stopped")
        _ = try await ProviderClient(p).listModels()
        XCTAssertEqual(ProviderServers.shared.state("localsrv"), .running, "starts again when needed")
    }


    /// Web sessions reach a plugin's server through the environment, and a changed session restarts it.
    func testServerGetsWebSessionEnvAndRestartsOnChange() async throws {
        let port = Int.random(in: 41000...49000)
        let folder = tmp.appendingPathComponent("src/envsrv")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        import json, os
        from http.server import BaseHTTPRequestHandler, HTTPServer
        class H(BaseHTTPRequestHandler):
            def log_message(self, *a): pass
            def do_GET(self):
                b = json.dumps({"data": [{"id": os.environ.get("ANVIL_PROVIDER_COOKIES", "none").replace('"', "")}]}).encode()
                self.send_response(200); self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
        HTTPServer(("127.0.0.1", int(os.environ["PORT"])), H).serve_forever()
        """.write(to: folder.appendingPathComponent("server.py"), atomically: true, encoding: .utf8)
        try """
        {"spec": 1, "id": "envsrv", "name": "Env server", "type": "openai", "baseURL": "http://127.0.0.1:\(port)/v1",
         "server": {"command": ["python3", "server.py"], "env": {"PORT": "\(port)"},
                    "ready": "http://127.0.0.1:\(port)/v1/models", "startupTimeout": 20},
         "auth": {"type": "web", "loginURL": "https://example.com", "domain": "example.com", "cookies": ["token"]},
         "models": [{"id": "tiny"}]}
        """.write(to: folder.appendingPathComponent(ProviderSpec.fileName), atomically: true, encoding: .utf8)
        try ProviderPlugins.shared.confirm(try ProviderPlugins.shared.inspect(folder: folder))
        defer { ProviderServers.shared.stop("envsrv"); ProviderPlugins.shared.setSession("envsrv", nil) }
        var session = ProviderPlugins.Session()
        session.cookies = ["token": "first"]
        ProviderPlugins.shared.setSession("envsrv", session)
        let p = try XCTUnwrap(ProviderPlugins.shared.provider("envsrv"))
        let first = try await ProviderClient(p).listModels()
        XCTAssertTrue(first.contains { $0.id.contains("first") }, "\(first)")
        session.cookies = ["token": "second"]
        ProviderPlugins.shared.setSession("envsrv", session)
        let second = try await ProviderClient(p).listModels()
        XCTAssertTrue(second.contains { $0.id.contains("second") }, "new session restarted the server: \(second)")
    }

    func testServerSpecValidation() throws {
        let remote = try JSONDecoder().decode(ProviderSpec.self, from: Data(#"{"spec":1,"id":"bad-srv","name":"x","type":"openai","baseURL":"https://api.example.com/v1","server":{"command":["sh","s.sh"],"ready":"https://example.com"},"auth":{"type":"none"}}"#.utf8))
        let p = remote.problems().joined(separator: " ")
        XCTAssertTrue(p.contains("localhost URL"), p)
        XCTAssertTrue(p.contains("localhost baseURL"), p)
    }
}
