import Foundation
import Observation

/// App-wide preferences (UserDefaults) plus the API key (Keychain).
@Observable
final class AppSettings {
    static let shared = AppSettings()
    @ObservationIgnored private let d = UserDefaults.standard

    var baseURL: String { didSet { d.set(baseURL, forKey: "baseURL") } }
    var model: String { didSet { d.set(model, forKey: "model") } }
    /// Used only for turns that carry an image (pasted screenshots). Empty = never send images.
    var visionModel: String { didSet { d.set(visionModel, forKey: "visionModel") } }
    /// "high" by default: the provider default ("max") is about twice as slow per step.
    var effort: String { didSet { d.set(effort, forKey: "effort") } }
    var visionEffort: String { didSet { d.set(visionEffort, forKey: "visionEffort") } }
    var maxSteps: Int { didSet { d.set(maxSteps, forKey: "maxSteps") } }
    /// Estimated context tokens above which the session is compacted automatically.
    var autoCompactTokens: Int { didSet { d.set(autoCompactTokens, forKey: "autoCompactTokens") } }
    var defaultMode: PermissionMode { didSet { d.set(defaultMode.rawValue, forKey: "defaultMode") } }
    var shellTimeout: Double { didSet { d.set(shellTimeout, forKey: "shellTimeout") } }
    /// Stop a request once it has cost this much (USD; 0 = no limit). Free models never reach it.
    var maxTaskCost: Double { didSet { d.set(maxTaskCost, forKey: "maxTaskCost") } }
    /// Seconds a reply may go quiet once it has started before the turn is retried (the idle watchdog).
    var stallSeconds: Int { didSet { d.set(stallSeconds, forKey: "stallSeconds") } }
    /// Seconds to wait for a reply's first token before the turn is retried (thinking models are quiet for a long time).
    var firstTokenSeconds: Int { didSet { d.set(firstTokenSeconds, forKey: "firstTokenSeconds") } }
    /// Keep the Mac from sleeping while a request or queue task runs.
    var keepAwake: Bool { didSet { d.set(keepAwake, forKey: "keepAwake") } }
    /// Show "Working on a task" on your Discord profile (Rich Presence), with a link to the repo.
    var discordPresence: Bool { didSet { d.set(discordPresence, forKey: "discordPresence") } }
    /// Also show the project's folder name there (off by default: project names can be private).
    var discordShowProject: Bool { didSet { d.set(discordShowProject, forKey: "discordShowProject") } }
    /// The Discord application ID the presence is shown under (its name is what Discord displays).
    var discordClientID: String { didSet { d.set(discordClientID, forKey: "discordClientID") } }
    /// Permission mode for background queue tasks.
    var queueMode: PermissionMode { didSet { d.set(queueMode.rawValue, forKey: "queueMode") } }
    /// How many queue tasks and sub-sessions run at the same time (each in its own worktree).
    var parallelTasks: Int { didSet { d.set(parallelTasks, forKey: "parallelTasks") } }
    /// After a batch of edits, ask the project's language server for type errors the edits introduced.
    var lspChecks: Bool { didSet { d.set(lspChecks, forKey: "lspChecks") } }
    /// Poll the project's GitHub repo for open issues with this label and queue them ("" = off).
    var githubIssueLabel: String { didSet { d.set(githubIssueLabel, forKey: "githubIssueLabel") } }
    /// Before accepting "done" after edits, run the project's test command (or ask the agent to verify).
    var autoVerify: Bool { didSet { d.set(autoVerify, forKey: "autoVerify") } }
    /// A second model call reads the final diff and flags real problems before the agent finishes.
    var selfReview: Bool { didSet { d.set(selfReview, forKey: "selfReview") } }
    /// Before a request is accepted as done, a hidden judge model checks the answer against the request and its changes.
    var judgeEnabled: Bool { didSet { d.set(judgeEnabled, forKey: "judgeEnabled") } }
    /// The judge's model: "auto" (the session's model; gemini-4-hydrogen is judged by gemini-neon), or a model id.
    var judgeModel: String { didSet { d.set(judgeModel, forKey: "judgeModel") } }
    /// After UI work, screenshot the page and have a vision model critique it (up to 3 fix rounds; see DesignCritique).
    var designCheck: Bool { didSet { d.set(designCheck, forKey: "designCheck") } }
    /// /goal runs in its own git worktree on its own branch (anvil/goal-...), when the project is a git repo.
    var goalInWorktree: Bool { didSet { d.set(goalInWorktree, forKey: "goalInWorktree") } }
    /// How long a goal may run before it stops with a summary (minutes).
    var goalMaxMinutes: Int { didSet { d.set(goalMaxMinutes, forKey: "goalMaxMinutes") } }
    /// After the same action fails twice, the next turn goes to this model ("auto" picks the other family, "" = off).
    var escalationModel: String { didSet { d.set(escalationModel, forKey: "escalationModel") } }
    /// Exploration turns (only reads and searches so far) and explore helpers use this model ("" = the session model).
    var exploreModel: String { didSet { d.set(exploreModel, forKey: "exploreModel") } }
    /// Stream replies (live text, and early stop for providers that ignore stop sequences).
    var streaming: Bool { didSet { d.set(streaming, forKey: "streaming") } }
    /// Reasoning effort per turn (low for wrap-ups and simple requests); the effort setting is the ceiling.
    var adaptiveEffort: Bool { didSet { d.set(adaptiveEffort, forKey: "adaptiveEffort") } }
    /// Model for simple requests (renames, typos); "" = the session model.
    var quickModel: String { didSet { d.set(quickModel, forKey: "quickModel") } }
    var prefetch: Bool { didSet { d.set(prefetch, forKey: "prefetch") } }
    var prepareWhilePlanning: Bool { didSet { d.set(prepareWhilePlanning, forKey: "prepareWhilePlanning") } }
    /// Warm the provider's prompt cache while the owner types.
    var warmCache: Bool { didSet { d.set(warmCache, forKey: "warmCache") } }
    /// Keep a short project brief (one cheap call when the project's shape changes).
    var projectBrief: Bool { didSet { d.set(projectBrief, forKey: "projectBrief") } }
    /// Name a session with a small model after its first request (the first message's title stays until then).
    var aiTitles: Bool { didSet { d.set(aiTitles, forKey: "aiTitles") } }
    /// Inject the jailbreak prompt ahead of requests to ChatGPT and Gemini web models.
    var jailbreak: Bool { didSet { d.set(jailbreak, forKey: "jailbreak") } }
    /// Save session transcripts to a NotebookLM notebook in the Google account, and let the agent ask it (ask_memory).
    var notebookMemory: Bool { didSet { d.set(notebookMemory, forKey: "notebookMemory") } }
    /// "project" (one notebook per project folder) or "account" (one notebook for everything).
    var notebookScope: String { didSet { d.set(notebookScope, forKey: "notebookScope") } }
    /// The Google AI plan ("free", "plus", "pro", "ultra"), which sets NotebookLM's limits.
    var notebookPlan: String { didSet { d.set(notebookPlan, forKey: "notebookPlan") } }
    /// Models pinned to the top of the model menu, in order.
    var favoriteModels: [String] { didSet { d.set(favoriteModels, forKey: "favoriteModels") } }
    /// Provider section ids (a Provider rawValue or a provider plugin id) hidden from the model menu.
    var hiddenModelSections: [String] { didSet { d.set(hiddenModelSections, forKey: "hiddenModelSections") } }
    /// Provider section ids whose models sit in a submenu in the model menu.
    var collapsedModelSections: [String] { didSet { d.set(collapsedModelSections, forKey: "collapsedModelSections") } }
    /// When a model fails for good (bad key, quota, retries used up), retry the turn on another ready model.
    var autoFallback: Bool { didSet { d.set(autoFallback, forKey: "autoFallback") } }
    /// Experiential Labs key.
    var apiKey: String {
        didSet { if !inMemoryKey { Keychain.set(apiKey, for: "apiKey") } }
    }
    @ObservationIgnored private var inMemoryKey = false
    /// Your Luna API (keyless, OpenAI-compatible).
    var lunaURL: String { didSet { d.set(lunaURL, forKey: "lunaURL") } }
    /// The local ChatGPT web proxy (zhaees/chatgpt-proxy) and, optionally, the folder it's cloned in.
    /// Only used when no ChatGPT account has been added in Settings.
    var chatgptURL: String { didSet { d.set(chatgptURL, forKey: "chatgptURL") } }
    var chatgptProxyFolder: String { didSet { d.set(chatgptProxyFolder, forKey: "chatgptProxyFolder") } }
    /// A proxy is only a fallback; the local ChatGPT client is used when an account exists.
    var chatgptProxyConfigured: Bool { !chatgptProxyFolder.isEmpty || chatgptURL != Providers.defaultChatGPTURL }
    /// A self-hosted Gemini web proxy. Only used when no Gemini account has been added.
    var geminiURL: String { didSet { d.set(geminiURL, forKey: "geminiURL") } }
    var geminiKey: String {
        didSet { if !inMemoryGemini { Keychain.set(geminiKey, for: "geminiKey") } }
    }
    @ObservationIgnored private var inMemoryGemini = false

