import KiteloopCore
import SwiftUI

/// The Coordinator's home on the portfolio screen: what the portfolio-level loop
/// is doing, what it has spent, which project it would pick next, and what the
/// last day actually produced.
///
/// This is the *container*. Each section's behaviour is its own item's — the
/// enable switch, the pass history — and the panel is built
/// so a section whose item hasn't landed is one line of grey text rather than a
/// hole in the layout. `CoordinatorPanelModel` holds all of that; this file only
/// draws it.
///
/// Two things it deliberately does not do:
///
/// * **It never acts on its own.** The reading half is built from a
///   `CoordinatorPanelModel`, whose inputs are values with no methods on them,
///   so rendering the panel can start nothing. The State section's controls
///   *do* write — but only settings, and only when someone presses one:
///   switching the loop on arms its timer, it does not run a pass, and no
///   control here files an item.
/// * **It stays cheap.** Collapsed it is one row, and the day's rollup — the only
///   part that touches a ledger — is aggregated off the main actor, once, and
///   only after the panel is opened. The autopilot panel's layout cost came from
///   unbounded lists in a constantly-updating view; every list here is bounded by
///   `CoordinatorPanelModel` before it reaches a `ForEach`.
struct CoordinatorPanel: View {
    /// The live loop: read through `LoopSnapshot.capture`, and written by the
    /// State section's switch and grooming budget — straight to the
    /// properties, which persist themselves and own the timer.
    let refill: CoordinatorQueueRefill
    /// The portfolio as the landing screen already read it — no extra disk work.
    let projects: [CoordinatorPanelModel.ProjectInput]
    /// The two ledgers the day's rollup is aggregated from. Optional so the panel
    /// still renders — with that one section marked unavailable — anywhere they
    /// aren't handy, matching how `PortfolioSection` treats its config store.
    var metricStore: TaskMetricStore?
    var groomingLedger: GroomingLedger?
    /// The loop that *starts* runs. Its switch is deliberately separate from the
    /// refill switch — filing work and running it are different levels of trust
    /// — so it is a separate input, and optional like the ledgers: absent, that
    /// control is drawn disabled saying it isn't wired here.
    var scheduler: CoordinatorRunScheduler?
    /// Where the portfolio-wide *running* ceiling lives
    /// (`GlobalConfig.dailyBudgetUSD`). Optional for the same reason.
    var globalConfigStore: GlobalConfigStore?
    /// On the landing screen the panel is one section among several, so its
    /// scroll area is capped; in the drawer it is the surface, and fills
    /// whatever height its collapsed neighbours leave.
    var fillsHeight = false
    /// Whether the panel draws its own card and header, or trusts a drawer to
    /// have drawn them.
    ///
    /// On the start screen there is nothing above it, so it needs both. In
    /// `CoordinatorDrawer` there is a title bar already saying "Planner" — and
    /// the card under it said "Planner" a second time, with its own pill, inside
    /// a border the drawer had no equivalent of. That is most of why the two
    /// loops read as unrelated tools side by side: the fleet's drawer is a title
    /// bar and then its sections, and this one was a title bar and then a
    /// completely different object.
    var standalone = true
    /// For the autonomy ladder's per-project switches. Optional: without it the
    /// ladder control simply isn't offered.
    var registry: ControlSessionRegistry?

    /// Collapsed by default and remembered across launches: the landing screen's
    /// job is to get you into a project, and this is the thing you open when you
    /// want to know what happened overnight. Collapsed it still shows on/off, so
    /// the state that matters most is never behind the disclosure.
    @AppStorage("coordinatorPanelExpanded") private var expanded = false

    /// Whether the body shows. The stored disclosure governs the standalone card,
    /// which has a header to toggle it; inside a drawer there is no such control
    /// and the drawer was opened to see this, so it is simply open.
    private var isOpen: Bool { standalone ? expanded : true }
    @State private var report: CoordinatorPanelModel.ReportInput = .reading
    /// Text mirrors of the two daily ceilings, following the Autopilot tab's
    /// cost-cap fields: a figure reaches the live ceiling only when its field is
    /// committed (Return, or focus leaving it), so a half-typed `1` in `12.50`
    /// never becomes the budget an unattended night runs against.

