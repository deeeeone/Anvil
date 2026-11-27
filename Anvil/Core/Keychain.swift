import Foundation
#if canImport(Security)
import Security
#endif

/// Minimal generic-password Keychain wrapper.
nonisolated enum Keychain {
#if canImport(Security)
    static func get(_ account: String, service: String = AppInfo.bundleID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func set(_ value: String?, for account: String, service: String = AppInfo.bundleID) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
#else
    // TODO(linux): no Keychain on this platform. Secrets live in credentials.json (mode 0600) under the app support folder.
    private static var fileURL: URL { Paths.support.appendingPathComponent("credentials.json") }

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    static func get(_ account: String, service: String = AppInfo.bundleID) -> String? {
        load()["\(service)/\(account)"]
    }

    @discardableResult
    static func set(_ value: String?, for account: String, service: String = AppInfo.bundleID) -> Bool {
        var all = load()
        let key = "\(service)/\(account)"
        if let value, !value.isEmpty { all[key] = value } else { all.removeValue(forKey: key) }
        guard let data = try? JSONEncoder().encode(all) else { return false }
        let url = fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // createFile only applies its permissions to a new file, so start from a clean slate.
        try? FileManager.default.removeItem(at: url)
        return FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
    }
#endif
}
