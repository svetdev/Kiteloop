import KiteloopCore
import SwiftUI

/// The fleet-wide hold as a side pane, so the state that matters while pausing
/// a fleet has somewhere to be read.
///
/// The control existed only as a box in the sidebar footer: a title, one elided
/// state line, and the verb. That is the right size for "is the fleet held?" and
/// the wrong size for every question that follows it — which projects are still
/// finishing, what each is on, whose queue this pause is holding, and how much
/// each of them is holding back. The Coordinator next door had already solved
/// the same shape in a drawer of its own, so this is that shape applied: the
/// footer box stays the compact summary and opens this.
///
/// It derives nothing. Every line here is a field of the one
/// `FleetQuiesceStatus` the footer box draws — see that type — so the drawer and
/// the box cannot come to disagree about what the fleet is doing. The two
/// controls call the same `FleetQuiesceControl` the footer's do, which is the
/// same seam `POST /v1/fleet/quiesce` drives.
///
/// The Planner lives here too (2026-11-02). Running work unattended is one
/// question — is the fleet taking work, what is the Planner grooming, what did
/// it produce — and two drawers split it, each with its own projects table.
/// So the fleet's state and controls come first, the Planner's state and
/// recent passes under them, and one Projects table carries both drawers'
/// columns. The budget is the sidebar's to show, once.
struct FleetDrawer: View {
    /// Where the drawer was opened to: the top, from the sidebar's Fleet row,
    /// or the Planner, from its own row.
    enum Focus: Hashable { case top, planner }

    /// Which drawer is open, and at which section, after a sidebar row asks
    /// for `section`: the fleet drawer there — unless it is already showing
    /// exactly that, which closes it, the way a drawer's own row always has.
    static func afterAsking(for section: Focus, open: SidebarDrawer?,
                            focus: Focus) -> (open: SidebarDrawer?, focus: Focus) {
        (open == .fleet && focus == section ? nil : .fleet, section)
    }
    /// What the fleet last read, or nil before the first reading has landed —
    /// the state the footer box draws nothing in. This drawer is persisted open
    /// across launches, so unlike the box it is on screen for those two seconds
    /// and says what it is waiting for.
    let status: FleetQuiesceStatus?
    /// The execution controls' inputs — the fleet runs, so its switch, budget,
    /// consent roster and starts history live here. All optional: a window
    /// without them shows the quiesce surface alone.
    var scheduler: CoordinatorRunScheduler?
    var globalConfigStore: GlobalConfigStore?
    var registry: ControlSessionRegistry?
    var refill: CoordinatorQueueRefill?
    /// The Planner's inputs: the portfolio as the landing screen lists it,
    /// and the two ledgers its passes and the Projects table's last day are
    /// read from.
    var recentProjects: [RecentProject] = []
    var vaultURL: URL?
    var metricStore: TaskMetricStore?
    var groomingLedger: GroomingLedger?
    var focus: Focus = .top
    @State private var summaries: [PortfolioProjectSummary] = []

