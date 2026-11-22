import Foundation

/// Keeps long sessions inside the context window: slims old turns in batches (prompt-cache friendly) and,
/// past a threshold, replaces the history with a model-written summary.
nonisolated enum Compactor {
    /// Token estimate for a conversation. Uses the characters-per-token ratio measured for `model` from the provider's own
    /// usage figures (see TokenCalibrator), 3.5 until a call has been measured.
    static func estimateTokens(_ messages: [ChatMessage], model: String? = nil, calibrator: TokenCalibrator = .shared) -> Int {
        calibrator.tokens(chars: messages.reduce(0) { $0 + $1.charCount }, model: model)
    }

    static func shouldCompact(_ messages: [ChatMessage], limit: Int, model: String? = nil) -> Bool {
        messages.count > 6 && estimateTokens(messages, model: model) > limit
    }

    /// Before appending a user turn: drop images from earlier turns, and every 10 messages clip big text parts in all
    /// but the newest 8. Batching keeps earlier history byte-identical between most calls so the provider cache hits.
    static func slim(_ messages: inout [ChatMessage]) {
        for i in messages.indices where messages[i].hasImage {
            messages[i].parts = messages[i].parts.filter { if case .image = $0 { return false } else { return true } } + [.text("[image omitted]")]
        }
        if messages.count > 9 && messages.count % 10 == 0 {
            for i in 1..<(messages.count - 8) {
                messages[i].parts = messages[i].parts.map {
                    if case .text(let t) = $0, t.count > 5000 { return .text(Fmt.clip(t, max: 3000)) } else { return $0 }
                }
            }
        }
    }

    static func summaryRequest(_ messages: [ChatMessage], focus: String? = nil) -> [ChatMessage] {
        var history = messages
        // History must end with a user turn; if the model spoke last, the request is appended as a new user turn.
        let ask = """
        <compact>
        The conversation is being compacted to save context. Write a summary that lets you continue the work without the \
        earlier messages. Include: the owner's requests and preferences; what has been done (files created or changed, \
        with paths); key decisions and why; commands that build, run and test the project; current state of tests; \
        open problems and the exact next steps. Be specific and concise (at most ~600 words). Plain text, no JSON, no dashes as bullets are fine.
        \(focus.map { "Pay special attention to: \($0)" } ?? "")
        </compact>
        """
        if history.last?.role == "user" {
            history[history.count - 1].parts.append(.text("\n\n" + ask))
        } else {
            history.append(.user(ask))
        }
        return history
    }

    /// The compacted history: the fixed briefing plus the summary as one user turn, and a short assistant ack so turns still alternate.
    static func compacted(briefing: String, summary: String) -> [ChatMessage] {
        let user = briefing + "\n\nSUMMARY OF THE CONVERSATION SO FAR (earlier turns were compacted to save context)\n"
            + summary.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        let ack = "I have the summary and will continue from it.\n```json\n{\"say\": \"Ready to continue.\", \"actions\": [], \"done\": true}\n```"
        return [.user(user), .assistant(ack)]
    }
}
