import KiteloopCore
import SwiftUI

/// This project's routines on its Autopilot tab: each with its arming switch,
/// when it falls, how it last went, and a Run now.
///
/// A routine is written over the control API or in `~/.kiteloop/routines.json`;
/// this row is where a person sees that one exists for the project they are
/// looking at, arms it, and starts it by hand. A project with none draws
/// nothing.
struct AutopilotRoutinesRow: View {
    let runner: RoutineRunner
    let projectRoot: URL

    var body: some View {
        let routines = Self.routines(in: runner.routines, for: projectRoot)
        if !routines.isEmpty {
            VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.xs) {
                ForEach(routines) { routine in
                    row(routine)
                }
            }
            .padding(.horizontal, KiteloopTokens.Spacing.md)
            .padding(.vertical, KiteloopTokens.Spacing.xs)
            .accessibilityIdentifier("autopilot-routines")
        }
    }

    private func row(_ routine: Routine) -> some View {
        HStack(spacing: KiteloopTokens.Spacing.md) {
            Toggle(isOn: Binding(get: { routine.armed }, set: { try? runner.setArmed(routine.id, $0) })) {
                Text(routine.name).font(.caption).lineLimit(1)
            }
            .help("Armed, this routine sends its prompt to \(routine.agent) on its schedule. Off, it runs only when you press Run now.")
            .accessibilityIdentifier("autopilot-routine-armed-\(routine.id)")
            Text(Self.line(for: routine, next: runner.next(for: routine), last: runner.lastRun(of: routine.id)))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button("Run now") { _ = runner.runNow(routine.id) }
                .controlSize(.small)
                .help("Send this routine's prompt to \(routine.agent) now, armed or not.")
                .accessibilityIdentifier("autopilot-routine-run-\(routine.id)")
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
    }

    /// The routines that name the project at `root` — by its folder's name, as
    /// the control API names a project, or by its path.
    static func routines(in routines: [Routine], for root: URL) -> [Routine] {
        let path = root.path(percentEncoded: false)
        return routines.filter {
            $0.project == root.lastPathComponent || KiteloopProject.isSamePath($0.project, path)
        }
    }

    /// What a routine's row says after its name: who it goes to and when it
    /// falls, when it next does while armed, and how it last went.
    static func line(for routine: Routine, next: Date?, last: RoutineRun?, now: Date = Date()) -> String {
        var parts = ["\(routine.agent) · \(routine.schedule?.words ?? "no schedule")"]
        if routine.armed, let next {
            parts.append("next \(next.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))")
        }
        if let last { parts.append(outcome(of: last)) }
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
}
