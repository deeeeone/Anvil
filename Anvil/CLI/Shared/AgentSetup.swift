import Foundation

/// Setup that every CLI run shares (headless and interactive): the agent's limits, its features and its models,
/// taken from the saved settings and overridden by the command-line options. Keeping it in one place means the two
/// modes cannot drift apart.
enum AgentSetup {
    /// Applies the settings and options to a fresh agent. The caller still wires the usage and checkpoint hooks,
    /// which differ between the modes.
    @MainActor
    static func configure(_ agent: Agent, options: CLIOptions, mode: PermissionMode) {
        let settings = AppSettings.shared
        agent.toolProvider = { MCPManager.shared.toolSpecs }
        agent.mode = mode
        agent.maxSteps = options.maxSteps ?? settings.maxSteps
        agent.maxCost = options.maxCost ?? settings.maxTaskCost
        agent.autoVerify = settings.autoVerify && !options.noVerify
        agent.selfReview = settings.selfReview && !options.noReview
        agent.judgeEnabled = settings.judgeEnabled && !options.noJudge
        agent.designCheck = false                 // no browser here, so nothing to screenshot
        agent.streaming = settings.streaming && !options.noStream
        agent.escalationModel = settings.escalation(for: agent.brain.model)
        agent.exploreModel = settings.exploreModel
        agent.quickModel = settings.quickModel
        agent.adaptiveEffort = settings.adaptiveEffort
        agent.prefetch = settings.prefetch
    }
}
