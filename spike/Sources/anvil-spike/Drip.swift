import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Counts raw body deliveries from a real HTTPS endpoint that trickles bytes out over time.
nonisolated final class DripDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var stamps: [Double] = []
    private var bytes = 0
    private let done: AsyncStream<Void>.Continuation
    let start = nowMS()

    nonisolated init(done: AsyncStream<Void>.Continuation) { self.done = done; super.init() }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); stamps.append(nowMS() - start); bytes += data.count; lock.unlock()
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { print("  https-drip error: \(error)") }
        done.finish()
    }

    nonisolated func result() -> (stamps: [Double], bytes: Int) {
        lock.lock(); defer { lock.unlock() }; return (stamps, bytes)
    }
}

func runDrip(_ url: URL) async -> Bool {
    let (stream, cont) = AsyncStream.makeStream(of: Void.self)
    let d = DripDelegate(done: cont)
    let session = URLSession(configuration: .default, delegate: d, delegateQueue: nil)
    var req = URLRequest(url: url)
    req.timeoutInterval = 20
    session.dataTask(with: req).resume()
    for await _ in stream {}
    session.finishTasksAndInvalidate()
    let r = d.result()
    let spread = (r.stamps.last ?? 0) - (r.stamps.first ?? 0)
    return report(r.stamps.count >= 3 && spread >= 300, "https-drip",
                  "\(r.stamps.count) deliveries, \(r.bytes) bytes, spread \(Int(spread)) ms at \(r.stamps.map { Int($0) })")
}
