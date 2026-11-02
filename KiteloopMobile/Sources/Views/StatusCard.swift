import SwiftUI

/// The project's state as one card: a tinted pill naming the state, the item
/// in flight, the run's rail of phases with the current one alive, the spend
/// against its cap, and the one lever the state offers as the card's single
/// prominent button.
struct StatusCard: View {
    let state: ProjectState
    let run: AutopilotRun?
    let spend: Double?
    let cap: Double?
    let acting: Bool
    let act: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                pill
                Spacer()
                if state.running {
                    Image(systemName: "circle.hexagongrid.fill")
                        .foregroundStyle(tint)
                        .symbolEffect(.variableColor.iterative.reversing)
                }
            }
            if let title = run?.itemTitle ?? run?.item, state.running {
                Text(title).font(.body.weight(.medium)).lineLimit(2)
            } else if let detail = state.detail {
                Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
            }
            if state.running, let rail = run?.phaseRail {
                PhaseRailView(rail: rail)
            }
            if let spend {
                spendRow(spend)
            }
            if let action = state.action {
                Button(action: act) {
                    Text(action.title).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(action.resumes ? .green : .orange)
                .disabled(acting)
            }
        }
        .padding(.vertical, 4)
    }

    private var pill: some View {
        Text(state.label.uppercased())
            .font(.caption.weight(.bold))
            .tracking(0.6)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
    }

    private var tint: Color {
        switch state.tone {
        case .running: .green
        case .paused: .orange
        case .recovering: .yellow
        case .idle: .blue
        case .off: .secondary
        }
    }

    private func spendRow(_ spend: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Session spend").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(cap.map { String(format: "$%.2f of $%.0f", spend, $0) } ?? String(format: "$%.2f", spend))
                    .font(.caption.monospacedDigit())
            }
            if let cap, cap > 0 {
                ProgressView(value: min(spend / cap, 1))
                    .tint(spend / cap > 0.85 ? .red : .accentColor)
            }
        }
    }
}

/// worker → verify → review → merge → gate: done ones ticked, the current one
/// alive, the rest waiting. The Mac names the steps; this only orders them.
struct PhaseRailView: View {
    let rail: PhaseRail
    private static let order = ["worker", "verify", "review", "merge", "gate"]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Self.order, id: \.self) { step in
                stepView(step)
                if step != Self.order.last {
                    Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: 1)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rail.currentStep.map { "Phase \($0)" } ?? "Phase rail")
    }

    @ViewBuilder
    private func stepView(_ step: String) -> some View {
        let done = rail.stepsDone?.contains(step) == true
        let current = rail.currentStep == step
        HStack(spacing: 3) {
            if done {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else if current {
                Image(systemName: "circle.fill").foregroundStyle(.green).symbolEffect(.pulse)
            } else {
                Image(systemName: "circle").foregroundStyle(.secondary.opacity(0.5))
            }
            Text(step)
                .font(.caption2.weight(current ? .semibold : .regular))
                .foregroundStyle(current ? .primary : .secondary)
        }
        .font(.caption2)
    }
}
