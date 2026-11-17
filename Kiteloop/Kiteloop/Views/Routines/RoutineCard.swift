import KiteloopCore
import SwiftUI

/// One routine on the Routines page: what it is called and what fires it, who
/// it goes to and what it may spend, its arming switch, when it next runs and how it last went, the
/// prompt it sends, and — unfolded — its recent runs.
struct RoutineCard: View {
    let routine: Routine
    let next: Date?
    /// This routine's runs, oldest first.
    let runs: [RoutineRun]
    let setArmed: (Bool) -> Void
    let runNow: () -> Void
    let edit: () -> Void
    let delete: () -> Void

    @State private var showsHistory = false

    /// How many past runs the unfolded card lists.
    static let historyLength = 5

    var body: some View {
        VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.lg) {
            titleRow
            Text(routine.prompt)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            footer
            if showsHistory { history }
        }
        .padding(KiteloopTokens.Spacing.xl)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: KiteloopTokens.Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: KiteloopTokens.Radius.lg)
                .strokeBorder(Color.primary.opacity(KiteloopTokens.Opacity.medium))
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("routine-card-\(routine.id)")
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: KiteloopTokens.Spacing.lg) {
            badge
            VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.xs) {
                Text(routine.name).font(.headline).lineLimit(1)
                Text(Self.caption(for: routine))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: KiteloopTokens.Spacing.md)
            Toggle("Armed", isOn: Binding(get: { routine.armed }, set: setArmed))
                .toggleStyle(.switch)
                .labelsHidden()
                .help("Armed, this routine sends its prompt to \(routine.agent) by itself when its trigger fires. Off, it runs only when you press Run Now.")
                .accessibilityIdentifier("routine-armed-\(routine.id)")
            menu
        }
    }

    /// The trigger's kind as a mark, in colour while the routine is armed.
    private var badge: some View {
        Image(systemName: Self.symbol(for: routine.trigger))
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(routine.armed ? Color.orange : Color.secondary)
            .frame(width: 34, height: 34)
            .background((routine.armed ? Color.orange : Color.secondary).opacity(KiteloopTokens.Opacity.medium),
                        in: RoundedRectangle(cornerRadius: KiteloopTokens.Radius.md))
    }

    private var menu: some View {
        Menu {
            Button("Edit…", action: edit)
            Button("Run Now", action: runNow)
            Divider()
            Button("Delete…", role: .destructive, action: delete)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Edit, run or delete this routine")
        .accessibilityIdentifier("routine-menu-\(routine.id)")
    }

    private var footer: some View {
        HStack(spacing: KiteloopTokens.Spacing.md) {
            Circle().fill(Self.tint(of: runs.last)).frame(width: 7, height: 7)
            Text(Self.status(for: routine, next: next, last: runs.last))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: KiteloopTokens.Spacing.md)
            if !runs.isEmpty {
                Button(showsHistory ? "Hide Runs" : "Runs") { showsHistory.toggle() }
                    .buttonStyle(.link)
                    .font(.caption)
                    .accessibilityIdentifier("routine-history-\(routine.id)")
            }
            Button("Run Now", action: runNow)
                .controlSize(.small)
                .help("Send this routine's prompt to \(routine.agent) now, armed or not.")
                .accessibilityIdentifier("routine-run-\(routine.id)")
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.sm) {
            ForEach(runs.suffix(Self.historyLength).reversed()) { run in
                HStack(alignment: .firstTextBaseline, spacing: KiteloopTokens.Spacing.md) {
                    Circle().fill(Self.tint(of: run)).frame(width: 6, height: 6)
                    Text(run.at.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(Self.historyLine(for: run))
                        .font(.caption)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
        .accessibilityIdentifier("routine-runs-\(routine.id)")
    }

    // MARK: - Words

    /// Under the name: what fires it, who it goes to, and what it may spend
    /// when it has a budget of its own.
    static func caption(for routine: Routine) -> String {
        ([routine.trigger.words ?? "No schedule", routine.agent] + [routine.budgetWords].compactMap { $0 })
            .joined(separator: " · ")
    }

    /// The mark for a trigger: a folder for a watched folder, a bolt for an
    /// event, a loop for an interval and a clock for a time of day.
    static func symbol(for trigger: Routine.Trigger) -> String {
        if trigger.watch != nil { return "folder" }
        if trigger.on != nil { return "bolt" }
        return trigger.every != nil ? "arrow.triangle.2.circlepath" : "clock"
    }

    /// The card's status line: when it next falls while armed, that it is off
    /// while it is not, and how it last went.
    static func status(for routine: Routine, next: Date?, last: RoutineRun?, now: Date = Date()) -> String {
        var parts: [String] = []
        if routine.armed, let next {
            parts.append("Next \(next.formatted(.relative(presentation: .named, unitsStyle: .wide)))")
        } else if !routine.armed {
            parts.append("Off")
        }
        parts.append(last.map(outcome(of:)) ?? "never run")
        return parts.joined(separator: " · ")
    }

    /// A run in a few words: what happened, and why when it did not start.
    static func outcome(of run: RoutineRun) -> String {
        switch run.outcome {
        case .started: return run.finishedAt == nil ? "last run in progress" : "last run finished"
        case .queued: return "last prompt queued behind a turn"
        case .skipped: return "last skipped — \(run.reason ?? "its check found nothing")"
        case .refused: return "last refused — \(run.reason ?? "no reason given")"
        case .waiting: return "waiting — \(run.reason ?? "its agent cannot be reached")"
        }
    }

    /// A past run on its own line: what the agent said for one that ran, and
    /// otherwise why it did not, with what it cost when it cost anything.
    static func historyLine(for run: RoutineRun) -> String {
        let what: String
        switch run.outcome {
        case .started: what = spoken(in: run)
        case .queued: what = "Queued behind a turn"
        case .skipped: what = "Skipped — \(run.reason ?? "its check found nothing")"
        case .refused: what = "Refused — \(run.reason ?? "no reason given")"
        case .waiting: what = "Waiting — \(run.reason ?? "its agent cannot be reached")"
        }
        guard let cost = run.costUSD, cost > 0 else { return what }
        return "\(what) · \(String(format: "$%.2f", cost))"
    }

    /// A turn that ran, as what the agent said — or, when it said nothing
    /// that was kept, whether it is still going.
    private static func spoken(in run: RoutineRun) -> String {
        if let reply = run.reply, !reply.isEmpty { return reply }
        return run.finishedAt == nil ? "In progress" : "Finished"
    }

    /// The dot beside a run: green for a turn that ran, orange for one held up
    /// or skipped, red for one refused, grey for a routine that has never run.
    static func tint(of run: RoutineRun?) -> Color {
        switch run?.outcome {
        case .started: return .green
        case .queued, .skipped, .waiting: return .orange
        case .refused: return .red
        case nil: return .secondary
        }
    }
}