    /// Same key as before the move, so the reader's open/closed choice
    /// survives the section changing homes.
    @AppStorage("coordinatorDrawerStartsExpanded") private var startsExpanded = false
    /// Hold every advancing queue and refuse new runs.
    let onQuiesce: () -> Void
    /// Lift that hold.
    let onResume: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView { sections.id(Focus.top) }
                    .onAppear { proxy.scrollTo(focus, anchor: .top) }
                    .onChange(of: focus) { _, section in
                        withAnimation { proxy.scrollTo(section, anchor: .top) }
                    }
            }
        }
        .background(.background)
        .accessibilityIdentifier("fleet-drawer")
        .task(id: recentProjects.map(\.id).joined(separator: ",")) {
            summaries = await PortfolioSummaryLoader.load(recentProjects, vaultURL: vaultURL,
                                                          grooming: groomingLedger?.records ?? [])
        }
    }

    /// The Planner's state, controls and recent passes — its own panel, drawn
    /// into this one.
    @ViewBuilder
    private var plannerSection: some View {
        if let refill {
            VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.sm) {
                AutonomyLoopSectionHeader(title: "Planner", icon: "point.3.connected.trianglepath.dotted")
                CoordinatorPanel(
                    refill: refill,
                    projects: summaries.map(PortfolioSection.coordinatorInput),
                    metricStore: metricStore,
                    groomingLedger: groomingLedger,
                    scheduler: scheduler,
                    globalConfigStore: globalConfigStore,
                    standalone: false,
                    plannerOnly: true,
                    registry: registry
                )
            }
            .padding(KiteloopTokens.Spacing.lg)
            .id(Focus.planner)
            .accessibilityIdentifier("fleet-drawer-planner")
            Divider()
        }
    }

    private var sections: some View {
        VStack(spacing: 0) {
            FleetRunControls(scheduler: scheduler,
                             globalConfigStore: globalConfigStore,
                             registry: registry,
                             refill: refill)
                .padding(.horizontal, KiteloopTokens.Spacing.lg)
                .padding(.vertical, KiteloopTokens.Spacing.sm)
            Divider()
            if let status {
                stateSection(status)
            }
            Divider()
            plannerSection
            startsSection
            if let status {
                Divider()
                if let registry {
                    // One table, every facet: replaces the status-derived rows
                    // (and the consent roster that lived in the controls above).
                    FleetBoard(registry: registry, metricStore: metricStore, groomingLedger: groomingLedger)
                        .padding(.horizontal, KiteloopTokens.Spacing.md)
                        .padding(.bottom, KiteloopTokens.Spacing.sm)
                } else {
                    projectsSection(status.projects)
                }
            } else {
                Text("The fleet hasn't been read yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(KiteloopTokens.Spacing.lg)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - State and the action

    /// Where the fleet is, and the one control that changes it.
    ///
    /// The state line leads because it is the answer somebody opened this for:
    /// held and quiet are different facts and only the second makes a restart
    /// safe. The verb sits under it rather than above, for the same reason the
    /// footer draws them in that order — you read where the fleet is, then
    /// decide.
    private func stateSection(_ status: FleetQuiesceStatus) -> some View {
        VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.sm) {
            AutonomyLoopSectionHeader(title: "Fleet state", icon: "dot.radiowaves.left.and.right")
            Text(status.stateLine)
                .font(.system(.callout, weight: .semibold))
                .foregroundStyle(tint(status.state))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("fleet-drawer-state")

            // What the footer has to cap at three projects and a "+2 more": the
            // sentence is still drawn here, above the list that spells it out,
            // because "2 run(s) finishing" and *which two* are different reads
            // and the summary is the one you take at a glance.
            if let stillRunning = status.stillRunning {
                Text("finishing now: \(stillRunning)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("fleet-drawer-still-running")
            }

            if let quitNotice = status.quitNotice {
                Text(quitNotice)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("fleet-drawer-quit-notice")
            }

            Button {
                switch status.action {
                case .quiesce: onQuiesce()
                case .resume: onResume()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: status.action == .quiesce ? "pause.circle" : "play.circle")
                    Text(status.action == .quiesce ? "Pause fleet" : "Resume")
                }
            }
            .disabled(!status.canAct)
            .help(status.help)
            .accessibilityIdentifier("fleet-drawer-action")

            // The same sentence the footer's hover carries, drawn rather than
            // hovered: this pane is where somebody decides whether to press it,
            // and "does this interrupt the run in flight?" should not be a
            // question you have to hover to have answered.
            Text(status.help)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("fleet-drawer-help")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(KiteloopTokens.Spacing.lg)
    }

    // MARK: - Projects

    /// Every open project, one row each — the list the footer could only give as
    /// a capped sentence.
    @ViewBuilder
    private func projectsSection(_ projects: [FleetQuiesceStatus.ProjectRow]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Projects")
                .font(.system(.caption, weight: .semibold))
                .padding(.horizontal, KiteloopTokens.Spacing.md)
                .padding(.vertical, KiteloopTokens.Spacing.sm)

            if projects.isEmpty {
                Text("No project is open, so the fleet has no queue to hold. The gate still applies: a run requested over the control API is refused while the fleet is paused.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, KiteloopTokens.Spacing.md)
                    .padding(.bottom, KiteloopTokens.Spacing.sm)
                    .accessibilityIdentifier("fleet-drawer-no-projects")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.md) {
                        ForEach(projects) { row in
                            projectRow(row)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, KiteloopTokens.Spacing.md)
                    .padding(.bottom, KiteloopTokens.Spacing.sm)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One project: what it is, what it is on, and where that leaves it.
    ///
    /// The item is an `ItemLink` for the reason every other item mention in the
    /// app is one — a fleet drain names items in projects that are not the
    /// active tab, and reading one used to mean remembering the id and going to
    /// find it. The fleet reading addresses a project by folder name, like the
    /// Coordinator's records do.
    private func projectRow(_ row: FleetQuiesceStatus.ProjectRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: KiteloopTokens.Spacing.sm) {
                Circle()
                    .fill(row.isRunning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
                    .frame(width: 6, height: 6)
                Text(row.name)
                    .font(.system(.caption, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: KiteloopTokens.Spacing.sm)
            }
            if let item = row.item {
                ItemLink(item, in: .name(row.name)) {
                    Text(item)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                }
            }
            Text(row.line)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("fleet-drawer-project-\(row.id)")
    }

    // MARK: - Chrome

    /// Paused-and-quiet is the state the control is pressed to reach, so it is
    /// the one that reads as good news; pausing is in-between and says so. The
    /// footer box colours itself the same way, off the same state.
    private func tint(_ state: FleetQuiesceStatus.State) -> Color {
        switch state {
        case .takingWork: .secondary
        case .draining: .orange
        case .held: .green
        }
    }

    /// The same capsule language the Coordinator's header speaks — green when
    /// the fleet takes work unattended, orange while paused, grey when every
    /// start is a human's.
    private var stateChip: some View {
        let (label, color): (String, Color) =
            (status.map { $0.state != .takingWork } ?? false) ? ("paused", .orange)
            : (scheduler?.enabled ?? false) ? ("On — unattended", .green)
            : ("manual", .gray)
        return Text(label)
            .font(.system(.caption2, weight: .semibold))
            .padding(.horizontal, KiteloopTokens.Spacing.md)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(KiteloopTokens.Opacity.medium)))
            .foregroundStyle(color == .gray ? Color.secondary : color)
            .accessibilityIdentifier("fleet-drawer-state")
    }

    private var header: some View {
        HStack(spacing: KiteloopTokens.Spacing.sm) {
            Image(systemName: "square.grid.2x2")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("Fleet")
                .font(.system(.caption, weight: .semibold))
            AutonomyScopeLabel(text: AutonomyScopeLabel.allProjects)
            stateChip
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark").font(.caption2)
            }
            .buttonStyle(.plain)
            .help("Close Fleet")
            .accessibilityIdentifier("fleet-drawer-close")
        }
        .padding(.horizontal, KiteloopTokens.Spacing.md)
        .padding(.vertical, KiteloopTokens.Spacing.xs)
        .background(.ultraThinMaterial)
    }

    // MARK: - Starts

    /// What the scheduler did unattended, and what it is standing on now.
    ///
    /// The scheduler has recorded every autonomous start since it existed —
    /// `startHistory`, a line in `~/.kiteloop/coordinator-starts.jsonl`, a run
    /// record — and `GET /v1/coordinator/scheduling` served all of it, but no
    /// screen read any of it: the app could not say what it had done overnight,
    /// and answering that meant reading the JSONL by hand. This is the same
    /// records, in the place the Coordinator is reachable with a project open.
    ///
    /// It reads and nothing else — `CoordinatorStartsModel` is a value with no
    /// method that can start a run, so unfolding this list is as inert as leaving
    /// it closed.
    @ViewBuilder
    private var startsSection: some View {
        VStack(spacing: 0) {
            if let starts = CoordinatorStartsModel.capture(scheduler) {
                startsHeader(starts)
                if startsExpanded {
                    Divider()
                    startsList(starts.rows)
                }
            } else {
                Text("Autonomous scheduling isn't wired into this window, so there are no starts to show.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, KiteloopTokens.Spacing.md)
                    .padding(.vertical, KiteloopTokens.Spacing.sm)
            }
            Divider()
        }
    }

    /// The disclosure, and under it the standing decision — drawn whether or not
    /// the list is open.
    private func startsHeader(_ starts: CoordinatorStartsModel) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { startsExpanded.toggle() }
            } label: {
                HStack(spacing: KiteloopTokens.Spacing.sm) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(startsExpanded ? 90 : 0))
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.caption2)
                        .foregroundStyle(.teal)
                    // The shared heading's weight and size. It keeps its own
                    // chevron and icon because it is a disclosure, but the title
                    // beside them now reads at the same size as every other
                    // section heading in either loop.
                    Text("Autonomous starts")
                        .font(.system(.subheadline, weight: .semibold))
                    if !starts.rows.isEmpty {
                        Text("\(starts.rows.items.count)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: KiteloopTokens.Spacing.sm)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Runs the fleet started by itself, newest first — what it picked, why, and how each ended")
            .accessibilityIdentifier("coordinator-drawer-starts-header")

            // Every kind reads the same way on purpose. A hold is information —
            // "off", "budget spent", "nothing ready" are ordinary answers — and
            // drawing them as faults would leave nothing to distinguish the one
            // that is a fault, which the row's own colour is for.
            Text(starts.standing.text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("coordinator-drawer-standing-decision")
        }
        .padding(.horizontal, KiteloopTokens.Spacing.md)
        .padding(.vertical, KiteloopTokens.Spacing.sm)
    }

    @ViewBuilder
    private func startsList(_ starts: CoordinatorPanelModel.BoundedList<CoordinatorStartsModel.Row>)
        -> some View {
        if starts.isEmpty {
            Text("Nothing has been started unattended yet. Every autonomous start is listed here.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, KiteloopTokens.Spacing.md)
                .padding(.vertical, KiteloopTokens.Spacing.sm)
        } else {
            // Bounded like the review list below, so the conversation keeps its
            // room: a night of starts scrolls inside this rather than pushing the
            // chat off the bottom of the drawer.
            ScrollView {
                VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.md) {
                    ForEach(starts.items) { row in
                        startRow(row)
                    }
                    if let label = starts.omittedLabel {
                        Text(label)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, KiteloopTokens.Spacing.md)
                .padding(.vertical, KiteloopTokens.Spacing.sm)
            }
            .frame(maxHeight: 260)
        }
    }

    private func startRow(_ row: CoordinatorStartsModel.Row) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: KiteloopTokens.Spacing.md) {
                // These rows are the drawer's real item mentions: each names an
                // item in a project, often one that isn't the active tab, and
                // reading back an unattended night meant remembering the id and
                // going to find it. The record addresses its project by folder
                // name — see `ItemLinkProject`.
                ItemLink(row.itemID, in: .name(row.project)) {
                    Text(row.headline)
                        .font(.caption)
                        .lineLimit(1)
                }
                Spacer(minLength: KiteloopTokens.Spacing.md)
                // The record's own word for how it ended, not a paraphrase of it.
                Text(row.outcome)
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundStyle(outcomeColor(row.kind))
            }
            Text("\(stamp(row.at)) · \(row.subtitle)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(row.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            // Only the outcomes that don't explain themselves — a refusal, and a
            // run whose app went away under it.
            if let note = row.note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// When it went. The stamp `BacklogItemDetailView` prints for an instant, so
    /// two screens about the same run don't date it two ways.
    private func stamp(_ at: Date) -> String {
        at.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    private func outcomeColor(_ kind: CoordinatorStartsModel.Row.Kind) -> Color {
        switch kind {
        case .done: return .green
        // In flight, or finished and waiting on a person — both are states, not
        // faults.
        case .running, .awaitingApproval: return .blue
        case .blocked, .cancelled, .didNotRun: return .orange
        case .interrupted, .other: return .secondary
        }
    }


}