    /// The window the rollup covers — "what did it do overnight".
    private static let reportHours = 24

    private var model: CoordinatorPanelModel {
        CoordinatorPanelModel.make(
            loop: CoordinatorPanelModel.LoopSnapshot.capture(refill),
            projects: projects,
            report: metricStore == nil || groomingLedger == nil ? .unavailable : report,
            controls: CoordinatorPanelModel.Controls.capture(
                refill: refill, scheduler: scheduler, store: globalConfigStore)
        )
    }

    var body: some View {
        let model = model
        VStack(alignment: .leading, spacing: 0) {
            if standalone { header(model) }
            if isOpen {
                if standalone { Divider() }
                ScrollView {
                    VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.xl) {
                        stateSection(model)
                        passesSection(model)
                        budgetSection(model)
                        reportSection(model)
                    }
                    .padding(KiteloopTokens.Spacing.lg)
                }
                .frame(maxHeight: fillsHeight ? .infinity : 380)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if standalone {
                RoundedRectangle(cornerRadius: KiteloopTokens.Radius.lg)
                    .fill(Color(nsColor: .controlBackgroundColor))
            }
        }
        .overlay {
            if standalone {
                RoundedRectangle(cornerRadius: KiteloopTokens.Radius.lg)
                    .strokeBorder(Color.gray.opacity(KiteloopTokens.Opacity.medium), lineWidth: 1)
            }
        }
        // Only while the panel is open: the aggregation is cheap but it is not
        // free, and a landing screen that never gets expanded should never pay
        // for it. Re-read on each open rather than once per launch — "last 24h"
        // read at breakfast is the wrong 24h by the evening, and the previous
        // rollup stays on screen while the fresh one is built.
        .task(id: isOpen) {
            guard isOpen else { return }
            await loadReport()
        }
    }

    // MARK: - Header

