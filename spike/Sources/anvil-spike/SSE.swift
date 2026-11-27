import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Delegate-based SSE reader. URLSession calls these on its own delegate queue,
/// so everything here is explicitly nonisolated and the buffer is lock-guarded.
nonisolated final class SSEDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let continuation: AsyncStream<String>.Continuation
    private let lock = NSLock()
    private var buffer = Data()

    nonisolated init(continuation: AsyncStream<String>.Continuation) {
        self.continuation = continuation
        super.init()
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [String] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            var line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...nl)
            if line.hasSuffix("\r") { line.removeLast() }
            if line.hasPrefix("data:") { lines.append(line) }
        }
        lock.unlock()
        for line in lines {
            continuation.yield(line)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        continuation.finish()
        session.finishTasksAndInvalidate()
    }
}

nonisolated func makeSSERequest(_ url: URL) -> URLRequest {
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    req.httpBody = Data(#"{"stream":true}"#.utf8)
    req.timeoutInterval = 20
    return req
}

nonisolated func checkSSE(_ name: String, lines: [String], stamps: [Double]) -> Bool {
    let span = (stamps.last ?? 0) - (stamps.first ?? 0)
    let ok = lines.count >= 3 && span >= 300
    return report(ok, name, "\(lines.count) data events, first-to-last \(Int(span)) ms (need >=3 events and >=300 ms)")
}

/// Reader (a): URLSession.bytes(for:). Not available with FoundationNetworking (Linux/Windows).
func runSSEBytes(_ url: URL) async -> Bool {
#if !canImport(FoundationNetworking)
    let start = nowMS()
    do {
        let (bytes, _) = try await URLSession.shared.bytes(for: makeSSERequest(url))
        var lines: [String] = []
        var stamps: [Double] = []
        for try await line in bytes.lines where line.hasPrefix("data:") {
            let t = nowMS() - start
            lines.append(line)
            stamps.append(t)
            print("  sse-bytes event \(lines.count) at \(Int(t)) ms: \(line)")
        }
        return checkSSE("sse-bytes", lines: lines, stamps: stamps)
    } catch {
        return report(false, "sse-bytes", "request failed: \(error)")
    }
#else
    skip("sse-bytes", "bytes(for:) unavailable")
    return true
#endif
}

/// Reader (b): delegate + AsyncStream. Works on all platforms.
func runSSEDelegate(_ url: URL) async -> Bool {
    let (stream, continuation) = AsyncStream.makeStream(of: String.self)
    let delegate = SSEDelegate(continuation: continuation)
    let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
    let start = nowMS()
    session.dataTask(with: makeSSERequest(url)).resume()

    var lines: [String] = []
    var stamps: [Double] = []
    for await line in stream {
        let t = nowMS() - start
        lines.append(line)
        stamps.append(t)
        print("  sse-delegate event \(lines.count) at \(Int(t)) ms: \(line)")
    }
    session.finishTasksAndInvalidate()
    return checkSSE("sse-delegate", lines: lines, stamps: stamps)
}

func runSSE(url: URL) async -> Bool {
    let bytesOK = await runSSEBytes(url)
    let delegateOK = await runSSEDelegate(url)
    return bytesOK && delegateOK
}
