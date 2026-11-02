import KiteloopCore
import SwiftUI

/// The Coordinator as a side pane, so it is reachable *while a project is open*.
///
/// `CoordinatorPanel` is complete, but it is mounted only inside
/// `PortfolioSection`, which lives on the start screen — the screen you see with
/// every project tab closed. The one surface that says what the portfolio loop
/// is doing was therefore hidden exactly when there was work in flight to judge
/// it against, and checking on it meant closing your project. This drawer mounts
/// that same panel, unchanged; the start-screen copy stays where it is, because
/// it is still the right thing to see with no project open.
///
/// The panel half starts no pass, files no item and approves nothing: it reads
/// the loop, the portfolio's `.kiteloop/` configs and the two ledgers, and its
/// State controls set the loop's *settings* — a switch, a ceiling. Reading this
/// drawer changes nothing; flipping a setting in it does.
///
/// Conversation is deliberately *not* here. Discussing priorities belongs to a
/// team agent granted Operator Tools — same read surface, persistent memory, a
/// real persona — not to a bespoke chat bolted onto the drawer.
struct CoordinatorDrawer: View {
    /// The portfolio-level loop, read (never called) by the panel.
    let refill: CoordinatorQueueRefill
    /// The directory of open projects, for the panel's per-project switches.
    /// Optional so the drawer still renders where no registry is wired.
    var registry: ControlSessionRegistry?
    /// The portfolio as the landing screen lists it — the drawer reads the same
    /// recents rather than a second idea of which projects exist.
    let recentProjects: [RecentProject]
    let vaultURL: URL?
    /// The two ledgers behind the panel's day rollup. Optional for the same
    /// reason the panel takes them that way — absent, that one section says so.
    var metricStore: TaskMetricStore?
    var groomingLedger: GroomingLedger?
    /// The panel's controls write to these: the autonomous-run switch, and the
    /// portfolio settings the running ceiling lives in. Optional like the
    /// ledgers — absent, those controls are drawn disabled saying so.
    var scheduler: CoordinatorRunScheduler?
    var globalConfigStore: GlobalConfigStore?
    let onClose: () -> Void

    /// Loaded here rather than inherited: with a project open there is no
    /// `PortfolioSection` above this to have read them already. Keyed on the
    /// recents so the list follows the projects you open.
    @State private var summaries: [PortfolioProjectSummary] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // The panel caps its own body height and is one row collapsed, so
            // it takes only what it needs.
            CoordinatorPanel(
                refill: refill,
                projects: summaries.map(PortfolioSection.coordinatorInput),
                metricStore: metricStore,
                groomingLedger: groomingLedger,
                scheduler: scheduler,
                globalConfigStore: globalConfigStore,
                fillsHeight: true,
                standalone: false,
                registry: registry
            )
            .padding(KiteloopTokens.Spacing.lg)
        }
        .background(.background)
        .accessibilityIdentifier("coordinator-drawer")
        .task(id: recentProjects.map(\.id).joined(separator: ",")) {
            // The ledger is copied on this actor and the reading happens off it,
            // like the panel's day rollup — it is what turns a project's ready
            // count into how much of it a pickup would actually take.
            summaries = await PortfolioSummaryLoader.load(recentProjects, vaultURL: vaultURL,
                                                          grooming: groomingLedger?.records ?? [])
        }
    }

    private var header: some View {
        HStack(spacing: KiteloopTokens.Spacing.sm) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("Planner")
                .font(.system(.caption, weight: .semibold))
            AutonomyScopeLabel(text: AutonomyScopeLabel.allProjects)
            AutonomyLoopStatePill(text: refill.enabled ? "On — grooming" : "Off",
                                  tint: refill.enabled ? .green : .gray)
                .accessibilityIdentifier("coordinator-drawer-state")
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark").font(.caption2)
            }
            .buttonStyle(.plain)
            .help("Close Planner")
            .accessibilityIdentifier("coordinator-drawer-close")
        }
        .padding(.horizontal, KiteloopTokens.Spacing.md)
        .padding(.vertical, KiteloopTokens.Spacing.xs)
        .background(.ultraThinMaterial)
    }
}
