import Foundation

// Saved sessions must keep loading as fields are added: every field falls back to its default when it's missing.

extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T { ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback }
}

extension ChatItem {
    enum CodingKeys: String, CodingKey { case id, kind, text, date, tool, plan, images, final, historyIndex, skillWorthy, suggestion }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: c.value(.id, UUID()), kind: c.value(.kind, .system), text: c.value(.text, ""))
        date = c.value(.date, Date())
        tool = c.value(.tool, nil as ToolStep?)
        plan = c.value(.plan, nil as PlanCard?)
        images = c.value(.images, 0)
        final = c.value(.final, false)
        historyIndex = c.value(.historyIndex, nil as Int?)
        skillWorthy = c.value(.skillWorthy, false)
        suggestion = c.value(.suggestion, nil as Suggestion?)
    }
}

extension ToolStep {
    enum CodingKeys: String, CodingKey { case name, summary, status, output, diffs, duration }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: c.value(.name, ""), summary: c.value(.summary, ""), status: c.value(.status, .ok))
        output = c.value(.output, "")
        diffs = c.value(.diffs, [FileDiff]())
        duration = c.value(.duration, nil as Double?)
    }
}

extension SessionUsage {
    enum CodingKeys: String, CodingKey { case calls, prompt, completion, cached, cost, lastPrompt }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        calls = c.value(.calls, 0); prompt = c.value(.prompt, 0); completion = c.value(.completion, 0)
        cached = c.value(.cached, 0); cost = c.value(.cost, 0.0); lastPrompt = c.value(.lastPrompt, 0)
    }
}

extension Session {
    enum CodingKeys: String, CodingKey {
        case id, title, created, updated, projectPath, model, mode, items, messages, briefing, todos, plan, checkpoints, usage,
             allowedCommands, workdir, branch, baseBranch, costLimit, stepLimit, compactedAt
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(projectPath: c.value(.projectPath, ""))
        id = c.value(.id, UUID()); title = c.value(.title, "Session")
        created = c.value(.created, Date()); updated = c.value(.updated, Date())
        model = c.value(.model, nil as String?); mode = c.value(.mode, nil as PermissionMode?)
        items = c.value(.items, [ChatItem]()); messages = c.value(.messages, [ChatMessage]())
        briefing = c.value(.briefing, ""); todos = c.value(.todos, [TodoItem]()); plan = c.value(.plan, nil as PlanCard?)
        checkpoints = c.value(.checkpoints, [Checkpoint]()); usage = c.value(.usage, SessionUsage())
        allowedCommands = c.value(.allowedCommands, [String]())
        workdir = c.value(.workdir, nil as String?); branch = c.value(.branch, nil as String?); baseBranch = c.value(.baseBranch, nil as String?)
        costLimit = c.value(.costLimit, nil as Double?); stepLimit = c.value(.stepLimit, nil as Int?); compactedAt = c.value(.compactedAt, nil as Date?)
    }
}
