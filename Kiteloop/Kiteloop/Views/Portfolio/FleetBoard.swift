import KiteloopCore
import SwiftUI

/// Every open project once, facets as columns — the table the three separate
/// lists were circling. A project is a row; whether it is parked, its consent,
/// what it is doing and how deep its queue is are columns, each backed by the
/// setting or state it has always been: the paused switch writes
/// `.kiteloop/config.json` through the same `setPaused` the Portfolio uses,
/// consent is the very
/// `autonomousWorkEnabled` the Autopilot tab shows, and the state cell opens
/// the running item's page through the one open-item action.
struct FleetBoard: View {
    let registry: ControlSessionRegistry
    /// The two ledgers the "last 24h" column is read from; without both the
    /// column says nothing rather than zero.
    var metricStore: TaskMetricStore?
    var groomingLedger: GroomingLedger?
    /// Each project's last day, by project name, once read.
    @State private var lastDay: [String: PortfolioReport.Row] = [:]

    /// Bumped after a paused write so the board re-reads the config it just
    /// changed — project config is a file, not an observable.
    @State private var configEdits = 0

    var body: some View {
        let projects = PortfolioSnapshot.capture(registry: registry).projects
        VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.sm) {
            AutonomyLoopSectionHeader(title: "Projects", icon: "square.grid.2x2")
            Grid(alignment: .leading,
                 horizontalSpacing: KiteloopTokens.Spacing.md,
                 verticalSpacing: KiteloopTokens.Spacing.xs) {
                GridRow {
                    Text("project"); Text("paused"); Text("autonomous"); Text("state"); Text("queue")
                    Text("last 24h")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                ForEach(projects, id: \.path) { project in
                    GridRow {
                        Text(project.name).font(.caption).bold()
                        pausedSwitchCell(project)
                        consentCell(project)
                        stateCell(project)
                        queueCell(project)
                        lastDayCell(lastDay[project.name])
                    }
                }
            }
            .id(configEdits)
        }
        .accessibilityIdentifier("fleet-board")
        .task { await loadLastDay() }
    }