    private func header(_ model: CoordinatorPanelModel) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            HStack(spacing: KiteloopTokens.Spacing.md) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(.secondary)
                Text("Planner")
                    .font(.system(.callout, weight: .semibold))
                AutonomyScopeLabel(text: AutonomyScopeLabel.allProjects)
                stateChip(model)
                Spacer(minLength: KiteloopTokens.Spacing.md)
                Text(headline(model))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, KiteloopTokens.Spacing.lg)
            .padding(.vertical, KiteloopTokens.Spacing.lg)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("coordinator-panel-header")
        .help("Portfolio-level grooming: state, passes, budget and the day's rollup")
    }

    /// On/off outside the disclosure, because it is the fact that changes what
    /// every other section means.
    @ViewBuilder
    private func stateChip(_ model: CoordinatorPanelModel) -> some View {
        if let state = model.state.content {
            Text(state.headline)
                .font(.system(.caption2, weight: .semibold))
                .padding(.horizontal, KiteloopTokens.Spacing.md)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill((state.enabled ? Color.green : Color.gray)
                        .opacity(KiteloopTokens.Opacity.medium))
                )
                .foregroundStyle(state.enabled ? Color.green : Color.secondary)
                .accessibilityIdentifier("coordinator-panel-state")
        }
    }

    /// The collapsed one-liner: the day's rollup when there is one, the loop's
    /// own state when there isn't.
    private func headline(_ model: CoordinatorPanelModel) -> String {
        if let report = model.report.content { return report.summaryLine }
        if let state = model.state.content, !state.enabled { return "Not grooming" }
        return model.state.unavailableReason ?? "Portfolio grooming"
    }

    // MARK: - 1. State

    /// What the loop is doing, and the controls that decide it.
    ///
    /// Laid out by hand rather than through `section` because the controls are
    /// drawn whether or not the readout above them has anything to say: with
    /// nothing wired the loop cannot run whatever its switch says, and a switch
    /// that vanished at that moment would answer "why is nothing happening" with
    /// an empty space. Disabled, with the reason, is the honest version.
    @ViewBuilder
    private func stateSection(_ model: CoordinatorPanelModel) -> some View {
        VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.md) {
            AutonomyLoopSectionHeader(title: "State", icon: "gauge")

            if let state = model.state.content {
                VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.sm) {
                    Text(state.headline)
                        .font(.system(.callout, weight: .semibold))
                        .foregroundStyle(state.enabled ? .primary : .secondary)
                    Text(state.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if let reason = model.state.unavailableReason {
                Text("Not available — \(reason)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            controls(model.controls)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 1a. The controls

    /// The settings that operate the Coordinator, and the ceilings they run
    /// against. Each writes straight to the property that owns it —
    /// `CoordinatorQueueRefill.enabled` persists itself and starts or tears
    /// down its own timer, and so does `CoordinatorRunScheduler.enabled` — so
    /// there is no second owner of any setting here and nothing to keep in
    /// sync.
    private func controls(_ controls: CoordinatorPanelModel.Controls) -> some View {
        VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.md) {
            groomingControls(controls)
            Divider()
            // The scheduling controls live in the fleet drawer now: the
            // Coordinator knows and feeds; the fleet runs. `Controls` keeps
            // deriving both gates so the model (and its tests) stay whole.
            caption("Unattended running is in the fleet drawer — the fleet runs; the Planner grooms.")
        }
        .padding(.top, KiteloopTokens.Spacing.xs)
    }

    /// Grooming: the switch, and what a day of it may cost.
    @ViewBuilder
    private func groomingControls(_ controls: CoordinatorPanelModel.Controls) -> some View {
        Toggle("Groom the backlog", isOn: Binding(
            get: { refill.enabled },
            set: { refill.enabled = $0 }
        ))
        .toggleStyle(.switch)
        .controlSize(.mini)
        .font(.caption)
        // Operable, not just wired: arming needs a grooming ceiling to exist,
        // the same rule the API's PUT enforces in the same words. Already-on
        // always accepts input, so the way out is never blocked.
        .disabled(!controls.isGroomingSwitchOperable)
        .accessibilityIdentifier("coordinator-refill-toggle")
        .help("Whether the Planner tops up queues that run dry. Switching it on arms the periodic check — it doesn't run a pass now.")

        if let reason = controls.groomingSwitchDisabledReason {
            caption(reason)
        }

        if refill.enabled && controls.canGroom {
            // Switching on arms a timer; it does not run a pass. Say when the
            // first look is due rather than letting one appear unannounced.
            caption("Armed — the next look is up to \(Self.intervalLabel(refill.checkInterval)) away.")
        }
        if let reason = controls.groomingDisabledReason {
            caption(reason)
        }
    }


    /// The check interval in the words a reader thinks in — "15 min", "1 h".
    private static func intervalLabel(_ interval: TimeInterval) -> String {
        let minutes = max(1, Int((interval / 60).rounded()))
        guard minutes >= 60 else { return "\(minutes) min" }
        let hours = Double(minutes) / 60
        return hours == hours.rounded() ? "\(Int(hours)) h" : String(format: "%.1f h", hours)
    }

    // MARK: - 3. Recent passes

    @ViewBuilder
    private func passesSection(_ model: CoordinatorPanelModel) -> some View {
        section("Recent passes", "clock.arrow.circlepath", model.passes) { passes in
            if passes.isEmpty {
                caption("No pass on record yet.")
            } else {
                VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.sm) {
                    ForEach(passes.items) { pass in
                        HStack(alignment: .firstTextBaseline, spacing: KiteloopTokens.Spacing.md) {
                            Image(systemName: icon(for: pass.kind))
                                .font(.caption2)
                                .foregroundStyle(color(for: pass.kind))
                            Text(pass.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    omitted(passes.omittedLabel)
                }
            }
        }
    }

    private func icon(for kind: CoordinatorPanelModel.Pass.Kind) -> String {
        switch kind {
        case .filed: return "checkmark.circle"
        case .held: return "pause.circle"
        case .nothing: return "minus.circle"
        case .triaged: return "arrow.triangle.2.circlepath"
        case .stalled: return "exclamationmark.triangle"
        }
    }

    private func color(for kind: CoordinatorPanelModel.Pass.Kind) -> Color {
        switch kind {
        case .filed: return .green
        case .triaged: return .orange
        // The one entry in this list that is a fault rather than a state.
        case .stalled: return .red
        case .held, .nothing: return .secondary
        }
    }

    // MARK: - 4. Budget

    @ViewBuilder
    private func budgetSection(_ model: CoordinatorPanelModel) -> some View {
        // Passes only. The spend meter that stood above this one reported the
        // *shared* ceiling — the same number the fleet's controls carried and
        // the sidebar drew a third time — so three surfaces each looked like
        // they owned it, and I read it as three separate budgets. It has its own
        // box beside the Planner's and the fleet's now. Passes are grooming's
        // alone, so they stay, and the section is named for what it still shows.
        section("Grooming passes", "clock.arrow.circlepath", model.budget) { budget in
            VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.md) {
                meter(label: budget.passText,
                      fraction: budget.passFraction,
                      tint: budget.isExhausted ? .orange : .blue)
                if let reason = budget.exhaustionReason {
                    Text("Spent — \(reason). Passes stop until tomorrow.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // The ceiling, operable where it is read: stepping it calls the
                // loop, which persists it, so a raise mid-day takes effect on
                // the next pass and survives a relaunch. Raising it is also how
                // a spent day gets more passes — there is no separate reset.
                Stepper(value: Binding(
                    get: { budget.maxPasses ?? 12 },
                    set: { refill.setBudgetLimits(maxPasses: .some(max(1, $0))) }
                ), in: 1...96) {
                    Text("Ceiling: \(budget.maxPasses.map(String.init) ?? "12") passes/day")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("grooming-pass-ceiling")
            }
        }
    }

    private func meter(label: String, fraction: Double?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            if let fraction {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.gray.opacity(KiteloopTokens.Opacity.light))
                        Capsule().fill(tint.opacity(0.5))
                            .frame(width: max(2, geo.size.width * fraction))
                    }
                }
                .frame(height: 6)
            }
        }
    }

    // MARK: - 5. Projects

    @ViewBuilder
    private func reportSection(_ model: CoordinatorPanelModel) -> some View {
        section("Last \(Self.reportHours)h", "chart.bar.doc.horizontal", model.report) { report in
            if report.isEmpty {
                caption("Nothing ran in the \(report.period.label).")
            } else {
                VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.md) {
                    Text("Merged \(report.total.mergeRate.text) · \(PortfolioReport.usd(report.total.spendUSD))")
                        .font(.system(.callout, weight: .semibold))
                    ForEach(report.rows) { row in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.projectName)
                                .font(.caption)
                            Text(row.text)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(row.causes, id: \.label) { cause in
                                Text("rejected — \(cause.label) \(cause.count)")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    if report.omittedProjects > 0 {
                        omitted("+\(report.omittedProjects) more in the total")
                    }
                }
            }
        }
    }

    /// Aggregate the day off the main actor. Both ledgers are plain `Sendable`
    /// values, so the copy crosses and the arithmetic never lands on the actor
    /// that has to draw the window.
    private func loadReport() async {
        guard let metricStore, let groomingLedger else {
            report = .unavailable
            return
        }
        let runs = metricStore.records
        let grooming = groomingLedger.records
        let period = PortfolioReport.Period.last(hours: Self.reportHours, endingAt: Date())
        let built = await Task.detached(priority: .utility) {
            PortfolioReport.make(runs: runs, grooming: grooming, period: period)
        }.value
        report = .ready(built)
    }

    // MARK: - Building blocks

    /// One section: its title, and either its content, a spinner, or the one line
    /// that says why there is nothing.
    @ViewBuilder
    private func section<Content, Inner: View>(
        _ title: String,
        _ icon: String,
        _ availability: CoordinatorPanelModel.Availability<Content>,
        @ViewBuilder content: (Content) -> Inner
    ) -> some View {
        VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.md) {
            AutonomyLoopSectionHeader(title: title, icon: icon)
            switch availability {
            case .shown(let value):
                content(value)
            case .loading:
                ProgressView().controlSize(.small)
            case .notAvailable(let reason):
                Text("Not available — \(reason)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func omitted(_ label: String?) -> some View {
        if let label {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}
