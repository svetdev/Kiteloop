import KiteloopCore
import SwiftUI

/// The worker → verify → review → wait → merge → gate pipeline a run moves
/// through, drawn as six dots: finished steps ticked, the current one ringed, the
/// attempt count when it is above one, and the time since the run's last
/// output — in the warning color once that age passes half the project's
/// stall timeout, ahead of the watchdog actually firing.
///
/// One view for both places a run's phase is worth seeing at a glance: the
/// fleet board's state cell and the Autopilot tab's in-flight row. Both draw
/// from the same `PortfolioSnapshot.RunState.PhaseRail`, so the two surfaces
/// cannot disagree about where a run is.
struct PhaseRailView: View {
    let rail: PortfolioSnapshot.RunState.PhaseRail

    private static let labels: [PortfolioSnapshot.RunState.PhaseRail.Step: String] = [
        .worker: "W", .verify: "V", .review: "R", .waitingForGate: "Q", .merge: "M", .gate: "G"
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(PortfolioSnapshot.RunState.PhaseRail.Step.allCases.enumerated()),
                    id: \.element) { index, step in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 6))
                        .foregroundStyle(.quaternary)
                }
                Self.stepDot(Self.labels[step] ?? "?",
                            active: step == rail.current,
                            done: rail.stepsDone.contains(step))
            }
            if rail.attempt > 1 {
                Text("attempt \(rail.attempt)")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
            Text(Self.ageText(rail.lastOutputAge))
                .font(.system(size: 8))
                .foregroundStyle(rail.isStale ? Color.orange : Color.secondary)
        }
        .accessibilityIdentifier("phase-rail")
    }

    /// One step's dot — ringed blue while it is the current step, filled green
    /// once it's behind the run, otherwise a plain gray placeholder.
    static func stepDot(_ label: String, active: Bool, done: Bool) -> some View {
        Text(label)
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .frame(width: 14, height: 14)
            .background(
                Circle().fill(
                    active ? Color.blue.opacity(0.2) :
                    done ? Color.green.opacity(0.2) :
                    Color.gray.opacity(0.1)
                )
            )
            .foregroundStyle(active ? .blue : done ? .green : .secondary)
    }

    /// `40s ago`, `3m ago`, `2h ago` — a phrase, not a duration formatter's
    /// full spelling; this sits in an eight-point caption next to an attempt
    /// count and a five-dot rail.
    static func ageText(_ interval: TimeInterval) -> String {
        DurationPhrase.age(interval)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 8) {
        PhaseRailView(rail: PortfolioSnapshot.RunState.PhaseRail(
            current: .worker, attempt: 1, lastOutputAge: 12, warnAtSeconds: 600))
        PhaseRailView(rail: PortfolioSnapshot.RunState.PhaseRail(
            current: .review, attempt: 2, lastOutputAge: 40, warnAtSeconds: 600))
        PhaseRailView(rail: PortfolioSnapshot.RunState.PhaseRail(
            current: .waitingForGate, attempt: 1, lastOutputAge: 8, warnAtSeconds: 600))
        PhaseRailView(rail: PortfolioSnapshot.RunState.PhaseRail(
            current: .merge, attempt: 2, lastOutputAge: 720, warnAtSeconds: 600))
    }
    .padding()
}
