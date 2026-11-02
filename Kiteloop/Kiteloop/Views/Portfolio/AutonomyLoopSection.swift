import SwiftUI

/// The section heading both autonomy loops use.
///
/// The Planner and the fleet answer the same shape of question — is it on, what
/// has it done, which projects — and drew that shape two different ways: the
/// Planner in icon-and-title labels, the fleet in plain bold text with no icons
/// at all. Side by side in their drawers they read as two unrelated tools rather
/// than the two halves of one machine, which is the thing this fixes. The
/// styling is the Planner's, because it was already the more legible of the two;
/// what matters is that there is now one of it.
///
/// **Its icon must name the subject, never an action.** A heading is a label —
/// there is nothing to press on it — so it takes a glyph that describes what the
/// section is about (`gauge`, `clock.arrow.circlepath`, `square.grid.2x2`) and
/// never one that reads as a control. Action glyphs — `power`, `pause`, `play`,
/// `pencil`, `plus` — belong only to things you can actually click.
///
/// This is not hypothetical tidiness. "Fleet state" was headed `pause.circle`
/// directly above the **Pause fleet** button: the same glyph an inch apart,
/// meaning "this section is about pausing" once and "press me to pause" once.
/// Both on/off sections were headed `power`, immediately above the switch that
/// actually does it. The icon is drawn in the secondary tint for the same
/// reason — a label recedes, a control does not.
struct AutonomyLoopSectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: KiteloopTokens.Spacing.sm) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(.primary)
        }
    }
}

/// The state pill a loop's title bar carries — "Off", "manual", "On —
/// unattended".
///
/// In the fleet's title bar this already existed; the Planner's lived inside a
/// card *below* its own drawer header, so the drawer said "Planner" and the card
/// said "Planner Off" directly under it. One pill, one place: beside the name,
/// in the title bar, for both.
struct AutonomyLoopStatePill: View {
    let text: String
    var tint: Color = .secondary

    /// Deliberately the capsule both headers already drew, down to the padding:
    /// the point is to have one of it, not a third one that is nearly the same.
    var body: some View {
        Text(text)
            .font(.system(.caption2, weight: .semibold))
            .padding(.horizontal, KiteloopTokens.Spacing.md)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(KiteloopTokens.Opacity.medium)))
            .foregroundStyle(tint == .gray ? Color.secondary : tint)
            .accessibilityIdentifier("autonomy-loop-state-pill")
    }
}

/// Who a surface's switches govern — "all projects", or the one project named.
///
/// Two of the three autonomy switches are portfolio-wide (`Groom the backlog`
/// and `Run work unattended`) and one is per project (`Include in autonomous
/// work`), and nothing on screen said which was which. So a person opens one
/// project, flips grooming on, and has armed it for every other project too,
/// from inside a window titled with a single repo's name. The same shape of
/// mistake the daily ceiling produced when it was drawn inside the Planner's
/// box — a portfolio-wide thing rendered on a project-shaped surface reads as
/// project-scoped.
///
/// The Planner panel already carried a sentence explaining that unattended
/// running lives in the fleet drawer. That prose exists because the structure
/// wasn't saying it; this is the structure saying it.
struct AutonomyScopeLabel: View {
    let text: String

    /// The wording for the portfolio surfaces, in one place so the two cannot
    /// drift into saying it differently.
    static let allProjects = "all projects"

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .accessibilityIdentifier("autonomy-scope-label")
    }
}
