import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A response body read through a URLSession data delegate. Linux and Windows Foundation have no
/// `URLSession.bytes(for:)`, so the non-Darwin shim below returns this instead. Its elements are bytes, like Apple's
/// `AsyncBytes`, and `lines` splits them the same way (LF, with a trailing CR removed, and a final unterminated line kept).
nonisolated enum HTTPLines {
    /// Starts `request` on a session with the same configuration as `session` and returns once the response
    /// headers arrive. The body streams in as the server sends it; cancelling the consumer cancels the request.
    static func body(for request: URLRequest, using session: URLSession) async throws -> (URLResponse, Body) {
        let (chunks, chunkContinuation) = AsyncThrowingStream.makeStream(of: Data.self, throwing: Error.self)
        let delegate = Delegate(chunks: chunkContinuation)
        let owned = URLSession(configuration: session.configuration, delegate: delegate, delegateQueue: nil)
        let task = owned.dataTask(with: request)
        chunkContinuation.onTermination = { @Sendable _ in task.cancel() }
        let response: URLResponse = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { head in
                delegate.setHead(head)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        return (response, Body(chunks: chunks))
    }

    /// The raw body bytes, plus `lines` for line-oriented readers.
    nonisolated struct Body: AsyncSequence, Sendable {
        typealias Element = UInt8
        let chunks: AsyncThrowingStream<Data, Error>

        nonisolated struct Iterator: AsyncIteratorProtocol {
            var chunks: AsyncThrowingStream<Data, Error>.AsyncIterator
            var current: [UInt8] = []
            var index = 0

            mutating func next() async throws -> UInt8? {
                while index >= current.count {
                    guard let chunk = try await chunks.next() else { return nil }
                    current = [UInt8](chunk)
                    index = 0
                }
                defer { index += 1 }
                return current[index]
            }
        }

        nonisolated func makeAsyncIterator() -> Iterator {
            Iterator(chunks: chunks.makeAsyncIterator())
        }

        /// The body split into lines. Each line is yielded as soon as its newline arrives.
        var lines: AsyncThrowingStream<String, Error> {
            let source = chunks
            return AsyncThrowingStream { continuation in
                let task = Task {
                    var buffer = Data()
                    do {
                        for try await chunk in source {
                            buffer.append(chunk)
                            while let newline = buffer.firstIndex(of: 0x0A) {
                                var line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                                buffer.removeSubrange(buffer.startIndex...newline)
                                if line.hasSuffix("\r") { line.removeLast() }
                                continuation.yield(line)
                            }
                        }
                        if !buffer.isEmpty {
                            var line = String(decoding: buffer, as: UTF8.self)
                            if line.hasSuffix("\r") { line.removeLast() }
                            continuation.yield(line)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { @Sendable _ in task.cancel() }
            }
        }
    }

    /// URLSession calls these on its own delegate queue, so they are nonisolated and the shared state is lock-guarded.
    nonisolated final class Delegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var head: CheckedContinuation<URLResponse, Error>?
        private let chunks: AsyncThrowingStream<Data, Error>.Continuation

        nonisolated init(chunks: AsyncThrowingStream<Data, Error>.Continuation) {
            self.chunks = chunks
            super.init()
        }

        nonisolated func setHead(_ continuation: CheckedContinuation<URLResponse, Error>) {
            lock.lock(); defer { lock.unlock() }
            head = continuation
        }

        nonisolated private func takeHead() -> CheckedContinuation<URLResponse, Error>? {
            lock.lock(); defer { lock.unlock() }
            let pending = head
            head = nil
            return pending
        }

        nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            completionHandler(.allow)
            takeHead()?.resume(returning: response)
        }

        nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            chunks.yield(data)
        }

        nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { chunks.finish(throwing: error) } else { chunks.finish() }
            takeHead()?.resume(throwing: error ?? URLError(.badServerResponse))
            session.finishTasksAndInvalidate()
        }
    }
}

#if !canImport(Darwin)
extension URLSession {
    /// The Linux and Windows stand-in for Darwin's `URLSession.bytes(for:)`, so callers keep one code path.
    typealias AsyncBytes = HTTPLines.Body

    func bytes(for request: URLRequest) async throws -> (AsyncBytes, URLResponse) {
        let (response, body) = try await HTTPLines.body(for: request, using: self)
        return (body, response)
    }
}
#endif
