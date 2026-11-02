import SwiftUI

/// The trust ladder, drawn: five rungs, ticked with their facts, the first
/// unmet one carrying its gate's own sentence and the control that advances
/// it. Renders `AutonomyLadder.assess` and can start nothing.
struct AutonomyLadderView: View {
    let rungs: [AutonomyLadder.Rung]

    var body: some View {
        VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.md) {
            Text("Autonomy, rung by rung")
                .font(.callout).bold()
            Text("Each step is one or two switches. Nothing arms without its "
                 + "budget, and no project runs unattended without its own opt-in.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            ForEach(rungs) { rung in
                HStack(alignment: .firstTextBaseline, spacing: KiteloopTokens.Spacing.sm) {
                    Image(systemName: rung.met ? "checkmark.circle.fill" : "circle")
                        .font(.caption)
                        .foregroundStyle(rung.met ? Color.green : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rung.title)
                            .font(.caption.weight(rung.met ? .regular : .semibold))
                        Text(rung.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let advance = rung.advance {
                            Text("→ \(advance)")
                                .font(.caption2)
                                .foregroundStyle(.tint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(KiteloopTokens.Spacing.md)
        .frame(minWidth: 320, maxWidth: 400)
    }
}
