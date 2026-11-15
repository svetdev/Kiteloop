import KiteloopCore
import AppKit
import Combine
import SwiftUI

struct AutopilotView: View {
    @Bindable var autopilot: BacklogAutopilot
    var agents: [Agent]
    var chatViewModels: [String: ChatViewModel]
    @Bindable var backlogViewModel: BacklogViewModel
    /// The run ledger and its queryable projection, for the item page this panel
    /// opens: every row here names an item, and until this existed a red history
    /// row was the one place in the app you could see an item fail and have
    /// nowhere to click. Optional so a caller without them still gets the panel —
    /// the rows then carry no page rather than an empty one.
    var metricStore: TaskMetricStore?
    var metricIndex: MetricIndex?
    /// Where a human release of the retry ceiling is read from, for the page's
    /// actions. Defaulted to the app-wide ledger, as the backlog view defaults it.
    var groomingLedger: GroomingLedger = .shared
    /// What the autonomy ladder is assessed from. All optional: without them the
    /// ladder simply isn't drawn, the way the panel treats its other stores.
    ///
    /// The ladder used to live only behind a link in the fleet drawer — a
    /// different surface from the one somebody setting a project up is looking
    /// at. It is the only place that states the order the switches go in, so a
    /// person in this tab asking "what turns this on" had no way to find the
    /// answer, and three config panels in three scopes read as three unrelated
    /// settings screens rather than rungs of one ladder.
    var refill: CoordinatorQueueRefill?
    var scheduler: CoordinatorRunScheduler?
    var globalConfigStore: GlobalConfigStore?
    var controlRegistry: ControlSessionRegistry?

