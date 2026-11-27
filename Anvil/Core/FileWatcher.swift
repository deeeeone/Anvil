import Foundation
#if canImport(CoreServices)
import CoreServices
#endif

/// Watches a folder tree with FSEvents and calls back (on the main queue) when something changes,
/// ignoring churn inside .git and dependency/build folders.
final class FileWatcher {
    private let onChange: () -> Void
    let path: String
    /// The paths of the last relevant batch (for debugging and tests).
    var lastPaths: [String] = []

    /// The watched folder with symlinks resolved (FSEvents reports /private/var, not /var).
    private let resolved: String

#if canImport(CoreServices)
    private var stream: FSEventStreamRef?

    init?(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        self.onChange = onChange
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let relevant = list.prefix(count).contains { p in
                p != me.path && p != me.resolved && p != me.resolved + "/" && !p.contains("/.git/") && !p.hasSuffix("/.git") && !ProjectContext.skipDirs.contains { p.contains("/\($0)/") }
            }
            if relevant { MainActor.assumeIsolated { me.lastPaths = Array(list.prefix(count)); me.onChange() } }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, callback, &ctx, [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25, flags) else { return nil }
        stream = s
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        FSEventStreamStart(s)
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }
#else
    // TODO(linux): polling watcher. Compares modification dates under the root once a second (depth-limited,
    // skipping .git and dependency/build folders), instead of FSEvents.
    private var timer: Timer?
    private var snapshot: [String: Date] = [:]
    private static let maxDepth = 8

    init?(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        self.onChange = onChange
        snapshot = Self.scan(resolved)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        let now = Self.scan(resolved)
        let changed = Set(now.keys).union(snapshot.keys).filter { now[$0] != snapshot[$0] }
        guard !changed.isEmpty else { return }
        snapshot = now
        lastPaths = changed.sorted()
        onChange()
    }

    private static func scan(_ root: String) -> [String: Date] {
        var out: [String: Date] = [:]
        let rootURL = URL(fileURLWithPath: root)
        let depth0 = rootURL.pathComponents.count
        guard let en = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: [.contentModificationDateKey], options: []) else { return out }
        for case let u as URL in en {
            let depth = u.pathComponents.count - depth0
            if u.lastPathComponent == ".git" || ProjectContext.skipDirs.contains(u.lastPathComponent) { en.skipDescendants(); continue }
            if depth > maxDepth { en.skipDescendants(); continue }
            out[u.path] = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        }
        return out
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
#endif

    deinit { stop() }
}
