import Foundation
#if canImport(Security)
import Security
#endif

/// Minimal generic-password Keychain wrapper.
///
/// Reads are cached in memory for the life of the process. Callers ask for keys on every request and even inside
/// SwiftUI view bodies, and on macOS a read the user has not granted "Always Allow" for shows a password prompt,
/// so an uncached read meant a prompt every few seconds. With the cache that is at most one prompt per key per launch.
///
/// Under XCTest nothing touches the real Keychain: values live only in the in-memory store, so tests never read,
/// overwrite or delete the owner's saved keys, and never trigger prompts.
nonisolated enum Keychain {
    static func get(_ account: String, service: String = AppInfo.bundleID) -> String? {
        let key = "\(service)/\(account)"
        if let hit = Cache.shared.lookup(key) { return hit }
        if inMemoryOnly { return nil }
        let (value, final) = Store.get(account, service: service)
        // A found value, or a read the user refused, is remembered so we don't ask again this launch.
        // A plain miss is not, so a key saved later by another app (Peep) can still be picked up.
        if final { Cache.shared.store(key, value) }
        return value
    }

    @discardableResult
    static func set(_ value: String?, for account: String, service: String = AppInfo.bundleID) -> Bool {
        let key = "\(service)/\(account)"
        let v = (value?.isEmpty == false) ? value : nil
        if inMemoryOnly { Cache.shared.store(key, v); return true }
        let ok = Store.set(v, for: account, service: service)
        if ok { Cache.shared.store(key, v) } else { Cache.shared.forget(key) }
        return ok
    }

    /// True under XCTest: secrets stay in memory and the real Keychain is never used.
    static var inMemoryOnly: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil || NSClassFromString("XCTestCase") != nil
    }

    /// Drops every cached value (tests use this to start clean).
    static func resetCache() { Cache.shared.clear() }

    private final class Cache: @unchecked Sendable {
        static let shared = Cache()
        private let lock = NSLock()
        // Outer optional: cached or not. Inner optional: the cached value, nil meaning "no key".
        private var values: [String: String?] = [:]

        func lookup(_ key: String) -> String?? { lock.withLock { values[key] } }
        func store(_ key: String, _ value: String?) { lock.withLock { values[key] = .some(value) } }
        func forget(_ key: String) { lock.withLock { _ = values.removeValue(forKey: key) } }
        func clear() { lock.withLock { values.removeAll() } }
    }

#if canImport(Security) && !SWIFT_PACKAGE
    private enum Store {
        /// The value, and whether the answer is final (found, or refused by the user) rather than a plain miss.
        static func get(_ account: String, service: String) -> (String?, Bool) {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var out: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &out)
            if status == errSecSuccess, let data = out as? Data { return (String(data: data, encoding: .utf8), true) }
            if status == errSecUserCanceled || status == errSecAuthFailed { return (nil, true) }
            return (nil, false)
        }

        static func set(_ value: String?, for account: String, service: String) -> Bool {
            let base: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(base as CFDictionary)
            guard let value else { return true }
            var add = base
            add[kSecValueData as String] = Data(value.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
    }
#else
    /// The anvil CLI's own secret store: a JSON file readable only by the owner (mode 0600) in the support folder.
    /// Linux and Windows have no Keychain; on a Mac the unsigned CLI would get a password prompt for every key the
    /// signed app saved, so it keeps its own keys instead (`anvil config set api-key`). On a Mac the file is
    /// cli-credentials.json, so it's clearly the CLI's and not something the app reads.
    private enum Store {
        private static var fileURL: URL {
#if canImport(Darwin)
            Paths.support.appendingPathComponent("cli-credentials.json")
#else
            Paths.support.appendingPathComponent("credentials.json")
#endif
        }

        private static func load() -> [String: String] {
            guard let data = try? Data(contentsOf: fileURL) else { return [:] }
            return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        }

        static func get(_ account: String, service: String) -> (String?, Bool) {
            let v = load()["\(service)/\(account)"]
            return (v, v != nil)
        }

        static func set(_ value: String?, for account: String, service: String) -> Bool {
            var all = load()
            let key = "\(service)/\(account)"
            if let value { all[key] = value } else { all.removeValue(forKey: key) }
            guard let data = try? JSONEncoder().encode(all) else { return false }
            let url = fileURL
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // createFile only applies its permissions to a new file, so start from a clean slate.
            try? FileManager.default.removeItem(at: url)
            return FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
        }
    }
#endif
}
