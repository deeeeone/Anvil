import Foundation
import Observation

/// A provider plugin Anvil knows about: its spec, where it lives, and where it came from.
nonisolated struct InstalledProvider: Identifiable, Equatable, Sendable {
    var spec: ProviderSpec
    var folder: URL
    /// Where it was installed from ("github.com/o/r@abc1234", "preset", or a linked folder).
    var source: String
    /// The commit installed from GitHub (nil for presets and linked folders).
    var commit: String?
    /// A folder on disk used in place (for plugin authors): edits apply after Reload.
    var linked: Bool
    var id: String { spec.id }
    var fromGitHub: Bool { commit != nil }
}

/// A plugin fetched and validated, waiting for the owner to confirm what it will do.
nonisolated struct PendingProvider: Identifiable, Sendable {
    var spec: ProviderSpec
    var folder: URL
    var source: String
    var commit: String?
    var linked: Bool
    var replaces: Bool
    var id: String { spec.id }

    /// What installing this means, in plain words, for the confirmation sheet.
    var summary: [String] {
        var out: [String] = []
        switch spec.type {
        case .openai:
            if let srv = spec.server {
                out.append("Runs a local server on your Mac for this provider: \(srv.command.joined(separator: " "))" +
                           (srv.setup.map { ", after a one-time setup: \($0.joined(separator: " "))" } ?? ""))
                out.append("Those scripts can do anything your user account can (the setup usually downloads code). Read them first, and only install if you trust the author.")
            } else {
                out.append("Sends your prompts and code to \(URL(string: spec.baseURL ?? "")?.host ?? "?").")
            }
        case .process:
            out.append("Runs a program on your Mac for every request: \((spec.command ?? []).joined(separator: " "))")
            out.append("That program can do anything your user account can. Only install it if you trust the author.")
        }
        switch spec.auth.type {
        case .none: out.append("No sign-in needed.")
        case .apiKey: out.append("Uses an API key you enter; it's kept in the Keychain and only sent \(spec.type == .openai ? "to that host" : "to the plugin").")
        case .web: out.append("Signs in on \(URL(string: spec.auth.loginURL ?? "")?.host ?? "the site"); the captured session is kept in the Keychain and \(spec.type == .openai ? "sent to that host" : "handed to the plugin").")
        }
        return out
    }
}

/// The provider plugins installed in this Anvil, their keys and sessions, and their models.
///
/// Plugins live in `~/Library/Application Support/Anvil/providers/<id>/` (fetched from GitHub or created
/// from a preset). Plugin authors can also link a folder they're working on; it's used in place.
@Observable
final class ProviderPlugins {
    static let shared = ProviderPlugins()

    private(set) var installed: [InstalledProvider] = []
    /// Models a plugin listed live (else its spec's static list is used).
    private(set) var liveModels: [String: [ProviderSpec.Model]] = [:]
    /// Per-plugin load or listing problems, shown in Settings.
    private(set) var problems: [String: String] = [:]

    @ObservationIgnored var root: URL = Paths.sub("providers")
    private var linksFile: URL { root.appendingPathComponent("links.json") }

    private init() { reload() }

    // MARK: Lookup

    func provider(_ id: String) -> InstalledProvider? { installed.first { $0.id == id } }

    /// The plugin a model id belongs to, and the model's own name at that provider.
    func route(_ model: String) -> (provider: InstalledProvider, model: String)? {
        guard let slash = model.firstIndex(of: "/") else { return nil }
        let id = String(model[..<slash])
        guard let p = provider(id) else { return nil }
        return (p, String(model[model.index(after: slash)...]))
    }

