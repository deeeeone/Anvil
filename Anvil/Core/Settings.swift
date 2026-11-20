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
    var apiKey: String {
        didSet { if !inMemoryKey { Keychain.set(apiKey, for: "apiKey") } }
    }
    @ObservationIgnored private var inMemoryKey = false

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
        // Headless runs and tests can pass the key in the environment (never printed, never stored).
        if let env = ProcessInfo.processInfo.environment["ANVIL_API_KEY"], !env.isEmpty {
            inMemoryKey = true
            apiKey = env
        } else {
            apiKey = Keychain.get("apiKey") ?? ""
        }
    }

    var hasKey: Bool { !apiKey.isEmpty }

    /// Copies Peep's provider key into Anvil's own Keychain entry. macOS may ask once to allow access.
    @discardableResult
    func importKeyFromPeep() -> Bool {
        guard let k = Keychain.get(AppInfo.peepKeychainAccount, service: AppInfo.peepKeychainService), !k.isEmpty else { return false }
        inMemoryKey = false
        apiKey = k
        return true
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
