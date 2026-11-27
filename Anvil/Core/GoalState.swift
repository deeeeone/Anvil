import Foundation

/// One checkable item of a goal's definition of done.
nonisolated struct GoalCriterion: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case command, file, manual }
    var text: String
    var kind: Kind = .manual
    /// A shell command that must exit 0.
    var command: String?
    /// A file that must exist.
    var path: String?
    /// The result of the latest check (nil = not checked by the app).
    var met: Bool?
}

nonisolated struct GoalBudget: Codable, Equatable, Sendable {
    var maxMinutes = 240
    /// USD; 0 = no cost limit.
    var maxCost = 0.0
    var maxSteps = 1500
}

nonisolated struct GoalSpent: Codable, Equatable, Sendable {
    var minutes = 0.0
    var cost = 0.0
    var steps = 0
}

/// /goal mission state, saved with the session so a goal survives a restart.
nonisolated struct GoalState: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case planning, working, checking, fixing, waitingForProvider, waitingForOwner, done, stopped
    }

    var objective: String
    var criteria: [GoalCriterion] = []
    var phase: Phase = .planning
    var rounds = 0
    var startedAt = Date()
    /// When the current round started (time is counted from here, so a restart doesn't use up the budget).
    var lastTick = Date()
    var budget = GoalBudget()
    var spent = GoalSpent()
    /// The session's cost when the goal started (spent cost = session cost minus this).
    var costBase = 0.0
    /// The last 50 things that went wrong or were retried, for the final summary.
    var recovery: [String] = []
    /// Misses still open when the goal ended, or when it was last judged.
    var unresolved: [String] = []
    /// The worktree branch the goal runs on (nil = in place).
    var branch: String?
    var stuckRounds = 0
    var lastSignature = ""
    var escalated = false
    /// Provider failures in a row (reset by any reply that came back).
    var providerTries = 0
    /// The permission mode and step limit the session had before the goal, restored when it ends.
    var savedMode: PermissionMode?
    var savedSteps: Int?

    init(objective: String, budget: GoalBudget = GoalBudget(), costBase: Double = 0) {
        self.objective = objective
        self.budget = budget
        self.costBase = costBase
    }

    /// Goals in these phases pick up again when Anvil starts.
    var isActive: Bool { [.working, .checking, .fixing, .waitingForProvider].contains(phase) }

    mutating func log(_ line: String) {
        recovery.append(line)
        if recovery.count > 50 { recovery.removeFirst(recovery.count - 50) }
    }

    /// Seconds to wait before retrying a failed provider: 30 s, 2 min, 5 min, then every 10 min.
    static func backoff(tries: Int) -> TimeInterval {
        let steps: [TimeInterval] = [30, 120, 300]
        return tries < steps.count ? steps[tries] : 600
    }

    /// The criteria a reply declares in its json block ("criteria"), or nil when it declares none.
    static func parseCriteria(_ reply: String) -> [GoalCriterion]? {
        guard let obj = CompletionJudge.jsonObject(reply), let list = obj["criteria"] as? [Any] else { return nil }
        func clean(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t
        }
        let out: [GoalCriterion] = list.compactMap { item in
            if let s = clean(item as? String) { return GoalCriterion(text: s) }
            guard let d = item as? [String: Any], let text = clean((d["text"] ?? d["check"] ?? d["description"]) as? String) else { return nil }
            if let cmd = clean(d["command"] as? String) { return GoalCriterion(text: text, kind: .command, command: cmd) }
            if let path = clean(d["path"] as? String) { return GoalCriterion(text: text, kind: .file, path: path) }
            return GoalCriterion(text: text)
        }
        return out.isEmpty ? nil : Array(out.prefix(8))
    }

    /// The first criteria declared by an assistant message in the conversation.
    static func criteria(in messages: [ChatMessage]) -> [GoalCriterion]? {
        for m in messages where m.role == "assistant" {
            if let found = parseCriteria(m.text) { return found }
        }
        return nil
    }

    /// The prompt that keeps a goal going after a round that didn't finish it.
    static func continuePrompt(missing: [String], stuckOn: String?) -> String {
        var p = "Continue toward the goal."
        p += missing.isEmpty ? " Don't repeat finished work: check what's already done, then finish the rest."
            : " Still missing: " + missing.joined(separator: "; ") + ". Don't redo finished work."
        if let stuckOn {
            p += " You're stuck on \(stuckOn). Re-read the relevant code, take a different approach, or ask the explore helper."
        }
        return p
    }
}