    func models(_ id: String) -> [ProviderSpec.Model] {
        guard let p = provider(id) else { return [] }
        if let live = liveModels[id], !live.isEmpty {
            // Live listing wins, but keep what the spec says about vision, context and prices.
            let known = Dictionary((p.spec.models ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            return live.map { m in known[m.id].map { k in var x = m; x.vision = x.vision ?? k.vision; x.context = x.context ?? k.context; x.input = x.input ?? k.input; x.output = x.output ?? k.output; x.name = x.name ?? k.name; return x } ?? m }
        }
        return p.spec.models ?? []
    }

    func modelInfo(_ model: String) -> ProviderSpec.Model? {
        guard let (p, name) = route(model) else { return nil }
        return models(p.id).first { $0.id == name }
    }

    func isReady(_ id: String) -> Bool {
        guard let p = provider(id) else { return false }
        switch p.spec.auth.type {
        case .none: return true
        case .apiKey: return p.spec.auth.optional == true || !apiKey(id).isEmpty
        case .web: return !session(id).isEmpty
        }
    }

    // MARK: Base URL

    /// The URL requests go to: the owner's own deployment when the spec allows it, else the spec's.
    func baseURL(_ p: InstalledProvider) -> String {
        if p.spec.editableBaseURL == true, let u = UserDefaults.standard.string(forKey: "provider.\(p.id).baseURL"), !u.isEmpty { return u }
        return p.spec.baseURL ?? ""
    }

    /// Saves (or with "" clears) the owner's base URL. Returns a problem, or nil.
    @discardableResult
    func setBaseURL(_ id: String, _ raw: String) -> String? {
        let u = raw.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !u.isEmpty && !ProviderSpec.isAllowedBaseURL(u) { return "Use an https URL, or http://localhost for a server on this Mac." }
        UserDefaults.standard.set(u.isEmpty ? nil : u, forKey: "provider.\(id).baseURL")
        liveModels[id] = nil
        problems[id] = nil
        Task { await refreshModels(id) }
        return nil
    }

    // MARK: Secrets

    func apiKey(_ id: String) -> String { Keychain.get("provider.\(id).key") ?? "" }

    func setAPIKey(_ id: String, _ key: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = Keychain.set(k.isEmpty ? nil : k, for: "provider.\(id).key")
        problems[id] = nil
        Task { await refreshModels(id) }
    }

    /// A web session: captured cookies and localStorage values.
    struct Session: Codable, Equatable, Sendable {
        var cookies: [String: String] = [:]
        var localStorage: [String: String] = [:]
        var isEmpty: Bool { cookies.isEmpty && localStorage.isEmpty }
    }

    func session(_ id: String) -> Session {
        guard let s = Keychain.get("provider.\(id).session"), let d = s.data(using: .utf8),
              let v = try? JSONDecoder().decode(Session.self, from: d) else { return Session() }
        return v
    }

    func setSession(_ id: String, _ s: Session?) {
        let text = s.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }
        _ = Keychain.set(s?.isEmpty == false ? text : nil, for: "provider.\(id).session")
        problems[id] = nil
    }

    /// The credentials a request carries: the key, or the session (and the bearer derived from it).
    func credentials(_ p: InstalledProvider) -> (key: String, session: Session) {
        let s = session(p.id)
        switch p.spec.auth.type {
        case .none: return ("", s)
        case .apiKey: return (apiKey(p.id), s)
        case .web:
            var bearer = ""
            if let b = p.spec.auth.bearer {
                if b.hasPrefix("localStorage:") { bearer = s.localStorage[String(b.dropFirst("localStorage:".count))] ?? "" }
                if b.hasPrefix("cookie:") { bearer = s.cookies[String(b.dropFirst("cookie:".count))] ?? "" }
            }
            return (bearer, s)
        }
    }

    // MARK: Loading

    func reload() {
        var list: [InstalledProvider] = []
        var bad: [String: String] = [:]
        let fm = FileManager.default
        let folders = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && !$0.lastPathComponent.hasPrefix(".") }
        for folder in folders {
            do {
                let spec = try ProviderSpec.load(folder.appendingPathComponent(ProviderSpec.fileName))
                let problems = spec.problems()
                guard problems.isEmpty else { bad[folder.lastPathComponent] = problems.joined(separator: "; "); continue }
                let meta = Self.readMeta(folder)
                list.append(InstalledProvider(spec: spec, folder: folder, source: meta.source, commit: meta.commit, linked: false))
            } catch {
                bad[folder.lastPathComponent] = (error as? ToolFailure)?.message ?? error.localizedDescription
            }
        }
        for path in linkedFolders() {
            let folder = URL(fileURLWithPath: path)
            do {
                let spec = try ProviderSpec.load(folder.appendingPathComponent(ProviderSpec.fileName))
                let problems = spec.problems()
                guard problems.isEmpty else { bad[folder.lastPathComponent] = problems.joined(separator: "; "); continue }
                guard !list.contains(where: { $0.id == spec.id }) else { bad[spec.id] = "linked folder \(path) has the same id as an installed plugin"; continue }
                list.append(InstalledProvider(spec: spec, folder: folder, source: Paths.display(folder, root: nil), commit: nil, linked: true))
            } catch {
                bad[folder.lastPathComponent] = (error as? ToolFailure)?.message ?? error.localizedDescription
            }
        }
        installed = list.sorted { $0.spec.name.localizedCaseInsensitiveCompare($1.spec.name) == .orderedAscending }
        problems = bad
    }

