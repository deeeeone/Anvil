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
    /// Experiential Labs key.
    var apiKey: String {
        didSet { if !inMemoryKey { Keychain.set(apiKey, for: "apiKey") } }
    }
    @ObservationIgnored private var inMemoryKey = false
    /// Your Luna API (keyless, OpenAI-compatible).
    var lunaURL: String { didSet { d.set(lunaURL, forKey: "lunaURL") } }
    /// The self-hosted Gemini web proxy.
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
        lunaURL = d.string(forKey: "lunaURL") ?? Providers.defaultLunaURL
        geminiURL = d.string(forKey: "geminiURL") ?? Providers.defaultGeminiURL
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

    /// Can requests to this provider go out?
    func ready(_ p: Provider) -> Bool {
        switch p {
        case .experiential: return !apiKey.isEmpty
        case .luna: return URL(string: lunaURL) != nil
        case .gemini: return !geminiKey.isEmpty && URL(string: geminiURL) != nil
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
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: AppInfo.peepKeychainService,
                                kSecAttrAccount as String: AppInfo.peepKeychainAccount,
                                kSecReturnAttributes as String: true]
        var out: AnyObject?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess
    }
}