    static let defaultBaseURL = "https://api.experientiallabs.ai"
    static let defaultModel = "glm-5.3-flash-uncensored"
    static let defaultVisionModel = "glm-5.3-flash"
    static let efforts = ["low", "medium", "high", "max"]

    private init() {
        baseURL = d.string(forKey: "baseURL") ?? Self.defaultBaseURL
        model = d.string(forKey: "model") ?? Self.defaultModel
        visionModel = d.string(forKey: "visionModel") ?? Self.defaultVisionModel
        effort = d.string(forKey: "effort") ?? "high"
        visionEffort = d.string(forKey: "visionEffort") ?? "low"
        maxSteps = d.object(forKey: "maxSteps") as? Int ?? 80
        autoCompactTokens = d.object(forKey: "autoCompactTokens") as? Int ?? 160_000
        defaultMode = PermissionMode(rawValue: d.string(forKey: "defaultMode") ?? "") ?? .ask
        shellTimeout = d.object(forKey: "shellTimeout") as? Double ?? 300
        maxTaskCost = d.object(forKey: "maxTaskCost") as? Double ?? 0
        stallSeconds = d.object(forKey: "stallSeconds") as? Int ?? 120
        firstTokenSeconds = d.object(forKey: "firstTokenSeconds") as? Int ?? 240
        keepAwake = d.object(forKey: "keepAwake") as? Bool ?? true
        discordPresence = d.object(forKey: "discordPresence") as? Bool ?? true
        discordShowProject = d.object(forKey: "discordShowProject") as? Bool ?? false
        discordClientID = d.string(forKey: "discordClientID") ?? DiscordPresence.clientID
        queueMode = PermissionMode(rawValue: d.string(forKey: "queueMode") ?? "") ?? .acceptEdits
        parallelTasks = min(4, max(1, d.object(forKey: "parallelTasks") as? Int ?? 2))
        lspChecks = d.object(forKey: "lspChecks") as? Bool ?? true
        githubIssueLabel = d.string(forKey: "githubIssueLabel") ?? ""
        autoVerify = d.object(forKey: "autoVerify") as? Bool ?? true
        selfReview = d.object(forKey: "selfReview") as? Bool ?? true
        escalationModel = d.string(forKey: "escalationModel") ?? "auto"
        exploreModel = d.string(forKey: "exploreModel") ?? ""
        streaming = d.object(forKey: "streaming") as? Bool ?? true
        adaptiveEffort = d.object(forKey: "adaptiveEffort") as? Bool ?? true
        quickModel = d.string(forKey: "quickModel") ?? ""
        prefetch = d.object(forKey: "prefetch") as? Bool ?? true
        prepareWhilePlanning = d.object(forKey: "prepareWhilePlanning") as? Bool ?? true
        warmCache = d.object(forKey: "warmCache") as? Bool ?? true
        projectBrief = d.object(forKey: "projectBrief") as? Bool ?? true
        aiTitles = d.object(forKey: "aiTitles") as? Bool ?? true
        jailbreak = d.object(forKey: "jailbreak") as? Bool ?? false
        judgeEnabled = d.object(forKey: "judgeEnabled") as? Bool ?? true
        judgeModel = d.string(forKey: "judgeModel") ?? "auto"
        designCheck = d.object(forKey: "designCheck") as? Bool ?? true
        goalInWorktree = d.object(forKey: "goalInWorktree") as? Bool ?? true
        goalMaxMinutes = d.object(forKey: "goalMaxMinutes") as? Int ?? 240
        notebookMemory = d.object(forKey: "notebookMemory") as? Bool ?? true
        notebookScope = d.string(forKey: "notebookScope") ?? "project"
        notebookPlan = d.string(forKey: "notebookPlan") ?? "free"
        favoriteModels = d.stringArray(forKey: "favoriteModels") ?? []
        hiddenModelSections = d.stringArray(forKey: "hiddenModelSections") ?? []
        collapsedModelSections = d.stringArray(forKey: "collapsedModelSections") ?? []
        autoFallback = d.object(forKey: "autoFallback") as? Bool ?? true
        lunaURL = d.string(forKey: "lunaURL") ?? Providers.defaultLunaURL
        geminiURL = d.string(forKey: "geminiURL") ?? Providers.defaultGeminiURL
        chatgptURL = d.string(forKey: "chatgptURL") ?? Providers.defaultChatGPTURL
        chatgptProxyFolder = d.string(forKey: "chatgptProxyFolder") ?? ""
        if let env = ProcessInfo.processInfo.environment["ANVIL_GEMINI_KEY"], !env.isEmpty {
            inMemoryGemini = true
            geminiKey = env
        } else {
            geminiKey = Keychain.get("geminiKey") ?? ""
        }
        // Headless runs and tests can pass the key in the environment (never printed, never stored).
        if let env = ProcessInfo.processInfo.environment["ANVIL_API_KEY"], !env.isEmpty {
            inMemoryKey = true
            apiKey = env
        } else {
            apiKey = Keychain.get("apiKey") ?? ""
        }
    }

