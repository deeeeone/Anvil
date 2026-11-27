import Foundation

/// Collects pipe output and termination from Process callbacks (background threads).
nonisolated final class ProcCollector: @unchecked Sendable {
    struct Line: Sendable {
        let t: Double
        let channel: String
        let text: String
    }

    private let lock = NSLock()
    private var buffers: [String: Data] = [:]
    private var collected: [Line] = []
    private var eofChannels = Set<String>()
    private var exitT: Double?
    private var exitStatus: Int32 = -1

    nonisolated init() {}

    nonisolated func feed(_ channel: String, _ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        let t = nowMS()
        if data.isEmpty {
            if let rest = buffers[channel], !rest.isEmpty {
                emit(channel, rest, t)
            }
            buffers[channel] = nil
            eofChannels.insert(channel)
            return
        }
        var buf = buffers[channel] ?? Data()
        buf.append(data)
        while let nl = buf.firstIndex(of: 0x0A) {
            emit(channel, Data(buf[buf.startIndex..<nl]), t)
            buf.removeSubrange(buf.startIndex...nl)
        }
        buffers[channel] = buf
    }

    /// Must be called with the lock held.
    nonisolated private func emit(_ channel: String, _ data: Data, _ t: Double) {
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        collected.append(Line(t: t, channel: channel, text: text))
        print("  proc \(channel) at \(Int(t)) ms: \(text)")
    }

    nonisolated func exited(_ status: Int32) {
        lock.lock()
        defer { lock.unlock() }
        exitT = nowMS()
        exitStatus = status
    }

    nonisolated func isFinished() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return eofChannels.count == 2 && exitT != nil
    }

    nonisolated func eofState() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return eofChannels.sorted()
    }

    nonisolated func snapshot() -> (lines: [Line], exitT: Double?, status: Int32) {
        lock.lock()
        defer { lock.unlock() }
        return (collected, exitT, exitStatus)
    }
}

/// Finds an executable on PATH by hand (split on ";" on Windows, ":" elsewhere).
nonisolated func findExecutable(_ names: [String]) -> String? {
    #if os(Windows)
    let sep: Character = ";"
    let exts = [".exe", ""]
    #else
    let sep: Character = ":"
    let exts = [""]
    #endif
    let env = ProcessInfo.processInfo.environment
    let path = env["PATH"] ?? env["Path"] ?? ""
    for dir in path.split(separator: sep) {
        for name in names {
            for ext in exts {
                let url = URL(fileURLWithPath: String(dir)).appendingPathComponent(name + ext)
                if FileManager.default.fileExists(atPath: url.path) {
                    return url.path
                }
            }
        }
    }
    return nil
}

func runProc() async -> Bool {
    let exe: String
    let args: [String]
    #if os(Windows)
    exe = findExecutable(["pwsh", "powershell"]) ?? "powershell.exe"
    args = [
        "-NoProfile", "-Command",
        "Write-Output one; Start-Sleep -Milliseconds 1000; Write-Output two; [Console]::Error.WriteLine('err')",
    ]
    #else
    exe = "/bin/sh"
    args = ["-c", "echo one; sleep 1; echo two; echo err 1>&2"]
    #endif

    let collector = ProcCollector()
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: exe)
    proc.arguments = args
    let outPipe = Pipe()
    let errPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = errPipe

    // Blocking reads on a background queue instead of readabilityHandler:
    // swift-corelibs-foundation never delivers the empty-Data EOF callback.
    for (name, pipe) in [("out", outPipe), ("err", errPipe)] {
        let h = pipe.fileHandleForReading
        DispatchQueue.global().async { @Sendable in
            while true {
                let d = h.availableData
                collector.feed(name, d)
                if d.isEmpty { break }
            }
        }
    }
    proc.terminationHandler = { @Sendable p in
        collector.exited(p.terminationStatus)
    }

    do {
        try proc.run()
    } catch {
        return report(false, "proc", "launch failed (\(exe)): \(error)")
    }

    var waited = 0
    while !collector.isFinished() && waited < 15_000 {
        try? await Task.sleep(for: .milliseconds(20))
        waited += 20
    }
    if !collector.isFinished() {
        let snap = collector.snapshot()
        let eof = collector.eofState()
        proc.terminate()
        return report(false, "proc", "timed out: exitHandlerFired=\(snap.exitT != nil) isRunning=\(proc.isRunning) eof=\(eof)")
    }

    let snap = collector.snapshot()
    guard let exitT = snap.exitT else {
        return report(false, "proc", "no termination timestamp")
    }
    let one = snap.lines.first { $0.channel == "out" && $0.text == "one" }
    let two = snap.lines.first { $0.channel == "out" && $0.text == "two" }
    let err = snap.lines.first { $0.channel == "err" && $0.text == "err" }
    guard let oneT = one?.t else {
        return report(false, "proc", "'one' never arrived")
    }
    let lead = exitT - oneT
    let ok = lead >= 700 && two != nil && err != nil && snap.status == 0
    return report(
        ok, "proc",
        "'one' arrived \(Int(lead)) ms before termination (need >=700); two=\(two != nil) err=\(err != nil) status=\(snap.status)"
    )
}