    @State private var workerMessages: [Message] = []
    @State private var reviewerMessages: [Message] = []
    @State private var lastWorkerCount: Int = 0
    @State private var lastReviewerCount: Int = 0
    /// Which transcript the right column shows, whether the person pinned it
    /// this run, and which tab has output it has not shown.
    @State private var transcriptTabs = AutopilotTranscriptTabs()
    @State private var workerSelection: String = ""
    @State private var reviewerSelection: String = ""
    @State private var showingSettings = false
    /// Opens the project's settings sheet on a page. Installed by the main
    /// window; a preview or test host without it shows the link disabled.
    @Environment(\.openProjectSettings) private var openProjectSettings
    @State private var localSelectedItems: Set<String> = []
    @State private var expandedExecutionID: String?
    /// The item whose gate is being resolved, so both buttons disable while a
    /// merge and its verify run — they can take minutes.
    @State private var resolvingGateFor: String?
    /// What resolving each gate did, kept on screen afterwards. A failed merge
    /// leaves the item at the gate, and that must not pass unnoticed.
    @State private var gateNotes: [String: GateNote] = [:]
    /// The item whose refusal output is open in a popover.
    @State private var showingRefusalOutputFor: String?
    /// The page each gated item's newest QA run kept, by item id — looked up
    /// when the gated items change, never on a redraw.
    @State private var storyboardPages: [String: URL] = [:]
    /// The storyboard open in a sheet over the panel.
    @State private var shownStoryboard: ShownStoryboard?
    /// The note being typed for the worker of the run in flight, and what came
    /// of the last one sent. The outcome stays on screen because delivery is at
    /// the worker's next turn boundary — the field emptying is the only thing
    /// that happens immediately, and on its own it reads like the note vanished.
    @State private var steerText: String = ""
    @State private var steerOutcome: BacklogAutopilot.SteerOutcome?
    // Collapsed by default, and remembered across launches: History is finished
    // work, the box above it is the run happening now, and the column is only so
    // tall. Persisted globally rather than per project — it's a reading
    // preference about this panel, not a fact about a backlog.
    @AppStorage("autopilotHistoryExpanded") private var historyExpanded = false
    /// The item whose page is open over this panel, and the model behind it.
    /// Built when the page opens rather than per row: it queries the metric
    /// index and git, which is not work to do for every line of a console.
    @State private var detailModel: BacklogItemDetailViewModel?
    /// The trust ladder, assessed from the loops — nil while they are not wired,
    /// since a ladder built from nothing reports every rung unmet and sends
    /// someone to switches that are already on.
    ///
    /// Lives behind the gear rather than as a row of its own: a checklist that
    /// stays open across the top of the console takes the space the queue
    /// needs, and once every rung is met it is just nagging. The gear carries
    /// the count of unmet rungs, so the state is still read at a glance.
    private var ladderRungs: [AutonomyLadder.Rung]? {
        guard let refill else { return nil }
        return AutonomyLadder.assess(.capture(
            registry: controlRegistry, refill: refill,
            scheduler: scheduler, store: globalConfigStore))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            AutopilotFleetControls(autopilot: autopilot)
            Divider()
            gridContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The item page, over the whole console. The panel stays mounted
        // underneath, so Back returns to the run exactly as it was left.
        .itemDetailPage(detailModel) { detailModel = nil }
        .onAppear {
            workerSelection = autopilot.workerAgentID ?? ""
            reviewerSelection = autopilot.reviewerAgentID ?? ""
                localSelectedItems = autopilot.selectedItemIDs
        }
        // Keep the mirrors in sync when the worker/reviewer are set on the
        // settings page or over the control API.
        .onChange(of: autopilot.workerAgentID) { _, newValue in
            let resolved = newValue ?? ""
            if workerSelection != resolved { workerSelection = resolved }
        }
        .onChange(of: autopilot.reviewerAgentID) { _, newValue in
            let resolved = newValue ?? ""
            if reviewerSelection != resolved { reviewerSelection = resolved }
        }
        // A run clears the selection when it ends, and the item page, the
        // scheduler and the control API replace it — the ticks follow suit.
        .onChange(of: autopilot.selectedItemIDs) { _, newValue in
            if localSelectedItems != newValue { localSelectedItems = newValue }
        }
        // A note describes a condition at the gate. Once the item is no longer
        // at one — merged, rejected, or picked up by another run — the condition
        // is gone with it, and the note must not be waiting there when the item
        // comes back for approval a second time.
        .onChange(of: gatedItems.map(\.id)) { _, ids in
            let stillGated = Set(ids)
            gateNotes = gateNotes.filter { stillGated.contains($0.key) }
            if let shown = showingRefusalOutputFor, !stillGated.contains(shown) {
                showingRefusalOutputFor = nil
            }
        }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            syncAgentMessages()
        }
    }

    // MARK: - Header

    /// One row, always — every label in it is `lineLimit(1)`.
    ///
    /// A label left free to wrap is what put a quarter of this panel's height
    /// into empty space (screenshot: `backlog/autopilot-panel-dead-space.png`).
    /// Narrow the pane past the point where the row's controls fit — a run in
    /// flight adds the Stop All button, the Coordinator drawer takes ~400pt off
    /// the width — and SwiftUI compresses the only flexible things here, the
    /// text labels, down towards zero width. A role label then wraps one or
    /// two characters per line into a ~190pt column, the whole HStack grows to
    /// that height, and its real content sits centred in the middle of it: dead
    /// space above the header *and* below it, which reads as the panel starting
    /// far down the window. Measured at an 872pt pane: 40pt row idle, 189pt with
    /// a run in flight. Truncating is the right thing to give up here — the row
    /// keeps every control reachable and the labels have `.help` text.
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 14))
                .foregroundStyle(.yellow)
            Text("Autopilot")
                .font(.system(.title3, weight: .semibold))
                .lineLimit(1)
            // The counterpart to "all projects" on the two portfolio surfaces:
            // this tab's switches govern one project, and it says which.
            if let projectName = autopilot.projectName {
                AutonomyScopeLabel(text: projectName)
            }
            statusBadge
                .lineLimit(1)
            Spacer()

            teamControls

            Divider().frame(height: 16)

            settingsButton

            if !isIdle {
                Button { autopilot.stop() } label: {
                    Label("Stop All", systemImage: "stop.fill")
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
                .controlSize(.small)
                .tint(.red)
                .accessibilityIdentifier("autopilot-stop-button")
                .help("Stop all runs immediately")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Who runs the queue, read out in the title row. Set once per project,
    /// so the pickers live on the Autopilot settings page and this is the way
    /// there: the two pickers took the most width in the row and, in a narrow
    /// center column, pushed the status off it. The roles are labelled because
    /// a bare "Claude" in a header says nothing about which seat it fills.
    private var teamControls: some View {
        Button {
            openProjectSettings(.autopilot)
        } label: {
            Text("Worker: \(roleName(workerSelection)) · Reviewer: \(roleName(reviewerSelection))")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                // Truncate rather than wrap: a label that may wrap is a label
                // that can be hundreds of points tall. See `header`.
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .buttonStyle(.plain)
        .disabled(!openProjectSettings.isInstalled)
        .accessibilityIdentifier("autopilot-roles-button")
        .help("The worker implements each item; the reviewer checks its diff. Click to change them in Autopilot settings.")
    }

    /// The agent filling a role, "Choose…" when none is.
    private func roleName(_ agentID: String) -> String {
        agentID.isEmpty ? "Choose…" : agentName(for: agentID)
    }

    /// Why Run is disabled, in the order you'd fix it — nil when it's runnable
    /// (or already running, which the status badge covers).
    private var missingRunRequirement: String? {
        guard isIdle else { return nil }
        switch (workerSelection.isEmpty, reviewerSelection.isEmpty) {
        case (true, true): return "Pick a worker and reviewer"
        case (true, false): return "Pick a worker"
        case (false, true): return "Pick a reviewer"
        case (false, false): return nil
        }
    }

    /// The gear: the setup checklist, one click from the run it governs, with
    /// the count of unmet rungs worn as a badge. The run switches and the caps used to be here too — a popover holding
    /// fourteen switches, three caps and a five-rung ladder was a settings
    /// window attached to a button — and now live on the project's Autopilot
    /// settings page, which the popover opens in one click.
    private var settingsButton: some View {
        let rungs = ladderRungs
        let unmet = rungs?.filter { !$0.met }.count ?? 0
        return Button { showingSettings.toggle() } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 13))
                .overlay(alignment: .topTrailing) {
                    // The unmet count, the way an inbox wears its unread count:
                    // nothing when every rung is met.
                    if unmet > 0 {
                        Text("\(unmet)")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(.orange, in: Capsule())
                            .offset(x: 8, y: -6)
                            .accessibilityIdentifier("autopilot-settings-badge")
                    }
                }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("autopilot-settings-button")
        .help(settingsHelp(rungs: rungs, unmet: unmet))
        .popover(isPresented: $showingSettings, arrowEdge: .bottom) {
            settingsPopover(rungs: rungs)
        }
    }

    private func settingsHelp(rungs: [AutonomyLadder.Rung]?, unmet: Int) -> String {
        let settings = "Autopilot settings — team, run switches, pickup stages, cost caps"
        guard let rungs else { return settings }
        let ladder = unmet == 0
            ? "Setting up autonomy — every rung met"
            : "Setting up autonomy — \(rungs.count - unmet) of \(rungs.count) rungs met, \(unmet) to go"
        return ladder + ". " + settings
    }

    /// The ladder while the loops are wired to assess it, and the way to the
    /// page with everything else. The project's opt-in is a switch under the
    /// title row now (`AutopilotFleetControls`).
    private func settingsPopover(rungs: [AutonomyLadder.Rung]?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let rungs {
                AutonomyLadderView(rungs: rungs)
                    .accessibilityIdentifier("autopilot-autonomy-ladder")
                Divider()
            }
            settingsLink
        }
        .frame(width: 340)
        .accessibilityIdentifier("autopilot-settings-popover")
    }

    private var settingsLink: some View {
        Button {
            showingSettings = false
            openProjectSettings(.autopilot)
        } label: {
            Label("Autopilot settings…", systemImage: "slider.horizontal.3")
                .font(.caption)
        }
        .buttonStyle(.link)
        .disabled(!openProjectSettings.isInstalled)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityIdentifier("autopilot-open-settings-button")
        .help("Worker and reviewer, worktree isolation, review rounds, auto-merge, the stages autopilot may pick up, and the cost caps — on the project's settings page.")
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch autopilot.status {
        case .idle:
            Text("Idle")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.gray.opacity(0.15), in: Capsule())
                .foregroundStyle(.secondary)
        case .running(let idx, let total):
            Text("Running \(idx + 1)/\(total)")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.blue.opacity(0.15), in: Capsule())
                .foregroundStyle(.blue)
        case .reviewing(let idx, let total, let attempt):
            Text("Review \(idx + 1)/\(total) · attempt \(attempt)")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.orange.opacity(0.15), in: Capsule())
                .foregroundStyle(.orange)
        case .paused:
            Text("Paused")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.yellow.opacity(0.15), in: Capsule())
                .foregroundStyle(.orange)
        }
    }

    private var isIdle: Bool {
        if case .idle = autopilot.status { return true }
        return false
    }

    // MARK: - Grid

    private var gridContent: some View {
        // The split is driven straight off the geometry proposal. It used to go
        // the long way round: a GeometryReader in `.background` published the
        // measured width as a preference, `onPreferenceChange` wrote it to
        // `availableWidth`, and that state sized the left column — whose layout
        // re-emitted the preference. That cycle settles while the view is quiet,
        // which is why resizing the window never showed it, but it never settles
        // while the transcripts stream: on 2026-08-04 it pinned the main thread
        // at 99% CPU within four minutes of starting a run, twice, with
        // GraphHost.LayoutInvalidator and DynamicPreferenceCombiner at the top
        // of the sample. Reading `geo` directly keeps the width out of view
        // state, so measurement can't feed back into layout.
        GeometryReader { geo in
            let leftWidth = max(280, geo.size.width * 0.35)
            HStack(spacing: 0) {
                // Left column: 3 boxes — Backlog / Execution / History
                VStack(spacing: 0) {
                    backlogBox
                    Divider()
                    executionBox
                    Divider()
                    historyBox
                }
                .frame(width: leftWidth)

                Divider()

                // Right column
                transcriptPane
                    .frame(maxWidth: .infinity)
            }
        }
    }


    // MARK: - Backlog Box (top)

    private var backlogBox: some View {
        VStack(alignment: .leading, spacing: 0) {
            boxHeader("BACKLOG", icon: "checklist")

            // Worker, reviewer and Coordinator now sit in the title row; this
            // box is the queue and nothing else.

            Divider()

            // The one item list: what the run still has to do, in run order,
            // then what's left to pick from. The Execution box used to repeat the
            // queued half of this under its own QUEUE heading — see
            // `AutopilotQueueList`.
            if backlogViewModel.backlogFile != nil {
                queueHealthLine
                approvalGate
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(queueGroups) { group in
                            listGroupHeader(group)
                            ForEach(group.rows) { row in
                                itemRow(row)
                            }
                        }
                    }
                }
            } else {
                Spacer()
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                Spacer()
            }

            Divider()

            // Action bar
            HStack(spacing: 8) {
                // With the team named up in the title row, an unassigned pair is no
                // longer visible right above this button — so say why Run is off
                // rather than leaving a greyed-out control with no explanation.
                if let missing = missingRunRequirement {
                    Label(missing, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("autopilot-run-blocked-hint")
                } else {
                    Text("\(selectedPickableCount) selected")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    if !pickableSelection.isEmpty {
                        localSelectedItems.removeAll()
                        autopilot.selectedItemIDs = localSelectedItems
                    } else {
                        selectAllQueueItems()
                    }
                } label: {
                    Text(pickableSelection.isEmpty ? "All" : "Clear")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .accessibilityIdentifier("autopilot-select-toggle-button")
                .help(pickableSelection.isEmpty ? "Select all queued items" : "Clear selection")

                Button {
                    startRun()
                } label: {
                    Label("Run", systemImage: "play.fill")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
                .accessibilityIdentifier("autopilot-run-button")
                .help("Run selected items through the worker/reviewer loop")
                .disabled(pickableSelection.isEmpty || workerSelection.isEmpty || reviewerSelection.isEmpty || !isIdle)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(maxHeight: .infinity)
    }

    /// What this queue actually is: how much of the Ready column autopilot could
    /// pick up right now, and what is holding the rest.
    ///
    /// The list below is a list of items, and a list of items nothing can start
    /// looks exactly like a healthy one — the failure `QueueHealth` was written
    /// for. That reading existed only on the no-project landing screen, so with a
    /// project open, which is where the work happens, "how many of these could
    /// start, and what is holding the rest?" had no answer on screen.
    ///
    /// `queueSummary` rather than `summary`: the approval gate directly below
    /// names every item waiting on a human and carries the buttons that resolve
    /// it, so the clause `summary` ends with would be saying it twice.
    private var queueHealthLine: some View {
        let queue = backlogViewModel.queueHealth
        return Text(queue.queueSummary)
            .font(.system(size: 10))
            .foregroundStyle(queue.isStalled ? Color.orange : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .accessibilityIdentifier("autopilot-queue-health")
            .help("How much of the Ready column autopilot could pick up right now, and what is holding the rest — the same reading the Portfolio screen's project card carries.")
    }

    /// The merged list, rebuilt from the backlog and the live run queue.
    private var queueGroups: [AutopilotQueueList.Group] {
        AutopilotQueueList.groups(
            sections: backlogViewModel.backlogFile?.sections ?? [],
            pickupStages: backlogViewModel.workflow.autopilotPickupStages,
            runQueue: autopilot.runQueue,
            activeIndex: activeRunIndex,
            selectedItemIDs: localSelectedItems
        )
    }

    /// Only the rows still offered as a choice — a queued row's pick was made
    /// when the run started.
    private var pickableItemIDs: Set<String> {
        AutopilotQueueList.selectableIDs(in: queueGroups)
    }

    /// Counted against what's on screen, so the action bar can't claim a
    /// selection with no ticked row to point at while a run holds those items.
    private var selectedPickableCount: Int {
        pickableSelection.count
    }

    /// The ticks that still have a row: what Run, the count and All/Clear read,
    /// and all a start hands the autopilot.
    private var pickableSelection: Set<String> {
        AutopilotQueueList.pickableSelection(localSelectedItems, in: queueGroups)
    }

    /// Run each item in its own git worktree/branch `kiteloop/<item-id>`
    /// (ADR-0001) instead of the live tree. Persisted per project
    /// (`autopilot-config.json`) the moment it changes, like the pickers above.
    /// Safe to flip mid-run: the in-flight item keeps the tree it started in
    /// (its worktree is captured at setup and torn down with it), so the change
    /// takes effect on the next item.
    // MARK: - Execution Box (middle)

    private var executionBox: some View {
        VStack(alignment: .leading, spacing: 0) {
            executionPanelHeader
            Divider()
            economicsRow
            Divider()
            if autopilot.canSteer || steerOutcome != nil {
                steerRow
                Divider()
            }
            if !isIdle || !autopilot.runQueue.isEmpty {
                activeExecutionContent
            } else {
                VStack(spacing: 4) {
                    Spacer()
                    Image(systemName: "play.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(.quaternary)
                    Text("No active run")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var executionPanelHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "play.circle")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text("EXECUTION")
                .font(.system(.caption2, weight: .semibold))
                .foregroundStyle(.tertiary)
            Spacer()
            executionControls
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - History Box (bottom) — one row unless expanded

    /// Collapsed, this is its header and nothing else, so the Execution box above
    /// takes the third of the column the list used to hold. The counts move into
    /// the header rather than disappearing: the list is what you open when
    /// something in the summary looks wrong.
    private var historyBox: some View {
        VStack(alignment: .leading, spacing: 0) {
            historyHeader
            if historyExpanded {
                if !autopilot.results.isEmpty || !autopilot.runHistory.isEmpty {
                    historyContent
                } else if !autopilot.log.isEmpty {
                    logList
                } else {
                    emptyHistoryState
                }
            }
        }
        // Collapsed the box is exactly its header; expanded it competes with
        // Execution for the column as before.
        .frame(minHeight: historyExpanded ? 60 : nil, maxHeight: historyExpanded ? .infinity : nil)
    }

    private var historyHeader: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { historyExpanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(historyExpanded ? 90 : 0))
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text("HISTORY")
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundStyle(.tertiary)
                if !historyExpanded {
                    Text(historySummary.text)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityIdentifier("autopilot-history-summary")
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("autopilot-history-toggle")
        .help(historyExpanded ? "Collapse run history" : "Expand run history")
    }

    private var historySummary: AutopilotHistorySummary.Summary {
        AutopilotHistorySummary.make(
            // Mirrors the expanded list: the run in flight contributes its
            // finished items, and once it's idle those items are records instead.
            liveResults: isIdle ? [] : autopilot.results,
            runHistory: autopilot.runHistory
        )
    }

    private var emptyHistoryState: some View {
        VStack(spacing: 4) {
            Spacer()
            Text("No completed runs")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var executionControls: some View {
        switch autopilot.status {
        case .running, .reviewing:
            HStack(spacing: 4) {
                Button { autopilot.pause() } label: {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
                .help("Pause after current item")

                Button { autopilot.stop() } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .help("Stop immediately")
            }
        case .paused:
            Button {
                Task { await autopilot.resume() }
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.green)
            .help("Resume execution")
        case .idle:
            EmptyView()
        }
    }

    // MARK: Steering

    /// The one thing an operator can do to a run in flight short of killing it:
    /// hand its worker a sentence.
    ///
    /// Pinned under the spend readout rather than placed in the scrolling
    /// transcript below, because the moment it is wanted is the moment you are
    /// reading the transcript and watching the worker go the wrong way — a
    /// control that had scrolled off the top by then is a control you cancel the
    /// run instead of finding.
    ///
    /// It appears only while there is a worker to reach (`canSteer`), which is
    /// what makes "sending with no run in flight" impossible rather than
    /// something that queues quietly for whatever runs next. It lingers for one
    /// beat after a run ends when an outcome is on screen, so the last thing
    /// sent doesn't disappear along with the field.
    private var steerRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "quote.bubble")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                TextField("Note to the worker — advice, not a change to the item", text: $steerText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .disabled(!autopilot.canSteer)
                    .onSubmit(sendSteerNote)
                    .accessibilityIdentifier("autopilot-steer-field")
                Button("Send", action: sendSteerNote)
                    .controlSize(.small)
                    .disabled(!autopilot.canSteer || RunSteerNote.sanitize(steerText) == nil)
                    .accessibilityIdentifier("autopilot-steer-send")
            }
            if let outcome = steerOutcome {
                switch outcome {
                case .sent:
                    Text("Sent — the worker reads it when its current turn ends.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                case .refused(let reason):
                    Text(reason)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("autopilot-steer")
        // A note belongs to the item it was about. Carrying "Sent" — or a
        // half-typed correction — across into the next item would offer both to
        // a worker they were never meant for.
        .onChange(of: currentRunItem?.id) {
            steerOutcome = nil
            steerText = ""
        }
        .help("Hands the worker a short note, delivered when its current turn ends. "
              + "It is advice: the item's What / How / Validation still govern the review, "
              + "and a note cannot approve work, raise a cap, or reach the reviewer. "
              + "Every note is recorded in the run transcript and in the item's Notes.")
    }

    private func sendSteerNote() {
        let outcome = autopilot.steerWorker(steerText)
        steerOutcome = outcome
        if case .sent = outcome { steerText = "" }
    }

    // MARK: Active Run

    /// The item in flight and nothing else: its steps, its spend, its trace. What
    /// comes *after* it is the Backlog box's list now — this box used to repeat
    /// that queue under its own heading, where it was already on screen as the
    /// Ready items a few inches above.
    private var activeExecutionContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let currentItem = currentRunItem {
                    activeItemRow(currentItem)
                }

                if showsCostReadout {
                    costReadoutRow
                }

                // Trace spans for current item
                if !autopilot.currentItemSpans.isEmpty {
                    traceView
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// Index in `runQueue` of the item in flight — the pivot the left column
    /// splits on: this box shows that item, the merged list above shows what
    /// follows it. Nil when nothing is running, which also means nothing is
    /// queued behind it.
    private var activeRunIndex: Int? {
        switch autopilot.status {
        case .running(let idx, _), .reviewing(let idx, _, _):
            return idx < autopilot.runQueue.count ? idx : nil
        case .paused:
            guard !autopilot.runQueue.isEmpty else { return nil }
            return min(autopilot.results.count, autopilot.runQueue.count - 1)
        case .idle:
            return nil
        }
    }

    private var currentRunItem: BacklogItem? {
        activeRunIndex.map { autopilot.runQueue[$0] }
    }

    /// What sits beside the item in flight: a pause mark while the run is
    /// held, a spinner while it is working on it.
    enum ActiveRunMark: Equatable {
        case paused
        case working
    }

    static func activeRunMark(for status: BacklogAutopilot.Status) -> ActiveRunMark {
        if case .paused = status { return .paused }
        return .working
    }

    private func activeItemRow(_ item: BacklogItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                switch Self.activeRunMark(for: autopilot.status) {
                case .paused:
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                case .working:
                    ProgressView()
                        .controlSize(.mini)
                }
                // The item in flight is the one a reader most wants to know more
                // about, and it was the only row in this panel that named an item
                // without opening it. The spinner beside it is not part of the
                // link: it is status, not the item.
                ItemLink(item.id, in: linkProject) {
                    HStack(spacing: 6) {
                        itemIDLabel(item.id, size: 10)
                        if let title = AutopilotQueueList.rowTitle(for: item) {
                            Text(title)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(2)
                        }
                    }
                }
                Spacer()
            }
            if let rail = phaseRail {
                PhaseRailView(rail: rail)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.blue.opacity(0.04))
    }

    /// Where this run is right now — the same derivation the fleet board's
    /// state cell draws, so the two can't disagree.
    private var phaseRail: PortfolioSnapshot.RunState.PhaseRail? {
        PortfolioSnapshot.phaseRail(
            currentRunPhase: autopilot.currentRunPhase, attempt: autopilot.currentRunAttempt,
            lastActivityAt: autopilot.lastActivityAt, stallTimeoutMinutes: autopilot.stallTimeoutMinutes)
    }

    /// Money is worth showing while a run is live, and still worth showing once
    /// it's over — a finished session's total is what tells you whether the caps
    /// need moving before the next one.
    private var showsCostReadout: Bool {
        !isIdle || autopilot.costReadout.sessionSpendUSD > 0
    }

    /// What the run has spent, against the ceilings that will actually stop it.
    /// The item figure is measured against its *effective* cap —
    /// this project's p95 run cost plus half again, never below the item's
    /// prediction — a number nobody typed, and the reason a run can end on one. Spend is sampled every ~16s, so it trails the
    /// live turn slightly.
    private var costReadoutRow: some View {
        let readout = autopilot.costReadout
        return HStack(spacing: 14) {
            costFigure(
                label: "Item",
                text: readout.itemText,
                isNearCap: readout.isItemNearCap,
                identifier: "autopilot-cost-readout-item"
            )
            costFigure(
                label: "Session",
                text: readout.sessionText,
                isNearCap: readout.isSessionNearCap,
                identifier: "autopilot-cost-readout-session"
            )
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("autopilot-cost-readout")
        .help("Spend so far. Item is measured against its effective cap — this project's p95 run cost plus half again, never below the item's predicted cost — and the session against the budget; a figure with no cap after it is uncapped. Turns orange past 80% of a cap, which is the point to raise it if the work is legitimate.")
    }

    /// Whether the money is buying anything: the cost of a delivered item, and
    /// the share of spend that produced nothing — for this run and for today.
    ///
    /// It sits with the caps and the spend readout because that is where someone
    /// already looks to decide whether a run is behaving, and the caps alone
    /// can't answer it: they bound one item's spend and say nothing about
    /// whether the spending is producing anything. Pinned under the box header
    /// rather than inside the scrolling content — it is read mid-run, and the
    /// trace below scrolls away from it.
    ///
    /// Always on screen, idle or not: a window with nothing in it says so (see
    /// `RunEconomics.text`) rather than rendering zeroes that would read as
    /// "nothing wasted". Both figures come from records already on disk plus the
    /// backlog's current statuses, so showing them costs nothing — and they are
    /// recomputed each time the panel draws, which is how work that ships after
    /// its run ended stops being counted as waste.
    private var economicsRow: some View {
        let windows = autopilot.economics
        return VStack(alignment: .leading, spacing: 2) {
            economicsLine("Run", windows.run, identifier: "autopilot-economics-run")
            economicsLine("Today", windows.today, identifier: "autopilot-economics-today")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("autopilot-economics")
    }

    private func economicsLine(_ label: String, _ economics: RunEconomics, identifier: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 34, alignment: .leading)
            Text(economics.text)
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(economics.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                .lineLimit(1)
            Spacer()
        }
        .accessibilityIdentifier(identifier)
        .help(economics.detail)
    }

    private func costFigure(label: String, text: String, isNearCap: Bool, identifier: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(isNearCap ? Color.orange : Color.secondary)
        }
        .accessibilityIdentifier(identifier)
    }

    /// Cap on rendered spans. `currentItemSpans` grows one entry per step and is
    /// only cleared between items, so a long-running item accumulates hundreds.
    /// This is an eager `VStack` nested inside the enclosing lazy scroll list, so
    /// every append made SwiftUI re-apply *every* node and resolve per-child
    /// explicit alignment — layout cost grew with the run until the main thread
    /// pegged at 100% and the app stopped responding (diagnosed from a spin
    /// sample: `LazyStack.place` → `ForEachList.applyNodes`, with
    /// `explicitAlignment` the single hottest frame). Bounding what's rendered
    /// keeps layout flat; the model stays complete for metrics.
    private static let maxVisibleSpans = 40

    /// Per-record cap in the history list — see the comment at its `ForEach`.
    private static let maxVisibleHistoryItems = 8

    private var traceView: some View {
        let spans = autopilot.currentItemSpans
        let hiddenCount = max(0, spans.count - Self.maxVisibleSpans)
        let visibleSpans = Array(spans.suffix(Self.maxVisibleSpans))
        let lastID = spans.last?.id

        return VStack(alignment: .leading, spacing: 0) {
            if hiddenCount > 0 {
                Text("+\(hiddenCount) earlier step\(hiddenCount == 1 ? "" : "s")")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 2)
            }
            ForEach(visibleSpans, id: \.id) { span in
                spanRow(span, isLast: span.id == lastID)
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .padding(.vertical, 4)
    }

    private func spanRow(_ span: BacklogAutopilot.ExecutionSpan, isLast: Bool) -> some View {
        HStack(spacing: 6) {
            // Tree connector
            VStack(spacing: 0) {
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: 1, height: 8)
                Circle()
                    .fill(spanColor(span))
                    .frame(width: 6, height: 6)
                if !isLast {
                    Rectangle()
                        .fill(.quaternary)
                        .frame(width: 1, height: 8)
                } else {
                    Spacer().frame(height: 8)
                }
            }
            .frame(width: 6)

            // Node label
            Text(span.nodeID.capitalized)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(span.isRunning ? .primary : .secondary)
                .frame(width: 52, alignment: .leading)

            // Agent name
            Text(span.agentName)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            Spacer()

            // Duration
            if span.isRunning {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.6)
            }
            Text(formatDuration(span.duration))
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(span.isRunning ? .blue : .gray)

            // Outcome icon
            if let outcome = span.outcome {
                switch outcome {
                case .success:
                    Image(systemName: "checkmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.green)
                case .failed:
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.red)
                case .running:
                    EmptyView()
                }
            }
        }
        .frame(height: 22)
    }

    private func spanColor(_ span: BacklogAutopilot.ExecutionSpan) -> Color {
        if span.isRunning { return .blue }
        switch span.outcome {
        case .success: return .green
        case .failed: return .red
        default: return .gray
        }
    }

    // MARK: - Human approval gate

    /// Items parked at the human gate, read from the backlog file rather than
    /// from the run that put them there.
    ///
    /// The existing Approve/Reject buttons live on a banner driven by a live
    /// workflow execution, and run records do not survive a restart — so after
    /// one, an item sat here visibly unresolvable with nothing on screen saying
    /// why. Item status is the durable fact, so this reads that.
    private var gatedItems: [BacklogItem] {
        (backlogViewModel.backlogFile?.sections.flatMap(\.items) ?? [])
            .filter { $0.status == .awaitingApproval }
    }

    /// Opens what QA saw for a gated item — only when its QA run kept a
    /// storyboard; an item that went through no QA gets no button.
    private func storyboardButton(for item: BacklogItem) -> some View {
        storyboardPages[item.id].map { page in
            Button("Storyboard") { shownStoryboard = ShownStoryboard(id: item.id, title: item.title, page: page) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("The screenshots QA judged, one per step")
                .accessibilityIdentifier("autopilot-gate-storyboard-button")
        }
    }

    private func findStoryboards(for ids: [String]) async {
        storyboardPages = await Task.detached {
            Dictionary(ids.compactMap { id in QAStoryboardPage.latest(itemID: id).map { (id, $0) } },
                       uniquingKeysWith: { first, _ in first })
        }.value
    }

    private struct ShownStoryboard: Identifiable {
        let id: String
        let title: String
        let page: URL
    }

    /// A line under a gated item saying what the last attempt at resolving it
    /// did — and, when that was a refusal, everything needed to act on it
    /// without leaving the panel.
    private struct GateNote {
        let text: String
        /// Green when the gate resolved, orange when the item is still sitting
        /// there.
        let resolved: Bool
        /// Set only on a refusal: the item is still at the gate, and this is
        /// what a rejection would hand the next run.
        var refusal: Refusal?

        struct Refusal {
            let reason: String
            /// What the failing verify printed. Nil for a refusal that never ran
            /// one — a dirty tree, a merge conflict.
            let verifyOutput: String?
        }
    }

    @ViewBuilder
    private var approvalGate: some View {
        if !gatedItems.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("Waiting for you", systemImage: "hand.raised.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.blue)
                ForEach(gatedItems, id: \.id) { item in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).font(.system(size: 11)).lineLimit(1)
                            // Name the branch being approved: approving is a
                            // judgement about a change, and it was being asked
                            // for with the change nowhere on screen.
                            Text(WorktreeSession.branchName(for: item.id))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Reject") { resolveGate(item, approve: false) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(resolvingGateFor != nil)
                        storyboardButton(for: item)
                        Button(gateNotes[item.id]?.refusal == nil ? "Approve" : "Retry") {
                            resolveGate(item, approve: true)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(resolvingGateFor != nil)
                    }
                    if let note = gateNotes[item.id] {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(note.text)
                                .font(.system(size: 9))
                                .foregroundStyle(note.resolved ? .green : .orange)
                                .fixedSize(horizontal: false, vertical: true)
                            if let refusal = note.refusal {
                                refusalActions(for: item, refusal: refusal)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(8)
            .background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
            .task(id: gatedItems.map(\.id)) { await findStoryboards(for: gatedItems.map(\.id)) }
            .sheet(item: $shownStoryboard) { QAStoryboardSheet(title: $0.title, pageURL: $0.page) }
        }
    }

    /// The two ways out of a refusal that don't involve a terminal: read what
    /// failed, or send the item back carrying that failure.
    @ViewBuilder
    private func refusalActions(for item: BacklogItem, refusal: GateNote.Refusal) -> some View {
        HStack(spacing: 10) {
            if let output = refusal.verifyOutput, !output.isEmpty {
                Button("Show output") {
                    showingRefusalOutputFor = showingRefusalOutputFor == item.id ? nil : item.id
                }
                .buttonStyle(.link)
                .font(.system(size: 9))
                .popover(isPresented: Binding(
                    get: { showingRefusalOutputFor == item.id },
                    set: { showingRefusalOutputFor = $0 ? item.id : nil }
                ), arrowEdge: .bottom) {
                    refusalOutputPopover(item: item, reason: refusal.reason, output: output)
                }
            }
            Button("Reject with this failure") {
                resolveGate(item, approve: false, reason: GateRefusalEvidence.feedback(
                    reason: refusal.reason, verifyOutput: refusal.verifyOutput))
            }
            .buttonStyle(.link)
            .font(.system(size: 9))
            .disabled(resolvingGateFor != nil)
            .help("Return the item to Ready with this failure as the feedback the next run reads")
        }
    }

    private func refusalOutputPopover(item: BacklogItem, reason: String, output: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(reason).font(.system(size: 11, weight: .semibold))
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(output, forType: .string)
                }
                .controlSize(.small)
            }
            Text(item.title)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Divider()
            ScrollView {
                Text(output)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .frame(width: 560, height: 380)
    }

    private func resolveGate(_ item: BacklogItem, approve: Bool, reason: String? = nil) {
        // Without a project root there is no repository to merge against; say so
        // rather than resolving the gate on a merge that could not be attempted.
        guard let root = autopilot.projectRoot else {
            gateNotes[item.id] = GateNote(text: "No project root — cannot merge from here",
                                          resolved: false)
            return
        }
        // Drop the previous attempt's note before this one starts: a refusal
        // describes a condition ("working tree not clean: …") that the operator
        // has probably just fixed, and leaving it up through the retry makes a
        // resolved problem look like a live one.
        gateNotes[item.id] = nil
        showingRefusalOutputFor = nil
        resolvingGateFor = item.id
        // Both, not either: the project's command is an addition to the item's
        // own verify, never a substitute for it — see `MergeVerifyPlan`.
        let plan = MergeVerifyPlan.resolve(projectCommand: autopilot.autoMergeVerifyCommand,
                                           itemVerify: item.verify)
        Task {
            let outcome = await backlogViewModel.resolveGate(
                itemID: item.id,
                approve: approve,
                reason: approve ? "" : (reason ?? "Rejected from the Autopilot panel"),
                autoMerge: autopilot.autoMergeOnApproval,
                verify: plan,
                projectRoot: root,
                isolationExpected: autopilot.useWorktree,
                base: autopilot.baseBranch,
                setupCommand: autopilot.worktreeSetupCommand)
            // A failed merge is the one outcome the operator must not miss: the
            // item is still at the gate and nothing shipped.
            switch outcome {
            case .approvedAndMerged:
                // Naming the gate here too: "merged" says the work landed, not
                // what was run before it did — and an empty plan means nothing was.
                gateNotes[item.id] = GateNote(
                    text: "Merged and marked done — verified by \(plan.summary)", resolved: true)
            case .approvedWithoutMerge(let n):
                gateNotes[item.id] = GateNote(text: "Done — \(n)", resolved: true)
            case .mergeFailed(let why, let output):
                gateNotes[item.id] = GateNote(
                    text: "Not approved — \(why)",
                    resolved: false,
                    refusal: GateNote.Refusal(reason: why, verifyOutput: output))
            case .workNotOnBranch(let why):
                // No verify output to offer: nothing was merged and nothing ran
                // — the refusal is about where the work is, not about a check.
                gateNotes[item.id] = GateNote(
                    text: "Not approved — \(why)",
                    resolved: false,
                    refusal: GateNote.Refusal(reason: why, verifyOutput: nil))
            case .rejected:
                gateNotes[item.id] = nil
            }
            resolvingGateFor = nil
        }
    }

    /// An item the run in flight has already finished. It sits in the same box
    /// as the recorded history rows and names an item the same way, so it opens
    /// the same page — a run's own results are the first place anyone looks when
    /// one of them goes red.
    private func resultRow(_ result: BacklogAutopilot.ItemResult) -> some View {
        HStack(spacing: 6) {
            switch result.outcome {
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.green)
            case .awaitingApproval:
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.blue)
            // At the same gate as the row above, so the same raised hand — but
            // hollow, because there is no diff behind this one: the worker says
            // the item was already built and nothing has checked that. The row
            // opens the item, where the claim and its evidence are written.
            // And the same hollow hand for a refuted premise: at the gate, no
            // diff behind it, a report in the item's Notes for a person to read.
            case .alreadyImplemented, .investigation:
                Image(systemName: "hand.raised")
                    .font(.system(size: 9))
                    .foregroundStyle(.blue)
            case .blocked:
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.red)
            case .cancelled:
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            // Parked, not failed: the account's usage limit stopped it, and it
            // goes again when the limit lifts — hence the clock.
            case .usageLimitParked(let until):
                Image(systemName: "clock.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .help("Usage limit — resumes \(UsageLimitStop(resetsAt: until, window: nil, resetReported: true).resumeText(now: Date()))")
            }
            Text(result.title)
                .font(.system(size: 10))
                .lineLimit(1)
                .foregroundStyle(.secondary)
            Spacer()
            branchChip(autopilot.branchLink(for: result.branch))
            qualityBadge(result.qualityScore.map(BacklogAutopilot.QualityBadge.init(score:)),
                         unavailable: result.judgeUnavailable)
            Text(formatDuration(result.duration))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .openItemOnTap(result.id, enabled: canOpenDetail(result.id), open: openDetail)
        .accessibilityIdentifier("autopilot-result-item-\(result.id)")
        .help(canOpenDetail(result.id)
              ? "Open \(result.id) — its runs, this one's reason, and what git says about it now"
              : detailUnavailableHelp(result.id))
    }

    // MARK: History

    private var historyContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // Current run's completed results (shown while run is active)
                if !autopilot.results.isEmpty && !isIdle {
                    ForEach(autopilot.results) { result in
                        resultRow(result)
                    }
                }
                // Past run records
                ForEach(autopilot.runHistory.prefix(15)) { record in
                    runRecordRow(record)
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// An item that passed review and is parked for approval counts as a
    /// success in run history — the agent's work is done, the human's isn't.
    private func historyIcon(for outcome: String) -> String {
        switch outcome {
        case "done": return "checkmark.circle.fill"
        case "awaiting-approval": return "hand.raised.fill"
        default: return "xmark.circle.fill"
        }
    }

    private func historyColor(for outcome: String) -> Color {
        switch outcome {
        case "done": return .green
        case "awaiting-approval": return .blue
        default: return .red
        }
    }

    /// One past run, collapsed to a line — and, for the records that hold a
    /// single item, that item named and reachable.
    ///
    /// The row used to read "N items", which for nearly every record is "1
    /// items": the scheduler and the headless harness start one item per run, so
    /// History was a wall of rows that named nothing and led nowhere. A lone
    /// item's row now carries its title and opens its page on click, with the
    /// chevron left to the run-level detail; a record holding several keeps
    /// today's expand-on-click and names its first item plus the rest.
    private func runRecordRow(_ record: BacklogAutopilot.RunRecord) -> some View {
        let isExpanded = expandedExecutionID == record.id
        let label = AutopilotHistorySummary.recordLabel(for: record.items)
        // A record outlives the item it names, and so does the page's evidence:
        // when the sole item can no longer be opened the row falls back to
        // expanding, which is better than a click that does nothing at all.
        let opensItem = label.opensItem.flatMap { canOpenDetail($0) ? $0 : nil }

        return VStack(alignment: .leading, spacing: 0) {
            if let opensItem {
                HStack(spacing: 6) {
                    Button {
                        toggleRunRecordExpansion(record.id, isExpanded: isExpanded)
                    } label: {
                        runRecordChevron(isExpanded: isExpanded)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "Hide this run's detail" : "Show this run's detail")
                    .accessibilityIdentifier("autopilot-history-record-chevron-\(record.id)")

                    // A gesture rather than a Button, for the reason the item
                    // rows below give: the summary carries a quality badge, and
                    // controls inside a control stop answering.
                    runRecordSummary(record, label: label)
                        .contentShape(Rectangle())
                        .openItemOnTap(opensItem, enabled: true, open: openDetail)
                        .help("Open \(opensItem) — its runs, this one's reason, and what git says about it now")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .accessibilityIdentifier("autopilot-history-record-\(record.id)")
            } else {
                Button {
                    toggleRunRecordExpansion(record.id, isExpanded: isExpanded)
                } label: {
                    HStack(spacing: 6) {
                        runRecordChevron(isExpanded: isExpanded)
                        runRecordSummary(record, label: label)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("autopilot-history-record-\(record.id)")
                .help(label.opensItem.map(detailUnavailableHelp)
                      ?? (isExpanded ? "Hide this run's detail" : "Show this run's detail"))
            }

            if isExpanded {
                runRecordDetail(record)
            }
        }
    }

    private func toggleRunRecordExpansion(_ recordID: String, isExpanded: Bool) {
        withAnimation(.easeInOut(duration: 0.15)) {
            expandedExecutionID = isExpanded ? nil : recordID
        }
    }

    private func runRecordChevron(isExpanded: Bool) -> some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .frame(width: 8)
    }

    private func runRecordSummary(_ record: BacklogAutopilot.RunRecord,
                                  label: AutopilotHistorySummary.RecordLabel) -> some View {
        let passed = record.items.filter { AutopilotHistorySummary.isPass($0.outcome) }.count

        return HStack(spacing: 6) {
            runOutcomeBadge(passed: passed, failed: record.items.count - passed)

            Text(label.text)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.secondary)

            qualityBadge(record.qualityBadge, unavailable: record.judgeUnavailable,
                         isAggregate: true)

            Spacer(minLength: 4)

            Text(record.startedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)

            Text(formatDuration(record.items.reduce(0) { $0 + $1.duration }))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    private func runRecordDetail(_ record: BacklogAutopilot.RunRecord) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text("W:")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                Text(record.workerAgentName)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text("R:")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
                Text(record.reviewerAgentName)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 2)

            // Third list capped for the same reason as the span trace and the
            // transcripts, and the worst of the three: this is an *eager* stack
            // (StackLayout.placeChildren dominated the capture), 15 records deep,
            // re-laid out on every update from a live run. A marathon's records
            // carry 8–11 items each, so history alone was placing dozens of rows
            // per frame while the run streamed.
            ForEach(record.items.prefix(Self.maxVisibleHistoryItems)) { item in
                historyItemRow(item)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 4)
        .background(Color.gray.opacity(0.03))
    }

    /// One finished item inside a run record — and the click that was missing.
    ///
    /// The row was display-only: an item could go red here, and the sentence
    /// saying why was in `~/.kiteloop/control-runs.jsonl` with nothing in the app
    /// pointing at it. Now the whole line opens that item's page, where the run
    /// and its recorded reason are a row in the Runs section. Failed rows most of
    /// all — they are the ones anybody clicks.
    private func historyItemRow(_ item: BacklogAutopilot.RunRecord.ItemRecord) -> some View {
        HStack(spacing: 5) {
            Image(systemName: historyIcon(for: item.outcome))
                .font(.system(size: 8))
                .foregroundStyle(historyColor(for: item.outcome))
            Text(item.title)
                .font(.system(size: 10))
                .lineLimit(1)
            Spacer()
            branchChip(autopilot.branchLink(for: item.branch))
            qualityBadge(item.qualityScore.map(BacklogAutopilot.QualityBadge.init(score:)),
                         unavailable: item.judgeUnavailable)
            Text(formatDuration(item.duration))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        // A gesture on the row rather than a Button around it: the row already
        // carries a branch menu, and wrapping controls in a control is how the
        // inner one stops answering clicks.
        .contentShape(Rectangle())
        .openItemOnTap(item.id, enabled: canOpenDetail(item.id), open: openDetail)
        .accessibilityIdentifier("autopilot-history-item-\(item.id)")
        .help(canOpenDetail(item.id)
              ? "Open \(item.id) — its runs, this one's reason, and what git says about it now"
              : detailUnavailableHelp(item.id))
    }

    private func runOutcomeBadge(passed: Int, failed: Int) -> some View {
        let allPassed = failed == 0
        return HStack(spacing: 3) {
            Circle()
                .fill(allPassed ? .green : .orange)
                .frame(width: 5, height: 5)
            Text(allPassed ? "\(passed) passed" : "\(passed)/\(passed + failed)")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill((allPassed ? Color.green : Color.orange).opacity(0.1)))
    }

    /// Where an item's work actually went: the branch an isolated run committed
    /// to, with the ways of getting to it behind a menu. Items that ran in the
    /// live tree — or whose branch was dropped for having no changes — render
    /// nothing, so a chip always names a ref that exists.
    ///
    /// Opening is deliberately read-only: the actions hand you the branch or the
    /// worktree, and never check anything out. A click that moved the user's HEAD
    /// out from under a running autopilot would be a poor trade for a shortcut.
    @ViewBuilder
    private func branchChip(_ link: BacklogAutopilot.BranchLink?) -> some View {
        if let link {
            Menu {
                Button("Copy Branch Name") { copyToPasteboard(link.branch) }
                Button("Copy Checkout Command") { copyToPasteboard("git checkout \(link.branch)") }
                if let path = link.worktreePath {
                    Divider()
                    Button("Reveal Worktree in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([path])
                    }
                }
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                    Text(link.shortName)
                        .font(.system(size: 9))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.gray.opacity(0.12)))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityIdentifier("autopilot-branch-chip")
            .help(link.worktreePath == nil
                  ? "Branch \(link.branch) — the worktree is gone; check the branch out to see the work."
                  : "Branch \(link.branch) — its worktree is still on disk for inspection.")
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The judge's score on a run row. Deliberately small and unlabelled beyond
    /// the "Q": it's advisory — nothing was gated on it — so it sits beside the
    /// outcome rather than competing with it. Unscored items render nothing at
    /// all, since an absent score is not a zero.
    ///
    /// Except when the judge was asked and failed: that row gets a grey `Q –`
    /// saying so. "Not scored" and "scored 02" are different statements about a
    /// diff and a reader acts differently on each, so the one the judge never
    /// looked at must not simply look like a row where the judge is off.
    @ViewBuilder
    private func qualityBadge(_ badge: BacklogAutopilot.QualityBadge?,
                              unavailable: RunQualityJudge.Unavailability? = nil,
                              isAggregate: Bool = false) -> some View {
        if let badge {
            HStack(spacing: 2) {
                Text("Q")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
                Text(badge.text)
                    .font(.system(size: 9, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(qualityColor(badge.band))
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Capsule().fill(qualityColor(badge.band).opacity(0.1)))
            .accessibilityIdentifier("autopilot-quality-badge")
            .help(isAggregate
                  ? "Average quality score across this run's judged items (0–100). Advisory — the judge scores work after the fact and never blocks it."
                  : "Quality score from the independent judge (0–100), scored against the reviewer rubric. Advisory — it never changed this item's outcome.")
        } else if let unavailable, unavailable.isFailure {
            HStack(spacing: 2) {
                Text("Q")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
                Text("–")
                    .font(.system(size: 9, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.gray.opacity(0.12)))
            .accessibilityIdentifier("autopilot-quality-unscored")
            .help("Not scored — \(unavailable.explanation). Nothing about this work was assessed, which is not the same as a low score.")
        }
    }

    private func qualityColor(_ band: BacklogAutopilot.QualityBadge.Band) -> Color {
        switch band {
        case .good: return .green
        case .fair: return .orange
        case .poor: return .red
        }
    }

    private var logList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(autopilot.log.suffix(20)) { entry in
                    HStack(alignment: .top, spacing: 6) {
                        Text(entry.timestamp, format: .dateTime.hour().minute().second())
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Text(entry.message)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                }
            }
            .padding(.vertical, 6)
        }
    }


    // MARK: - Right: Transcript

    /// One transcript at the column's full height, with a tab for each agent.
    /// Only one of the two works at a time, so two stacked panes always gave
    /// half the column to the one that was idle. The pane follows the stage
    /// that is running unless the person picked a tab during this run
    /// (`AutopilotTranscriptTabs`).
    private var transcriptPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            transcriptPaneHeader
            switch transcriptTabs.shown {
            case .worker:
                AutopilotTranscriptView(messages: workerMessages, hasAgent: !workerSelection.isEmpty)
            case .reviewer:
                AutopilotTranscriptView(messages: reviewerMessages, hasAgent: !reviewerSelection.isEmpty)
            }
        }
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("autopilot-transcript-pane")
        .onChange(of: autopilot.currentItemSpans.count) {
            if let node = autopilot.currentItemSpans.last?.nodeID { transcriptTabs.enter(node: node) }
        }
        .onChange(of: autopilot.status == .idle) { _, idle in
            if idle { transcriptTabs.endRun() } else { transcriptTabs.startRun() }
        }
    }

    private var transcriptPaneHeader: some View {
        HStack(spacing: 4) {
            transcriptTabButton(.worker, title: "Worker")
            transcriptTabButton(.reviewer, title: "Reviewer")
            Spacer()
            let showsWorker = transcriptTabs.shown == .worker
            Image(systemName: showsWorker ? "hammer" : "magnifyingglass")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text((showsWorker ? workerAgentName : reviewerAgentName).uppercased())
                .font(.system(.caption2, weight: .semibold))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .accessibilityIdentifier("autopilot-transcript-agent")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
    }

    private func transcriptTabButton(_ tab: AutopilotTranscriptTab, title: String) -> some View {
        let isShown = transcriptTabs.shown == tab
        let hasUnseen = transcriptTabs.unseen.contains(tab)
        return Button {
            transcriptTabs.pick(tab, duringRun: autopilot.status != .idle)
        } label: {
            transcriptTabLabel(title, isShown: isShown, hasUnseen: hasUnseen)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isShown ? .primary : .secondary)
        .accessibilityIdentifier("autopilot-transcript-tab-\(tab.rawValue)")
        .accessibilityAddTraits(isShown ? .isSelected : [])
        .accessibilityValue(transcriptTabValue(isShown: isShown, hasUnseen: hasUnseen))
        .help(hasUnseen ? "\(title) — new output since you last looked" : title)
    }

    private func transcriptTabLabel(_ title: String, isShown: Bool, hasUnseen: Bool) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(.caption, weight: isShown ? .semibold : .regular))
            if hasUnseen {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(isShown ? Color.primary.opacity(0.1) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
    }

    /// What the tab reads to accessibility, and what the QA flow asserts:
    /// `shown` or `hidden`, then `new output` while it carries a dot.
    private func transcriptTabValue(isShown: Bool, hasUnseen: Bool) -> String {
        let state = isShown ? "shown" : "hidden"
        return hasUnseen ? "\(state), new output" : state
    }

    // MARK: - Shared Components

    private func boxHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(title.uppercased())
                .font(.system(.caption2, weight: .semibold))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    /// One heading for both kinds of group. The run-order group carries a count
    /// because its length is the thing you want to know mid-run; a backlog
    /// section is just a place items came from.
    private func listGroupHeader(_ group: AutopilotQueueList.Group) -> some View {
        HStack(spacing: 4) {
            Text(group.title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.quaternary)
            if group.isRunOrder {
                Text("(\(group.rows.count))")
                    .font(.system(size: 9))
                    .foregroundStyle(.quaternary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private func itemRow(_ row: AutopilotQueueList.Row) -> some View {
        switch row.state {
        case .queued(let position):
            queuedItemRow(row.item, position: position)
        case .selectable(let isSelected):
            selectableItemRow(row.item, isSelected: isSelected)
        }
    }

    /// An item the running queue already owns. Deliberately not a checkbox — the
    /// pick was made when the run started — so the glyph reads as state, and the
    /// one thing still worth doing to it is dropping it from the queue.
    private func queuedItemRow(_ item: BacklogItem, position: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.dotted")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            itemIDLabel(item.id)
            if let title = AutopilotQueueList.rowTitle(for: item) {
                Text(title)
                    .font(.system(size: 11))
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            Spacer()
            if let size = item.size {
                sizeBadge(size)
            }
            Button {
                autopilot.removeFromQueue(id: item.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Remove from the queue — the run skips it")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        // A queued row's click is not spoken for, so the whole line opens the
        // item — the menu is there for the keyboard and for consistency with the
        // selectable rows below, whose click already ticks a box.
        .openItemOnTap(item.id, enabled: canOpenDetail(item.id), open: openDetail)
        .contextMenu { openItemMenuItem(item.id) }
        .accessibilityIdentifier("autopilot-queued-item-\(item.id)")
        .help("Queued — #\(position) in this run. Click to open the item.")
    }

    private func selectableItemRow(_ item: BacklogItem, isSelected: Bool) -> some View {
        Button {
            if isSelected {
                localSelectedItems.remove(item.id)
            } else {
                localSelectedItems.insert(item.id)
            }
            autopilot.selectedItemIDs = localSelectedItems
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11))
                    .foregroundColor(isSelected ? .blue : .gray.opacity(0.3))
                itemIDLabel(item.id)
                if let title = AutopilotQueueList.rowTitle(for: item) {
                    Text(title)
                        .font(.system(size: 11))
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                if let size = item.size {
                    sizeBadge(size)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? Color.blue.opacity(0.04) : .clear)
        // Clicking this row picks the item for the next run, so the page is on
        // the menu rather than on the click: a row that both selects and
        // navigates does neither predictably.
        .contextMenu { openItemMenuItem(item.id) }
        .accessibilityIdentifier("autopilot-item-\(item.id)")
    }

    /// The id a console row leads with — see `AutopilotQueueList.rowTitle(for:)`
    /// for why the id goes first and the title second.
    ///
    /// It outranks the title in layout, so a narrow row spends its width on the
    /// part that identifies the item and the title is what gives way. Middle
    /// truncation is the fallback for an id long enough to fill the row on its
    /// own, where both ends still say more than the head alone.
    /// Fixed width rather than `layoutPriority`. Priority is what it looks like
    /// it wants — "give the id its width before the title" — but a differing
    /// priority inside a row forces SwiftUI to size that stack in multiple
    /// passes, per row, on every update. It was the only `layoutPriority` in the
    /// app and `StackLayout.prioritize` took 196 samples of the spin capture
    /// (~/.kiteloop/diagnostics/hang-20260806-161643). A fixed width gets the
    /// same guarantee for one pass — and aligns the titles, which the ragged
    /// left edge of the first version did not.
    private func itemIDLabel(_ id: String, size: CGFloat = 9) -> some View {
        Text(id)
            .font(.system(size: size, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(width: 118, alignment: .leading)
    }

    private func sizeBadge(_ size: ItemSize) -> some View {
        Text(size.rawValue)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(size.isTooLargeForAutopilot ? .orange : .secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(size.isTooLargeForAutopilot ? Color.orange.opacity(0.1) : Color.gray.opacity(0.1))
            )
    }

    /// Selects everything the list is offering. Items a run already holds are not
    /// offered, so "All" no longer re-ticks rows that have no checkbox on screen.
    private func selectAllQueueItems() {
        localSelectedItems = pickableItemIDs
        autopilot.selectedItemIDs = localSelectedItems
    }

    // MARK: - Item page

    /// How this panel names its project to the app-level open-item action. The
    /// autopilot is per-project, so every item this panel mentions is in the
    /// project it is driving.
    private var linkProject: ItemLinkProject {
        .path(autopilot.projectRoot?.path(percentEncoded: false) ?? "")
    }

    /// Whether this panel can open the page for an item.
    ///
    /// Both stores have to be attached — the page reads its runs from them — and
    /// the item has to still be in the backlog file: a history row outlives the
    /// item it names, and a page about an item that has been removed could show
    /// its runs and none of the definition it promises. The row is disabled and
    /// says which of the two is missing, rather than opening a half-page.
    private func canOpenDetail(_ itemID: String) -> Bool {
        metricIndex != nil && metricStore != nil && backlogViewModel.item(withID: itemID) != nil
    }

    private func detailUnavailableHelp(_ itemID: String) -> String {
        backlogViewModel.item(withID: itemID) == nil
            ? "\(itemID) is no longer in this project's backlog, so there is no item to open."
            : "This panel has no run history attached, so there is no page to open."
    }

    /// Opens one item's page: its runs, its readiness, what git says about its
    /// branch right now, and the actions its state permits.
    private func openDetail(_ itemID: String) {
        guard let metricIndex, let metricStore else { return }
        detailModel = BacklogItemDetailViewModel.make(
            itemID: itemID,
            backlog: backlogViewModel,
            autopilot: autopilot,
            metricIndex: metricIndex,
            metricStore: metricStore,
            groomingLedger: groomingLedger)
    }

    /// The page as a menu entry, for the rows whose click already means
    /// something else — the queue's selection checkboxes.
    @ViewBuilder
    private func openItemMenuItem(_ itemID: String) -> some View {
        Button {
            openDetail(itemID)
        } label: {
            Label("Open Item…", systemImage: "clock.arrow.circlepath")
        }
        .disabled(!canOpenDetail(itemID))
    }

    // MARK: - Message Sync

    private func startRun() {
        workerMessages = []
        reviewerMessages = []
        lastWorkerCount = chatViewModels[workerSelection]?.messages.count ?? 0
        lastReviewerCount = chatViewModels[reviewerSelection]?.messages.count ?? 0

        autopilot.workerAgentID = workerSelection.isEmpty ? nil : workerSelection
        autopilot.reviewerAgentID = reviewerSelection.isEmpty ? nil : reviewerSelection
        autopilot.selectedItemIDs = pickableSelection
        Task { await autopilot.start() }
    }

    private func syncAgentMessages() {
        // Worker
        if !workerSelection.isEmpty, let vm = chatViewModels[workerSelection] {
            let current = vm.messages.count
            if current > lastWorkerCount {
                let new = vm.messages[lastWorkerCount..<current]
                workerMessages.append(contentsOf: new)
                lastWorkerCount = current
                transcriptTabs.output(on: .worker, sameAgent: workerSelection == reviewerSelection)
            }
        }
        // Reviewer
        if !reviewerSelection.isEmpty, let vm = chatViewModels[reviewerSelection] {
            let current = vm.messages.count
            if current > lastReviewerCount {
                let new = vm.messages[lastReviewerCount..<current]
                reviewerMessages.append(contentsOf: new)
                lastReviewerCount = current
                transcriptTabs.output(on: .reviewer, sameAgent: workerSelection == reviewerSelection)
            }
        }
    }

    // MARK: - Helpers

    private var workerAgentName: String {
        guard !workerSelection.isEmpty else { return "Worker" }
        return agents.first { $0.id == workerSelection }?.name ?? "Worker"
    }

    private var reviewerAgentName: String {
        guard !reviewerSelection.isEmpty else { return "Reviewer" }
        return agents.first { $0.id == reviewerSelection }?.name ?? "Reviewer"
    }

    private func agentName(for agentID: String) -> String {
        agents.first { $0.id == agentID }?.name ?? agentID
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        DurationPhrase.phrase(seconds)
    }
}

