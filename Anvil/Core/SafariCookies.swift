import Foundation

/// Reads cookies Safari already has, so a sign-in done in Safari (where passkeys and password
/// autofill work, because the sites claim Safari as a browser) can be imported into an account.
/// Safari's jar is TCC-protected: the app needs Full Disk Access.
nonisolated enum SafariCookies {
    static var file: URL? {
        if let override = ProcessInfo.processInfo.environment["ANVIL_SAFARI_COOKIES"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"),
            home.appendingPathComponent("Library/Cookies/Cookies.binarycookies"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func cookies(for provider: Provider) throws -> [String: String] {
        let url: URL
        if let file { url = file } else { throw Failure.noFile }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw Failure.noAccess }
        let wanted = provider == .chatgpt ? ["chatgpt.com", "openai.com"] : ["google.com"]
        let records = parse(data).filter { record in
            (record.expiry > Date() || record.expiry == .distantPast) && wanted.contains(where: { record.domain.contains($0) })
        }
        let host = provider == .chatgpt ? "chatgpt.com" : "gemini.google.com"
        // Most-specific cookies win (gemini.google.com's OSID over google.com's), like path/domain order in a browser.
        let generic = records.filter { $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")) != host }
        let specific = records.filter { $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")) == host }
        var out: [String: String] = [:]
        for record in generic + specific { out[record.name] = record.value }
        return out
    }

    enum Failure: LocalizedError {
        case noFile, noAccess, corrupt
        var errorDescription: String? {
            switch self {
            case .noFile: return "Safari has no cookies file yet. Sign in in Safari first."
            case .noAccess: return "Can't read Safari's cookies. Give Anvil Full Disk Access in System Settings → Privacy & Security, then try again."
            case .corrupt: return "Safari's cookie file couldn't be read."
            }
        }
    }

    struct Record {
        var domain = ""
        var name = ""
        var path = "/"
        var value = ""
        var expiry = Date.distantPast
    }

    static func parse(_ data: Data) -> [Record] {
        guard data.count > 8, String(decoding: data.prefix(4), as: UTF8.self) == "cook" else { return [] }
        let pages = Int(be32(data, 4))
        guard pages > 0, pages < 5000, 8 + pages * 4 <= data.count else { return [] }
        let sizes = (0..<pages).map { Int(be32(data, 8 + $0 * 4)) }
        var page = 8 + pages * 4
        var out: [Record] = []
        for size in sizes {
            guard size >= 8, page + size <= data.count else { break }
            let count = Int(le32(data, page + 4) ?? 0)
            if count > 0, count < 5000 {
                for i in 0..<count {
                    guard let offset = le32(data, page + 8 + i * 4) else { break }
                    if let r = record(data, at: page + Int(offset)) { out.append(r) }
                }
            }
            page += size
        }
        return out
    }

    private static func record(_ data: Data, at start: Int) -> Record? {
        guard start >= 0, start + 48 <= data.count else { return nil }
        guard let urlOff = le32(data, start + 16), let nameOff = le32(data, start + 20),
              let pathOff = le32(data, start + 24), let valueOff = le32(data, start + 28) else { return nil }
        guard let domain = cstr(data, start + Int(urlOff)), let name = cstr(data, start + Int(nameOff)),
              let value = cstr(data, start + Int(valueOff)) else { return nil }
        var r = Record()
        r.domain = domain
        r.name = name
        r.value = value
        r.path = cstr(data, start + Int(pathOff)) ?? "/"
        let expiry = leDouble(data, start + 32) ?? 0
        if expiry > 0 { r.expiry = Date(timeIntervalSinceReferenceDate: expiry) }
        return r
    }

    private static func cstr(_ d: Data, _ at: Int) -> String? {
        guard at >= 0, at < d.count else { return nil }
        var end = at
        while end < d.count, d[end] != 0 { end += 1 }
        guard end > at else { return "" }
        return String(decoding: d[at..<end], as: UTF8.self)
    }

    private static func be32(_ d: Data, _ at: Int) -> UInt32 {
        guard at + 4 <= d.count else { return 0 }
        return UInt32(d[at]) << 24 | UInt32(d[at + 1]) << 16 | UInt32(d[at + 2]) << 8 | UInt32(d[at + 3])
    }

    private static func le32(_ d: Data, _ at: Int) -> UInt32? {
        guard at + 4 <= d.count else { return nil }
        return UInt32(d[at]) | UInt32(d[at + 1]) << 8 | UInt32(d[at + 2]) << 16 | UInt32(d[at + 3]) << 24
    }

    private static func leDouble(_ d: Data, _ at: Int) -> Double? {
        guard at + 8 <= d.count else { return nil }
        var bits: UInt64 = 0
        for i in (0..<8).reversed() { bits = bits << 8 | UInt64(d[at + i]) }
        return Double(bitPattern: bits)
    }
}
