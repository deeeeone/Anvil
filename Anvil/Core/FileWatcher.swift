import Foundation
import CoreServices

/// Watches a folder tree with FSEvents and calls back (on the main queue) when something changes,
/// ignoring churn inside .git and dependency/build folders.
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void
    let path: String

    init?(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let relevant = list.prefix(count).contains { p in
                !p.contains("/.git/") && !p.hasSuffix("/.git") && !ProjectContext.skipDirs.contains { p.contains("/\($0)/") }
            }
            if relevant { MainActor.assumeIsolated { me.onChange() } }
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

    deinit { stop() }
}
