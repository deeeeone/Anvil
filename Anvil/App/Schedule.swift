import Foundation

/// An instruction to run later (once) or on a repeat. When it's due it goes into the background queue, so it runs
/// in its own git worktree like any queued task. Anvil has to be open for it to fire; anything that came due while
/// it was closed runs once at the next launch.
nonisolated struct ScheduledTask: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var prompt: String
    var next: Date
    /// Repeat every this many seconds (nil = once, or daily when `dailyMinutes` is set).
    var interval: Double?
    /// Repeat every day at this many minutes after midnight, local time.
    var dailyMinutes: Int?
    var created = Date()

    var isRecurring: Bool { interval != nil || dailyMinutes != nil }

    var repeatLabel: String {
        if let m = dailyMinutes { return "every day at \(ScheduleParser.clock(m))" }
        if let i = interval { return "every \(ScheduleParser.duration(i))" }
        return "once"
    }

    /// The run after `next` (nil for one-time tasks).
    func following(after now: Date, calendar: Calendar = .current) -> Date? {
        if let i = interval {
            var n = next.addingTimeInterval(i)
            if n <= now { n = now.addingTimeInterval(i) }   // skip runs missed while Anvil was closed
            return n
        }
        if let m = dailyMinutes { return ScheduleParser.nextDaily(minutes: m, after: now, calendar: calendar) }
        return nil
    }
}

nonisolated enum ScheduleParser {
    static let usage = """
    /schedule in 30m <task>       once, after a delay (s, m, h, d)
    /schedule at 14:30 <task>     once, at the next 14:30
    /schedule every 2h <task>     repeatedly (at least every 5m)
    /schedule daily at 09:00 <task>
    /schedule list    /schedule cancel <number>
    Runs go to the background queue, in their own worktree. Anvil must be open.
    """

    enum Result: Equatable {
        case add(ScheduledTask)
        case list
        case cancel(Int)
        case invalid(String)
    }

    static func parse(_ args: String, now: Date = Date(), calendar: Calendar = .current) -> Result {
        let text = args.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if text.isEmpty || lower == "list" || lower == "ls" { return .list }
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        if ["cancel", "remove", "rm", "delete"].contains(words[0].lowercased()) {
            guard words.count > 1, let n = Int(words[1]), n > 0 else { return .invalid("Say which one: /schedule cancel <number> (see /schedule list).") }
            return .cancel(n)
        }
        func task(from index: Int) -> String { words.dropFirst(index).joined(separator: " ") }

        switch words[0].lowercased() {
        case "in":
            guard words.count > 1, let (secs, used) = delay(Array(words.dropFirst())) else { return .invalid("How long? For example: /schedule in 30m run the tests") }
            let t = task(from: 1 + used)
            guard !t.isEmpty else { return .invalid("What should it do? /schedule in 30m <task>") }
            return .add(ScheduledTask(prompt: t, next: now.addingTimeInterval(secs)))
        case "at":
            guard words.count > 1, let m = minutesOfDay(words[1]) else { return .invalid("Use a 24-hour time, like /schedule at 14:30 <task>") }
            let t = task(from: 2)
            guard !t.isEmpty else { return .invalid("What should it do? /schedule at 14:30 <task>") }
            return .add(ScheduledTask(prompt: t, next: nextDaily(minutes: m, after: now, calendar: calendar)))
        case "daily", "every":
            let daily = words[0].lowercased() == "daily" || (words.count > 1 && ["day", "daily"].contains(words[1].lowercased()))
            if daily {
                var i = words[0].lowercased() == "daily" ? 1 : 2
                if i < words.count, words[i].lowercased() == "at" { i += 1 }
                guard i < words.count, let m = minutesOfDay(words[i]) else { return .invalid("Which time? /schedule daily at 09:00 <task>") }
                let t = task(from: i + 1)
                guard !t.isEmpty else { return .invalid("What should it do? /schedule daily at 09:00 <task>") }
                return .add(ScheduledTask(prompt: t, next: nextDaily(minutes: m, after: now, calendar: calendar), dailyMinutes: m))
            }
            guard words.count > 1, let (secs, used) = delay(Array(words.dropFirst())) else { return .invalid("How often? For example: /schedule every 2h check for new issues") }
            guard secs >= 300 else { return .invalid("Repeats must be at least 5 minutes apart.") }
            let t = task(from: 1 + used)
            guard !t.isEmpty else { return .invalid("What should it do? /schedule every 2h <task>") }
            return .add(ScheduledTask(prompt: t, next: now.addingTimeInterval(secs), interval: secs))
        default:
            return .invalid(usage)
        }
    }

    /// "30m", "2h", "1d", "45s", or "10 minutes": seconds, and how many words it used.
    static func delay(_ words: [String]) -> (Double, Int)? {
        guard let first = words.first?.lowercased() else { return nil }
        var number = "", unit = ""
        var used = 1
        for ch in first { if ch.isNumber || ch == "." { number.append(ch) } else { unit.append(ch) } }
        if unit.isEmpty, words.count > 1 { unit = words[1].lowercased(); used = 2 }
        guard let n = Double(number), n > 0 else { return nil }
        let table: [(Set<String>, Double)] = [(["s", "sec", "secs", "second", "seconds"], 1), (["m", "min", "mins", "minute", "minutes"], 60),
                                              (["h", "hr", "hrs", "hour", "hours"], 3600), (["d", "day", "days"], 86400)]
        guard let mult = table.first(where: { $0.0.contains(unit) })?.1 else { return nil }
        return (n * mult, used)
    }

    static func minutesOfDay(_ s: String) -> Int? {
        var t = s.lowercased()
        var pm: Bool?
        if t.hasSuffix("am") { pm = false; t.removeLast(2) } else if t.hasSuffix("pm") { pm = true; t.removeLast(2) }
        let parts = t.split(separator: ":").map(String.init)
        guard parts.count <= 2, var h = Int(parts[0]), h >= 0, h <= 23 else { return nil }
        let m = parts.count == 2 ? Int(parts[1]) : 0
        guard let m, m >= 0, m < 60 else { return nil }
        if let pm { guard h >= 1, h <= 12 else { return nil }; h = h % 12 + (pm ? 12 : 0) }
        return h * 60 + m
    }

    static func nextDaily(minutes: Int, after now: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: now)
        let today = calendar.date(byAdding: .minute, value: minutes, to: start) ?? now
        return today > now ? today : (calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86400))
    }

    static func clock(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }

    static func duration(_ secs: Double) -> String {
        if secs >= 86400, secs.truncatingRemainder(dividingBy: 86400) == 0 { return "\(Int(secs / 86400))d" }
        if secs >= 3600, secs.truncatingRemainder(dividingBy: 3600) == 0 { return "\(Int(secs / 3600))h" }
        return "\(Int(secs / 60))m"
    }
}

