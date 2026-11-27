import SwiftUI

/// Goal text and colour choices as pure functions, so the panel, the sidebar, /goal status and the tests agree.
nonisolated enum GoalSummary {
    enum Tone: Equatable { case accent, amber, green, red, neutral }

    /// The phase chip's text and tone.
    static func chip(_ phase: GoalState.Phase) -> (text: String, tone: Tone) {
        switch phase {
        case .planning: return ("Planning", .neutral)
        case .working: return ("Working", .accent)
        case .checking: return ("Checking", .accent)
        case .fixing: return ("Fixing", .amber)
        case .waitingForProvider: return ("Waiting for provider", .amber)
        case .waitingForOwner: return ("Waiting for you", .amber)
        case .done: return ("Done", .green)
        case .stopped: return ("Stopped", .red)
        }
    }

    /// A goal still going or waiting: its panel stays up and the sidebar shows the scope symbol.
    static func isLive(_ phase: GoalState.Phase) -> Bool { phase != .done && phase != .stopped }

    /// "2 of 5 criteria met", or "No criteria yet".
    static func criteriaLine(_ criteria: [GoalCriterion]) -> String {
        guard !criteria.isEmpty else { return "No criteria yet" }
        return "\(criteria.filter { $0.met == true }.count) of \(criteria.count) criteria met"
    }

    /// "38 min of 240 · $0.120", with "of $1.00" after the cost when there is a cost limit.
    static func budgetLine(_ spent: GoalSpent, _ budget: GoalBudget) -> String {
        var line = "\(Int(spent.minutes)) min of \(budget.maxMinutes) · " + Fmt.dollars(spent.cost)
        if budget.maxCost > 0 { line += " of " + Fmt.dollars(budget.maxCost) }
        return line
    }

    /// Why a goal is waiting (the latest recovery entry), or nil when it isn't waiting.
    static func waitingReason(_ goal: GoalState) -> String? {
        guard goal.phase == .waitingForProvider || goal.phase == .waitingForOwner else { return nil }
        return goal.recovery.last.map { Fmt.line($0, 160) }
    }

    /// The /goal status summary: phase, criteria, spending, the last three recovery entries (newest first) and what is open.
    static func statusText(_ goal: GoalState) -> String {
        var lines = ["Goal: " + Fmt.line(goal.objective, 160)]
        lines.append("Phase: \(chip(goal.phase).text) (round \(goal.rounds))")
        lines.append("Criteria: " + criteriaLine(goal.criteria))
        lines.append("Spent: " + budgetLine(goal.spent, goal.budget))
        if !goal.recovery.isEmpty {
            lines.append("Recovery, newest first:")
            lines += goal.recovery.suffix(3).reversed().map { "- " + Fmt.line($0, 160) }
        }
        if !goal.unresolved.isEmpty { lines.append("Unresolved: " + goal.unresolved.joined(separator: "; ")) }
        if let branch = goal.branch { lines.append("Branch: \(branch)") }
        return lines.joined(separator: "\n")
    }

    /// The goal the panel shows: a live goal always, an ended one until the owner dismisses it (dismissed is its start time).
    static func shown(_ goal: GoalState?, dismissed: Date?) -> GoalState? {
        guard let goal else { return nil }
        if isLive(goal.phase) { return goal }
        return dismissed == goal.startedAt ? nil : goal
    }
}

extension GoalSummary.Tone {
    var color: Color {
        switch self {
        case .accent: return Theme.accent
        case .amber: return Theme.amber
        case .green: return Theme.green
        case .red: return Theme.red
        case .neutral: return Theme.text2
        }
    }
}

