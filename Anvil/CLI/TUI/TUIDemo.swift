import Foundation

/// Manual test harness for the TUI kit (`anvil tui-demo`). It shows a live status line and the input box, commits each
/// submitted line, streams a fake reply into the live region word by word, and quits on Ctrl-D or a second Ctrl-C on
/// an empty line. The terminal is restored on every exit path.
enum TUIDemo {
    private enum Event {
        case key(Key)
        case tick
        case resize
    }

    static func run() async -> Int32 {
        let term = TUITerminal()
        guard term.isInputTTY else {
            print("tui-demo needs an interactive terminal: stdin is not a TTY.")
            return 2
        }
        guard term.enterRawMode() else {
            print("tui-demo could not switch the terminal to raw mode.")
            return 2
        }
        defer { term.restore() }

        let live = LiveScreen(interactive: true, write: { term.write($0) }, size: { term.size() })
        let (events, continuation) = AsyncStream.makeStream(of: Event.self)
        term.onResize = { continuation.yield(.resize) }
        let keyTask = Task {
            for await key in term.keys() { continuation.yield(.key(key)) }
        }
        let tickTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 80_000_000)
                continuation.yield(.tick)
            }
        }
        defer {
            keyTask.cancel()
            tickTask.cancel()
            continuation.finish()
        }

        let model = DemoModel(term: term, live: live)
        model.redraw()
        loop: for await event in events {
            switch event {
            case .key(let key):
                if model.handle(key) == false { break loop }
            case .tick:
                model.tick()
            case .resize:
                live.resized()
                model.redraw()
            }
        }

        live.clearLive()
        live.commit([Ansi.dim("demo ended")])
        live.finish()
        return 0
    }
}

/// The demo's state. Lives on the main actor with the event loop.
private final class DemoModel {
    private static let replyText = "You said something, and this reply streams word by word into the live region while the spinner turns and the input box keeps working."

    private let term: TUITerminal
    private let live: LiveScreen
    private var editor = LineEditor()
    private var frameIndex = 0
    private let started = Date()
    private var queue: [String] = []
    private var streamWords: [String] = []
    private var streamed = 0
    private var isStreaming = false
    private var quitArmed = false
    private let defaultHint = "type and press Enter · Ctrl-D to quit"
    private var hint = "type and press Enter · Ctrl-D to quit"

    init(term: TUITerminal, live: LiveScreen) {
        self.term = term
        self.live = live
        editor.placeholder = "say something"
    }

    /// Returns false when the demo should quit.
    func handle(_ key: Key) -> Bool {
        let wasArmed = quitArmed
        quitArmed = false
        hint = defaultHint
        let action = editor.handle(key)
        switch action {
        case .submit(let text):
            // State first, then redraw (which queues a fresh frame), then commit, so commit draws the new region.
            queue.append(text)
            if !isStreaming { startNextReply() }
            redraw()
            live.commit([Ansi.dim("› " + text)])
            return true
        case .cancel:
            if wasArmed { return false }
            quitArmed = true
            hint = "press Ctrl-C again to quit"
        case .eof:
            return false
        case .changed, .none:
            break
        }
        redraw()
        return true
    }

    /// Advances the spinner and the streamed reply. Runs every 80 ms.
    func tick() {
        frameIndex += 1
        if isStreaming {
            // Two words per tick: about 2 s for the whole reply.
            streamed = min(streamed + 2, streamWords.count)
            if streamed >= streamWords.count {
                let reply = streamWords.joined(separator: " ")
                isStreaming = false
                streamWords = []
                streamed = 0
                startNextReply()
                redraw()
                live.commit([reply])
                return
            }
        }
        redraw()
    }

    private func startNextReply() {
        guard !queue.isEmpty else { return }
        let prompt = queue.removeFirst()
        streamWords = (DemoModel.replyText + " (re: " + prompt + ")").split(separator: " ").map(String.init)
        streamed = 0
        isStreaming = true
    }

    func redraw() {
        let width = max(1, term.size().cols - 1)
        let elapsed = Spinner.elapsed(Date().timeIntervalSince(started))
        let state = isStreaming ? "streaming" : "idle"
        let status = "\(Spinner.frame(at: frameIndex)) \(state) \(elapsed) · demo · \(hint)"
        var lines = [Ansi.cyan(Ansi.truncate(status, width: width))]
        if isStreaming {
            let shown = streamWords.prefix(streamed).joined(separator: " ")
            let tail = Ansi.wrap(shown + "▍", width: width).suffix(4)
            lines += Array(tail)
        }
        let base = lines.count
        let box = editor.render(width: width, prompt: "› ", continuation: "  ")
        lines += box.lines
        live.setLiveThrottled(lines, cursor: (row: base + box.cursorRow, col: box.cursorCol))
    }
}