    private struct Meta: Codable { var source: String; var commit: String?; var installed: Date }
    private static let metaFile = ".anvil-source.json"

    private static func readMeta(_ folder: URL) -> (source: String, commit: String?) {
        guard let d = try? Data(contentsOf: folder.appendingPathComponent(metaFile)),
              let m = try? JSONDecoder().decode(Meta.self, from: d) else { return ("local", nil) }
        return (m.source, m.commit)
    }

    private func linkedFolders() -> [String] {
        guard let d = try? Data(contentsOf: linksFile), let l = try? JSONDecoder().decode([String].self, from: d) else { return [] }
        return l
    }

    private func saveLinks(_ l: [String]) {
        if let d = try? JSONEncoder().encode(Array(Set(l)).sorted()) { try? d.write(to: linksFile, options: .atomic) }
    }

    // MARK: Installing

    /// Fetches a plugin from GitHub into a temporary folder and validates it. Nothing is installed until `confirm`.
    func fetch(_ raw: String) async throws -> PendingProvider {
        guard let src = GitHubSource(raw) else {
            throw ToolFailure("That isn't a GitHub repository URL. Use https://github.com/owner/repo (optionally …/tree/branch/folder).")
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("anvil-provider-\(UUID().uuidString.prefix(8))")
        var args = ["clone", "--depth", "1", "--quiet"]
        if let ref = src.ref { args += ["--branch", ref] }
        args += [src.cloneURL, tmp.path]
        let r = await ProcessRunner.run("/usr/bin/git", args, timeout: 120)
        guard r.status == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            let msg = r.combined.contains("not found") || r.combined.contains("Repository not found") ? "repository not found (or it's private)" : Fmt.line(r.combined, 300)
            throw ToolFailure("Couldn't download \(src.display): \(msg)")
        }
        let commit = await ProcessRunner.run("/usr/bin/git", ["-C", tmp.path, "rev-parse", "HEAD"], timeout: 20).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = src.path.map { tmp.appendingPathComponent($0) } ?? tmp
        do {
            let spec = try ProviderSpec.load(folder.appendingPathComponent(ProviderSpec.fileName))
            let problems = spec.problems()
            guard problems.isEmpty else { throw ToolFailure("\(ProviderSpec.fileName) has problems: " + problems.joined(separator: "; ")) }
            return PendingProvider(spec: spec, folder: folder, source: src.display + " @ " + String(commit.prefix(7)), commit: commit,
                                   linked: false, replaces: provider(spec.id) != nil)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    /// A plugin folder on disk, used in place (for developing a plugin).
    func inspect(folder: URL) throws -> PendingProvider {
        let spec = try ProviderSpec.load(folder.appendingPathComponent(ProviderSpec.fileName))
        let problems = spec.problems()
        guard problems.isEmpty else { throw ToolFailure("\(ProviderSpec.fileName) has problems: " + problems.joined(separator: "; ")) }
        return PendingProvider(spec: spec, folder: folder, source: Paths.display(folder, root: nil), commit: nil, linked: true,
                               replaces: provider(spec.id) != nil)
    }

    /// Installs a fetched or inspected plugin (replacing one with the same id).
    func confirm(_ p: PendingProvider) throws {
        if let old = provider(p.id) { remove(old.id, keepSecrets: true) }
        if p.linked {
            saveLinks(linkedFolders().filter { $0 != p.folder.path } + [p.folder.path])
        } else {
            let dest = root.appendingPathComponent(p.id, isDirectory: true)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: p.folder, to: dest)
            try? FileManager.default.removeItem(at: dest.appendingPathComponent(".git"))
            let meta = Meta(source: p.source, commit: p.commit, installed: Date())
            try JSONEncoder().encode(meta).write(to: dest.appendingPathComponent(Self.metaFile))
            discard(p)
        }
        reload()
        Task { await refreshModels(p.id) }
    }

    /// Deletes a fetched plugin that wasn't confirmed.
    func discard(_ p: PendingProvider) {
        guard !p.linked else { return }
        var top = p.folder
        while top.deletingLastPathComponent().path != FileManager.default.temporaryDirectory.path && top.pathComponents.count > 2 {
            top = top.deletingLastPathComponent()
        }
        if top.lastPathComponent.hasPrefix("anvil-provider-") { try? FileManager.default.removeItem(at: top) }
    }

    /// Creates a plugin from one of the bundled presets.
    func add(preset spec: ProviderSpec) throws {
        let dest = root.appendingPathComponent(spec.id, isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(spec).write(to: dest.appendingPathComponent(ProviderSpec.fileName))
        try enc.encode(Meta(source: "preset", commit: nil, installed: Date())).write(to: dest.appendingPathComponent(Self.metaFile))
        reload()
    }

    func remove(_ id: String, keepSecrets: Bool = false) {
        guard let p = provider(id) else { return }
        ProviderServers.shared.stop(id)
        if p.linked { saveLinks(linkedFolders().filter { $0 != p.folder.path }) }
        else { try? FileManager.default.removeItem(at: p.folder) }
        if !keepSecrets { setSession(id, nil); _ = Keychain.set(nil, for: "provider.\(id).key") }
        liveModels[id] = nil
        reload()
    }

    /// Re-fetches a GitHub plugin from the same repository (shows the confirmation again if it changed).
    func checkForUpdate(_ id: String) async throws -> PendingProvider? {
        guard let p = provider(id), p.fromGitHub else { return nil }
        let url = p.source.components(separatedBy: " @ ").first ?? p.source
        let fresh = try await fetch(url)
        if fresh.commit == p.commit { discard(fresh); return nil }
        return fresh
    }

    // MARK: Presets

    /// Ready-made specs for popular OpenAI-compatible providers (Anvil/Providers/Presets/*.json).
    /// On the Mac app these come from the bundle. Elsewhere (and in SwiftPM builds, which have no app bundle) they come
    /// from `PresetData`, an embedded copy kept in sync by scripts/sync-presets.sh.
    static var presets: [ProviderSpec] {
#if canImport(Darwin) && !SWIFT_PACKAGE
        let urls = (Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("preset-") }
        return urls.compactMap { try? ProviderSpec.load($0) }.filter { $0.problems().isEmpty }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
#else
        return PresetData.files.filter { $0.key.hasPrefix("preset-") }
            .compactMap { try? ProviderSpec.load(data: Data($0.value.utf8)) }.filter { $0.problems().isEmpty }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
#endif
    }

    // MARK: Models

    func refreshModels() async {
        // Plugins with a local server are listed once their server runs, not started just to list models.
        for p in installed where isReady(p.id) && (p.spec.server == nil || ProviderServers.shared.state(p.id) == .running) {
            await refreshModels(p.id)
        }
    }

    func refreshModels(_ id: String) async {
        guard let p = provider(id), isReady(id) else { return }
        do {
            let list = try await ProviderClient(p).listModels()
            if !list.isEmpty { liveModels[id] = list }
            problems[id] = nil
        } catch {
            problems[id] = "couldn't list models: " + ((error as? BrainError)?.message ?? (error as? ToolFailure)?.message ?? error.localizedDescription)
        }
    }

    /// Saves cookies a process plugin reports as rotated.
    func updateSession(_ id: String, cookies: [String: String]) {
        guard !cookies.isEmpty else { return }
        var s = session(id)
        for (k, v) in cookies { s.cookies[k] = v.isEmpty ? nil : v }
        setSession(id, s)
    }
}