    var hasKey: Bool { !apiKey.isEmpty }

    /// The model to escalate to from `model` ("" = none available).
    func escalation(for model: String) -> String {
        if escalationModel.isEmpty { return "" }
        if escalationModel != "auto" { return ready(model: escalationModel) && escalationModel != model ? escalationModel : "" }
        guard ready(.experiential) else { return "" }
        return model.hasPrefix("deepseek") ? "glm-5.3-flash-uncensored" : "deepseek-v4.1-flash-uncensored"
    }

    /// Can requests to this provider go out?
    /// Whether a model can be used now: its provider plugin is set up, or its built-in provider is.
    func ready(model: String) -> Bool {
        if let (plugin, _) = ProviderPlugins.shared.route(model) { return ProviderPlugins.shared.isReady(plugin.id) }
        return ready(Providers.provider(for: model))
    }

    func ready(_ p: Provider) -> Bool {
        switch p {
        case .experiential: return !apiKey.isEmpty
        case .luna: return URL(string: lunaURL) != nil
        case .gemini: return WebAccounts.shared.hasAny(.gemini) || (!geminiKey.isEmpty && URL(string: geminiURL) != nil)
        case .chatgpt: return WebAccounts.shared.hasAny(.chatgpt) || chatgptProxyConfigured
        }
    }

    /// Copies Peep's keys (Experiential Labs and the Gemini proxy) into Anvil's own Keychain entries.
    /// macOS may ask once to allow access. Returns what was imported.
    @discardableResult
    func importKeyFromPeep() -> [String] {
        var got: [String] = []
        if let k = Keychain.get(AppInfo.peepKeychainAccount, service: AppInfo.peepKeychainService), !k.isEmpty {
            inMemoryKey = false
            apiKey = k
            got.append("Experiential Labs")
        }
        if let g = Keychain.get("apiKey", service: AppInfo.peepKeychainService), !g.isEmpty {
            inMemoryGemini = false
            geminiKey = g
            got.append("Gemini proxy")
        }
        if let url = UserDefaults(suiteName: "com.diwan.peep")?.string(forKey: "baseURL"), !url.isEmpty { geminiURL = url }
        return got
    }

    var peepKeyAvailable: Bool {
        // Existence check without reading the secret.
#if canImport(Security)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: AppInfo.peepKeychainService,
                                kSecAttrAccount as String: AppInfo.peepKeychainAccount,
                                kSecReturnAttributes as String: true]
        var out: AnyObject?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess
#else
        return false // TODO(linux): no Keychain, so the peep key is never found here.
#endif
    }
}