    /// What the project's last day produced, and why its rejected runs were
    /// rejected — the Planner's report, one cell per project.
    private func lastDayCell(_ row: PortfolioReport.Row?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(row?.text ?? "—")
                .font(.caption2)
                .foregroundStyle(row == nil ? .tertiary : .secondary)
            ForEach(row?.causes ?? [], id: \.label) { cause in
                Text("rejected — \(cause.label) \(cause.count)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// The day aggregated off the main actor, as the Planner's report always was.
    private func loadLastDay() async {
        guard let metricStore, let groomingLedger else { return }
        let runs = metricStore.records
        let grooming = groomingLedger.records
        let period = PortfolioReport.Period.last(hours: 24, endingAt: Date())
        let report = await Task.detached(priority: .utility) {
            PortfolioReport.make(runs: runs, grooming: grooming, period: period)
        }.value
        lastDay = Dictionary(report.rows.map { ($0.projectName, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func entry(at path: String) -> ControlSessionRegistry.Entry? {
        registry.openProjects.first {
            $0.session.project.rootURL.path(percentEncoded: false) == path
        }
    }

    /// The cheapest, highest-leverage control in the app, finally in reach:
    /// one switch per project, read by both loops.
    private func pausedSwitchCell(_ project: PortfolioSnapshot.Project) -> some View {
        Toggle("", isOn: Binding(
            get: { project.paused },
            set: { paused in
                Task {
                    await PortfolioSummaryLoader.save(paused: paused,
                                                      goal: project.goal,
                                                      projectPath: project.path)
                    configEdits += 1
                }
            }
        ))
        .toggleStyle(.switch)
        .controlSize(.mini)
        .labelsHidden()
        .help("Park this project: no run starts for it — unattended, from its Run button or over the control API — "
              + "until it is unparked. A run already in flight finishes, and items at the approval gate stay there.")
        .accessibilityIdentifier("fleet-board-paused-switch-\(project.name)")
    }

    private func consentCell(_ project: PortfolioSnapshot.Project) -> some View {
        Group {
            if let entry = entry(at: project.path) {
                Toggle("", isOn: Binding(
                    get: { entry.autopilot.autonomousWorkEnabled },
                    set: { entry.autopilot.autonomousWorkEnabled = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help("Include in autonomous work — the same setting as the project's Autopilot tab. A human Run never asks.")
            } else {
                Text("—").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func stateCell(_ project: PortfolioSnapshot.Project) -> some View {
        Group {
            switch project.boardState {
            case .inFlight(let run, let itemID):
                VStack(alignment: .leading, spacing: 2) {
                    ItemLink(itemID, in: .path(project.path)) {
                        Text(run.itemTitle ?? itemID)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    if let rail = run.phaseRail {
                        PhaseRailView(rail: rail)
                    }
                }
            case .paused:
                pausedCell(project)
            case .idleWithWork(let idle):
                idleWithWorkCell(project, idle)
            case .quiet:
                Text("quiet").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    /// The state cell for a paused project (`isPaused`), plus the gate count:
    /// pausing holds the queue but does nothing about the items already sitting
    /// at the human gate, and this is where a human would otherwise have to
    /// open the project to see that.
    private func pausedCell(_ project: PortfolioSnapshot.Project) -> some View {
        let gate = project.statusCounts[.awaitingApproval] ?? 0
        let wording = Self.pausedWording(parked: project.paused, atGate: gate)
        return Text(wording.text)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .help(wording.help)
            .accessibilityIdentifier("fleet-board-paused-\(project.name)")
    }

    /// What the paused cell says. `isPaused` has two causes and only one is a
    /// person's: the board's paused switch. The other is the project's own
    /// autopilot in `.paused` — which it also enters by itself, on the session
    /// spend cap or after dead agent sessions — so with the switch off the cell
    /// says the run is paused without claiming who paused it, and points at the
    /// Autopilot tab, where the reason and Resume are.
    static func pausedWording(parked: Bool, atGate gate: Int) -> (text: String, help: String) {
        if parked {
            return ("paused by hand · \(gate) at gate",
                    "Parked with the paused switch: no run starts for this project until it is turned off.")
        }
        return ("run paused · \(gate) at gate",
                "This project's autopilot run is paused — by its Pause button, its spend cap or failing agent sessions. "
                    + "Open the project's Autopilot tab for the reason and to Resume.")
    }

    /// How many of the items a refusal named are linked before the cell stops
    /// counting. A row on a table, not a run log — the sentence above them names
    /// them all, and the project's own Autopilot tab has room for the rest.
    private static let namedItemLimit = 3

    /// The state cell for a project that is running nothing while its queue says
    /// there is work — the one place these two columns are read together.
    ///
    /// Both halves of the contradiction were already on screen, side by side,
    /// and "quiet" beside a queue depth of 6 read as two unremarkable cells
    /// rather than as one statement. This says it as one.
    ///
    /// Stated, never acted on, exactly as `ItemDisagreement` is: no control here
    /// starts, reorders or retries anything. The refusal is the deciding gate's
    /// own sentence rather than a rewording of it, cut to two lines with the
    /// whole of it on the tooltip; the items it named are links to the items,
    /// which is where a refusal is answered.
    private func idleWithWorkCell(_ project: PortfolioSnapshot.Project,
                                  _ idle: PortfolioSnapshot.IdleWithRunnableWork) -> some View {
        let shown = idle.namedItems.prefix(Self.namedItemLimit)
        let omitted = idle.namedItems.count - shown.count
        return VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.xs) {
            Text(idle.headline)
                .font(.caption)
                .foregroundStyle(Color.orange)
            if let line = idle.refusalLine {
                Text(line)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !shown.isEmpty {
                HStack(spacing: KiteloopTokens.Spacing.sm) {
                    ForEach(shown, id: \.self) { itemID in
                        ItemLink(itemID, in: .path(project.path)) {
                            Text(itemID)
                                .font(.caption2)
                                .foregroundStyle(Color.accentColor)
                                .lineLimit(1)
                        }
                    }
                    if omitted > 0 {
                        Text("+\(omitted) more").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .help(idle.refusal.map {
            "This project has \(idle.runnable) runnable item\(idle.runnable == 1 ? "" : "s") and is "
                + "running none. The last start was declined: \($0)"
        } ?? "This project has \(idle.runnable) runnable item\(idle.runnable == 1 ? "" : "s") and is "
            + "running none. No reason was recorded for the last start decision.")
        .accessibilityIdentifier("fleet-board-idle-with-work-\(project.name)")
    }

    private func queueCell(_ project: PortfolioSnapshot.Project) -> some View {
        let ready = project.statusCounts[.ready] ?? 0
        let blocked = project.statusCounts[.blocked] ?? 0
        let gate = project.statusCounts[.awaitingApproval] ?? 0
        return Text("\(ready) ready · \(blocked) blocked · \(gate) gate")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }
}
