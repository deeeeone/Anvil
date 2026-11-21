import Foundation

struct ToolResult {
    var ok: Bool
    var output: String
    var image: (Data, String)? = nil
    /// Stop executing the rest of this action batch.
    var stopBatch = false
    /// End the whole task with this message.
    var endTask: String? = nil

    static func ok(_ s: String) -> ToolResult { ToolResult(ok: true, output: s) }
    static func fail(_ s: String) -> ToolResult { ToolResult(ok: false, output: s, stopBatch: true) }
}

/// A failure message meant for the model (what went wrong and what to do next).
struct ToolFailure: Error, LocalizedError {
    var message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

enum ToolGroup: String, CaseIterable {
    case files = "Files", search = "Search", shell = "Shell and processes", web = "Web", work = "Planning, skills and questions", mcp = "Connected tools (MCP servers)"
}

struct ToolSpec {
    let name: String
    let kind: ToolKind
    let signature: String
    let summary: String
    let group: ToolGroup
    /// Edit tools compute their changes first so the app can show a diff and ask before writing.
    var prepare: ((JSON, ToolContext) async throws -> [FileChange])?
    var run: ((JSON, ToolContext) async throws -> ToolResult)?
    /// Exec tools: the command to check against the permission policy (nil = nothing to check).
    var command: ((JSON) -> String?)?
    /// Overrides `kind` per call (e.g. wait_until only executes for until:"command").
    var kindFor: ((JSON) -> ToolKind)?

    init(name: String, kind: ToolKind, signature: String, summary: String, group: ToolGroup,
         command: ((JSON) -> String?)? = nil, kindFor: ((JSON) -> ToolKind)? = nil,
         run: @escaping (JSON, ToolContext) async throws -> ToolResult) {
        self.name = name; self.kind = kind; self.signature = signature; self.summary = summary; self.group = group
        self.run = run; self.command = command; self.kindFor = kindFor
    }

    init(edit name: String, signature: String, summary: String, prepare: @escaping (JSON, ToolContext) async throws -> [FileChange]) {
        self.name = name; self.kind = .edit; self.signature = signature; self.summary = summary; self.group = .files
        self.prepare = prepare
    }

    var catalogLine: String { "- \(name) \(signature): \(summary)" }
    func effectiveKind(_ args: JSON) -> ToolKind { kindFor?(args) ?? kind }
}

/// What a permission prompt shows and how the owner answered.
struct PermissionRequest {
    var tool: String
    var reason: String
    var command: String?
    var diffs: [FileDiff]
    var commandKey: String?
}

enum PermissionAnswer: Equatable {
    case allow
    case allowSession      // commands: allow this command key for the session; edits: switch to auto-accept edits
    case deny(String?)     // optional note for the model
}

enum PlanDecision: Equatable { case approve, approveAutoEdits, cancel, revise(String) }

/// The UI (or the headless console) the agent reports to.
protocol AgentHost: AnyObject {
    func agentStatus(_ text: String)
    func agentThought(_ text: String)
    func agentSay(_ text: String, final: Bool)
    func agentStepBegan(_ id: UUID, tool: String, summary: String)
    func agentStepOutput(_ id: UUID, chunk: String)
    func agentStepEnded(_ id: UUID, status: ToolStep.Status, output: String, diffs: [FileDiff], duration: Double)
    func agentPermission(_ req: PermissionRequest) async -> PermissionAnswer
    func agentPlan(_ steps: [String]) async -> PlanDecision
    func agentMilestone(_ index: Int)
    func agentTodos(_ todos: [TodoItem])
    func agentAsk(_ question: String) async -> String?
    /// Messages the owner sent while the agent was working (delivered with the next observation).
    func agentDrainSteering() -> [String]
    func agentError(_ text: String)
    /// The reply as it streams in (optional).
    func agentStream(_ text: String)
}

extension AgentHost {
    func agentStream(_ text: String) {}
}

/// What tools can reach while running.
final class ToolContext {
    let root: URL
    let processes: ProcessManager
    weak var host: AgentHost?
    var stepID: UUID?
    var shellTimeout: Double = 300
    var todos: [TodoItem] = []
    /// Files read this session (edit hints).
    var readFiles = Set<String>()

    init(root: URL, processes: ProcessManager, host: AgentHost?) {
        self.root = root.standardizedFileURL
        self.processes = processes
        self.host = host
    }

    func resolve(_ p: String) -> URL { Paths.resolve(p, base: root) }
    func rel(_ u: URL) -> String { Paths.display(u, root: root) }
}