/// The goal card above the composer: phase, budget, the definition of done, and the recovery log.
struct GoalPanel: View {
    let controller: SessionController
    let goal: GoalState
    var onDismiss: () -> Void = {}
    @Environment(AppState.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showLog = false

    private var anim: Animation? { reduceMotion ? nil : .snappy(duration: 0.22) }

    /// Spent so far, with the round in progress counted in. Redrawn when the session changes, not every second.
    private var spent: GoalSpent {
        guard GoalSummary.isLive(goal.phase), controller.running else { return goal.spent }
        var s = goal.spent
        s.minutes += Date().timeIntervalSince(goal.lastTick) / 60
        s.cost = max(s.cost, controller.session.usage.cost - goal.costBase)
        return s
    }

    var body: some View {
        let chip = GoalSummary.chip(goal.phase)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "scope").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                Text("Goal").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                Text(chip.text)
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(chip.tone.color)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(chip.tone.color.opacity(0.14)))
                    .animation(anim, value: goal.phase)
                if goal.rounds > 0 { Text("round \(goal.rounds)").font(.system(size: 12)).foregroundStyle(Theme.text3) }
                Spacer(minLength: 6)
                Text(GoalSummary.budgetLine(spent, goal.budget))
                    .font(.system(size: 12, design: .monospaced)).monospacedDigit().foregroundStyle(Theme.text3)
                    .lineLimit(1)
                if !GoalSummary.isLive(goal.phase) {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.text3)
                    }
                    .buttonStyle(.plain).help("Dismiss").accessibilityLabel("Dismiss goal")
                }
            }

            if let why = GoalSummary.waitingReason(goal) {
                Text(why).font(.system(size: 12)).foregroundStyle(Theme.amber).lineLimit(2)
            }

            if !goal.criteria.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(goal.criteria.enumerated()), id: \.offset) { _, c in criterionRow(c) }
                }
            }

            if !goal.recovery.isEmpty { recoveryLog }

            if !goal.unresolved.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Unresolved").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.amber)
                    ForEach(Array(goal.unresolved.enumerated()), id: \.offset) { _, item in
                        Text("• " + item).font(.system(size: 12)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            actions
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border))
    }

    /// One criterion: its check state, its text, and the command or path under it in monospace.
    private func criterionRow(_ c: GoalCriterion) -> some View {
        HStack(alignment: .top, spacing: 8) {
            criterionIcon(c.met)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.text).font(.system(size: 12.5))
                    .foregroundStyle(c.met == true ? Theme.text2 : Theme.body)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = c.command ?? c.path {
                    Text(detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text3)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            }
        }
    }

    /// Met is a green check, failed a red x, unknown a hollow circle. Changes scale and fade in.
    private func criterionIcon(_ met: Bool?) -> some View {
        let name = met == true ? "checkmark.circle.fill" : met == false ? "xmark.circle.fill" : "circle"
        let color = met == true ? Theme.green : met == false ? Theme.red : Theme.text3
        return Image(systemName: name)
            .font(.system(size: 13))
            .foregroundStyle(color)
            .id(name)
            .transition(.scale(scale: 0.5).combined(with: .opacity))
            .frame(width: 16, height: 16)
            .animation(anim, value: met)
            .accessibilityLabel(met == true ? "Met" : met == false ? "Not met" : "Not checked")
    }

    /// The last ten recovery entries, newest first, folded away until opened.
    private var recoveryLog: some View {
        let recent = Array(goal.recovery.suffix(10).reversed())
        return VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(anim) { showLog.toggle() } } label: {
                HStack(spacing: 5) {
                    Image(systemName: showLog ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold))
                    Text("Recovery log (\(goal.recovery.count))").font(.system(size: 12))
                }
                .foregroundStyle(Theme.text2)
            }
            .buttonStyle(.plain)
            if showLog {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(recent.enumerated()), id: \.offset) { _, line in
                        Text(Fmt.line(line, 200)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text3)
                            .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            if GoalSummary.isLive(goal.phase) {
                Button("Stop goal") { controller.stopGoal() }
                    .buttonStyle(Pill(kind: .secondary, compact: true))
                    .help("Stops the goal cleanly, keeping its work")
            }
            if goal.phase == .done, goal.branch != nil {
                Button("Show in Git tab") {
                    app.inspectorDismissed = false
                    app.inspectorTab = .git
                    app.showInspector = true
                }
                .buttonStyle(Pill(kind: .primary, compact: true))
            }
            Spacer(minLength: 0)
        }
    }
}