extension AppState {
    private var scheduleFile: URL? {
        guard let project else { return nil }
        return Paths.dir(Paths.sub("projects").appendingPathComponent(SessionStore.projectKey(project))).appendingPathComponent("schedules.json")
    }

    func loadSchedules() {
        guard let f = scheduleFile, let d = try? Data(contentsOf: f) else { schedules = []; return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        schedules = (try? dec.decode([ScheduledTask].self, from: d)) ?? []
    }

    private func saveSchedules() {
        guard let f = scheduleFile else { return }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(schedules) { try? d.write(to: f, options: .atomic) }
    }

    func addSchedule(_ t: ScheduledTask) {
        schedules.append(t)
        schedules.sort { $0.next < $1.next }
        saveSchedules()
        startScheduleTimer()
    }

    @discardableResult
    func cancelSchedule(number: Int) -> ScheduledTask? {
        guard number >= 1, number <= schedules.count else { return nil }
        let t = schedules.remove(at: number - 1)
        saveSchedules()
        return t
    }

    /// Checks every 20 seconds while the project is open; due tasks go to the background queue.
    func startScheduleTimer() {
        scheduleTimer?.cancel()
        guard !schedules.isEmpty else { return }
        scheduleTimer = Task { [weak self] in
            while !Task.isCancelled {
                self?.runDueSchedules()
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    func runDueSchedules(now: Date = Date()) {
        var changed = false
        for t in schedules where t.next <= now {
            enqueue(t.prompt)
            Notifier.shared.post(id: "sched-\(t.id)", title: "Scheduled task started", body: Fmt.line(t.prompt, 100), category: "done", session: "")
            changed = true
        }
        guard changed else { return }
        schedules = schedules.compactMap { t in
            guard t.next <= now else { return t }
            guard let n = t.following(after: now) else { return nil }
            var u = t; u.next = n; return u
        }.sorted { $0.next < $1.next }
        saveSchedules()
        if schedules.isEmpty { scheduleTimer?.cancel() }
    }

    func scheduleSummary() -> String {
        if schedules.isEmpty { return "Nothing scheduled.\n\n" + ScheduleParser.usage }
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return "Scheduled (Anvil must be open):\n" + schedules.enumerated().map { i, t in
            "\(i + 1). \(f.string(from: t.next)) · \(t.repeatLabel) · \(Fmt.line(t.prompt, 90))"
        }.joined(separator: "\n") + "\n/schedule cancel <number> removes one."
    }
}
