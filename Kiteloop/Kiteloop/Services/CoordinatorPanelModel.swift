import Foundation
import KiteloopCore

/// What the portfolio screen's Coordinator section shows, as a value.
///
/// The Coordinator is a **portfolio**-level agent: it chooses *between* projects,
/// its ledger and budget live in `~/.kiteloop/`, and `MainWindow` runs exactly one
/// of it per window. Every control for it, though, sat inside a single project's
/// Autopilot tab — which is why `CoordinatorQueueRefill.enabled` never got a
/// switch: there was nowhere portfolio-level to put one. This is the contents of
/// that place.
///
/// Two properties are load-bearing, and each is a property of the *type* rather
/// than a rule the view is trusted to follow:
///
/// * **Reading it cannot do anything.** `make` takes plain values — no registry,
///   no autopilot, no runtime, nothing with a method on it — so there is no path
///   from rendering the panel to starting a pass or filing an item. That holds
///   with the panel's controls in it: `Controls` says which switches accept
///   input, and flipping one sets a setting. Nothing in this file can start a
///   pass, and neither can anything the panel draws from it.
/// * **Every list is bounded at construction.** Passes accumulate for as long
///   as the app runs; a section that grew with them would make the landing
///   screen more expensive the longer Kiteloop stayed open — the same defect
///   that made the autopilot panel costly to lay out. `BoundedList` caps at the
///   door and *states* what it dropped, because a truncated list that looks
///   complete is worse than a short one.
///
/// The panel is a container. Each section's behaviour belongs to its own item, so
/// a section whose input isn't wired here renders as `notAvailable` with a reason
/// — one grey line, not a blocked panel.
struct CoordinatorPanelModel: Sendable, Equatable {

    // MARK: - Section availability

    /// A section's content, or the reason there isn't any.
    ///
    /// `loading` is separate from `notAvailable` on purpose: "the ledgers are
    /// still being read" and "there are no ledgers here" look identical to a
    /// reader and mean opposite things.
    enum Availability<Content: Sendable & Equatable>: Sendable, Equatable {
        case shown(Content)
        /// The input is on its way — an aggregation running off the main actor.
        case loading
        /// Nothing to show and nothing wrong: this section's input isn't wired.
        case notAvailable(String)

        var content: Content? {
            if case .shown(let content) = self { return content }
            return nil
        }

        var unavailableReason: String? {
            if case .notAvailable(let reason) = self { return reason }
            return nil
        }
    }

    /// A list that carries its own bound and says what the bound cost.
    ///
    /// Capping at construction rather than at render means nothing downstream has
    /// to remember to do it — including a section added later by a different item.
    struct BoundedList<Element: Sendable & Equatable & Identifiable>: Sendable, Equatable {
        let items: [Element]
        /// How many the bound dropped. Named rather than silently lost.
        let omitted: Int

        init(_ all: [Element], limit: Int) {
            let limit = max(0, limit)
            self.items = Array(all.prefix(limit))
            self.omitted = max(0, all.count - limit)
        }

        var isEmpty: Bool { items.isEmpty }

        /// e.g. `+3 more`. Nil when the bound dropped nothing.
        var omittedLabel: String? {
            omitted > 0 ? "+\(omitted) more" : nil
        }
    }

    // MARK: - 1. State

    /// On or off — read first, because it changes what everything below it
    /// means.
    struct LoopState: Sendable, Equatable {
        let enabled: Bool
        /// A pass is running right now.
        let isPassing: Bool

        /// `Off` or `On`.
        var headline: String {
            enabled ? "On" : "Off"
        }

        /// The sentence under the headline. Off is a *statement*, not a fault:
        /// a loop that files backlog items unattended is not something to inherit
        /// by upgrading, so off is the shipped default and reads as deliberate.
        var detail: String {
            guard enabled else {
                return "The Planner isn't grooming. Queues that run dry stay dry until you top them up."
            }
            if isPassing { return "A pass is running now." }
            return "Drafts that clear both gates are filed into the backlog; the rest are parked as drafts."
        }
    }

    // MARK: - 3. Recent passes

    /// One look the loop took, and what came of it. A held pass is as worth
    /// seeing as a productive one: "nothing to do" and "not allowed to do it"
    /// are different states, and a loop that reported both as silence would be
    /// impossible to trust.
    struct Pass: Sendable, Equatable, Identifiable {
        enum Kind: String, Sendable {
            case filed
            /// A pass that didn't happen, and why.
            case held
            /// A pass that happened and produced nothing usable.
            case nothing
            /// A pass that worked the blocked pile rather than drafting new work.
            case triaged
            /// A pass that was ended rather than finished — it outlived its
            /// deadline, or the loop was switched off under it. Distinct from
            /// `held`, which is a pass that decided not to groom, and from
            /// `nothing`, which is one whose drafter came back empty: this one
            /// spent a pass and reached no verdict at all.
            case stalled
        }

        let id: String
        let kind: Kind
        /// The project the pass concerned, when it got as far as choosing one.
        let project: String?
        /// One line: what it did, or why it didn't.
        let summary: String
    }

    // MARK: - 4. Budget

    /// The day's ceiling and the spend against it. Exhausted means *stop*, not
    /// degrade — so this reads as a hard line, not a gauge.
    struct Budget: Sendable, Equatable {
        let spentUSD: Double
        let capUSD: Double?
        let passes: Int
        let maxPasses: Int?
        /// The budget's own phrasing for why it is spent. Nil when there's room.
        let exhaustionReason: String?

        var isExhausted: Bool { exhaustionReason != nil }

        /// The same numbers as the loop's own budget, which is where the
        /// fractions and the phrasing live. Forwarding rather than restating
        /// them keeps the panel and the sidebar footer — which reads the loop's
        /// budget directly — from drifting into two spellings of one reading.
        private var source: QueueRefill.Budget {
            QueueRefill.Budget(spentUSD: spentUSD, capUSD: capUSD,
                               passes: passes, maxPasses: maxPasses)
        }

        /// 0…1 against the cap, or nil when uncapped — there is no bar to draw
        /// for a ceiling that doesn't exist.
        var spendFraction: Double? { source.spendFraction }

        var passFraction: Double? { source.passFraction }

        /// e.g. `$1.20 of $5.00`, or `$1.20 · no cap set`.
        var spendText: String { source.spendText }

        /// e.g. `3 of 12 passes`, or `3 passes · no cap set`.
        var passText: String { source.passText }
    }

    // MARK: - 5. Projects

    /// One project as the portfolio screen already knows it, before the panel
    /// works out where it stands.
    struct ProjectInput: Sendable, Equatable {
        let id: String
        let name: String
        /// Whether a human has parked this project — never chosen while it is.
        let paused: Bool
        let goal: String?
        /// Items sitting at `ready` — the depth the loop tops up.
        let readyCount: Int
        /// Whether the project has a backlog file at all. A project with none
        /// reads as zero ready items, which would otherwise make it look like
        /// the hungriest project in the portfolio.
        let hasBacklog: Bool
        /// How much of that ready column could actually start. `.empty` is the
        /// degradation for a caller that hasn't read it — the row then judges on
        /// depth alone, exactly as it did before this existed, rather than
        /// reporting a queue as stalled on no evidence.
        let queue: QueueHealth

        init(id: String, name: String, paused: Bool,
             goal: String?, readyCount: Int, hasBacklog: Bool = true,
             queue: QueueHealth = .empty) {
            self.id = id
            self.name = name
            self.paused = paused
            self.goal = goal
            self.readyCount = readyCount
            self.hasBacklog = hasBacklog
            self.queue = queue
        }
    }

    /// A project, ranked: whether the human parked it, what it's for, how deep
    /// its queue is, and whether the loop would groom for it next.
    struct ProjectRow: Sendable, Equatable, Identifiable {
        enum Standing: String, Sendable {
            /// Never chosen — the human paused it.
            case paused
            /// No backlog file, so there is nothing to file into.
            case noBacklog
            /// Below the refill threshold: this is what the loop grooms for.
            case queueLow
            /// Deep enough by the threshold, and yet nothing in it could start.
            /// The state this row used to report as `queueHealthy` — a full queue
            /// that cannot run reads exactly like a working one if the only thing
            /// counted is how deep it is.
            case queueStalled
            case queueHealthy
        }

        let id: String
        let name: String
        let paused: Bool
        let goal: String?
        let readyCount: Int
        /// How much of that column could actually start, and what holds the rest.
        let queue: QueueHealth
        let standing: Standing
        /// The threshold this row was judged against, so the reason can quote it.
        let threshold: Int
        /// True for the single project the loop would groom for next, and only
        /// when there is one.
        let isNext: Bool

        /// The "why" beside the name.
        var reason: String {
            switch standing {
            case .paused:
                return "Paused — never chosen."
            case .noBacklog:
                return "No backlog file — nothing to groom into."
            case .queueStalled:
                return "\(queue.ready) ready, none can start\(heldClause)"
            case .queueLow:
                return "\(readyCount) ready — below the threshold of \(threshold).\(heldNote)"
            case .queueHealthy:
                return "\(readyCount) ready — at or above the threshold of \(threshold).\(heldNote)"
            }
        }

        /// Why nothing in a stalled queue can start, e.g.
        /// ` — 19 not grounded, 1 no verify: command.` Empty when the queue
        /// reports no clause at all, which leaves the sentence true rather than
        /// trailing an em dash into nothing.
        private var heldClause: String {
            queue.withheld.isEmpty ? "." : " — \(queue.reasonsPhrase)."
        }

        /// Appended to a depth verdict that is true but incomplete: the count is
        /// right and some of what it counted is going nowhere.
        private var heldNote: String {
            let held = queue.ready - queue.startable
            guard queue.ready > 0, held > 0 else { return "" }
            return " \(held) of them can't start\(heldClause)"
        }
    }

    /// What the ranking above deliberately can't know. The panel ranks by the
    /// parked switch and the queue depth, which is what a *closed*
    /// project can tell it; the loop additionally requires the project to be open
    /// with a worker and a reviewer assigned. Stated rather than glossed — a
    /// "next" that turns out not to run is worse than a qualified one.
    static let projectsFootnote =
        "The loop only grooms for an open project that has a worker and a reviewer assigned."

    // MARK: - 7. Controls

    /// What the panel's controls may do, and why not when they may not.
    ///
    /// The panel reads the loop; these are the one part of it that *writes* —
    /// and what they write are settings, never a pass. Whether a control accepts
    /// input is a judgement with rules, so it is a value here rather than a
    /// condition in a view body:
    ///
    /// * **Unconfigured is not off.** With nothing wired to the loop it cannot
    ///   run whatever its switch says, so the switch refuses input and says so
    ///   rather than accepting a choice that will do nothing.
    /// * **Scheduling needs a ceiling before it needs a switch.** Grooming is
    ///   cheap and separately capped; *running* work unattended is not, and
    ///   `GlobalConfig.dailyBudgetUSD` left nil is not a small budget — it is no
    ///   ceiling at all. So the switch that starts runs cannot be turned on
    ///   until the number that bounds them exists.
    /// * **Off is always reachable.** A kill switch you can be locked out of is
    ///   not a kill switch, so every refusal above applies to turning scheduling
    ///   *on* and never to turning it off.
    struct Controls: Sendable, Equatable {
        /// Whether the refill loop has a portfolio, a store and a runtime wired
        /// to it — `CoordinatorQueueRefill.isConfigured`.
        let refillWired: Bool
        /// Whether the run scheduler is wired into this window.
        let schedulerWired: Bool
        /// Whether the global config store — where the running ceiling lives —
        /// was handed to the panel.
        let storeWired: Bool
        /// The portfolio-wide ceiling on autonomous *running*, as stored. Nil is
        /// no ceiling.
        let runningBudgetUSD: Double?
        /// Whether autonomous scheduling is on right now.
        let schedulingEnabled: Bool
        /// Whether the grooming loop is on right now.
        var refillEnabled: Bool = false

        /// Nothing wired at all: every control is inert and says why.
        static let unwired = Controls(refillWired: false, schedulerWired: false,
                                      storeWired: false, runningBudgetUSD: nil,
                                      schedulingEnabled: false)

        /// The grooming controls — the switch and the grooming budget.
        var canGroom: Bool { refillWired }

        /// Whether the grooming switch may be turned *on*: wired, and with a
        /// ceiling to arm against — the same rule `AutonomyArming` gives the
        /// API, so the toggle and a `PUT` refuse in the same words.
        var canEnableGrooming: Bool {
            refillWired && AutonomyArming.armGrooming(dailyBudgetUSD: runningBudgetUSD) == nil
        }

        /// Already-on always accepts input, so the way out is never blocked by
        /// the rule that guards the way in — the same shape as the scheduling
        /// switch below.
        var isGroomingSwitchOperable: Bool { refillEnabled || canEnableGrooming }

        var groomingSwitchDisabledReason: String? {
            guard !isGroomingSwitchOperable, refillWired else { return nil }
            return AutonomyArming.armGrooming(dailyBudgetUSD: runningBudgetUSD)?.message
        }

        var groomingDisabledReason: String? {
            canGroom ? nil
                : "Nothing is wired to the Planner in this window, so these would have no effect."
        }

        /// The running ceiling can be set wherever the store is, including with
        /// the loop unwired — it bounds the scheduler, not the grooming loop.
        var canSetRunningBudget: Bool { storeWired }

        var runningBudgetDisabledReason: String? {
            canSetRunningBudget ? nil : "The portfolio's settings aren't wired into this window."
        }

        /// Whether scheduling may be switched **on** from where it stands.
        var canEnableScheduling: Bool { schedulerWired && runningBudgetUSD != nil }

        /// Whether the switch accepts input at all. Already-on always does, so
        /// the way out is never blocked by the rule that guards the way in.
        var isSchedulingSwitchOperable: Bool { schedulingEnabled || canEnableScheduling }

        var schedulingDisabledReason: String? {
            guard !isSchedulingSwitchOperable else { return nil }
            guard schedulerWired else {
                return "Autonomous scheduling isn't wired into this window."
            }
            // AutonomyArming's sentence, so the toggle and the API's 422 read
            // identically.
            return AutonomyArming.armScheduling(dailyBudgetUSD: runningBudgetUSD)?.message
        }
    }

    // MARK: - Bounds

    /// Enough to see a pattern (three holds in a row), not a log.
    static let passLimit = 5
    /// The landing screen already renders a card per project; this list is the
    /// loop's view of them, and a long one would just be the grid again.
    static let projectLimit = 8

    // MARK: - Fields

    let state: Availability<LoopState>
    let passes: Availability<BoundedList<Pass>>
    let budget: Availability<Budget>
    let projects: Availability<BoundedList<ProjectRow>>
    let report: Availability<PortfolioReport>
    /// Not an `Availability`: a control with nothing behind it is still drawn,
    /// disabled, saying why — a section that vanished when it was inoperable
    /// would answer "where is the switch" with silence.
    let controls: Controls

    // MARK: - Input

    /// The loop, read once and copied.
    ///
    /// A value rather than the live `CoordinatorQueueRefill` on purpose: with no
    /// method to call, there is no way for the panel — now or after some later
    /// item edits it — to start a pass by rendering.
    struct LoopSnapshot: Sendable, Equatable {
        let enabled: Bool
        let isPassing: Bool
        /// The queue depth below which the loop grooms.
        let threshold: Int
        let budget: QueueRefill.Budget
        /// Newest first.
        let passes: [Pass]

        init(enabled: Bool, isPassing: Bool,
             threshold: Int, budget: QueueRefill.Budget,
             passes: [Pass] = []) {
            self.enabled = enabled
            self.isPassing = isPassing
            self.threshold = threshold
            self.budget = budget
            self.passes = passes
        }
    }

    /// Why the report section is empty when it is. The report is aggregated off
    /// the main actor, so "not read yet" is a real state the panel passes through
    /// on every open.
    enum ReportInput: Sendable, Equatable {
        case ready(PortfolioReport)
        case reading
        /// No run/grooming ledger was handed to the panel here.
        case unavailable
    }

    // MARK: - Build

    /// Assemble the panel.
    ///
    /// Nil inputs are the degradation path, not an error: a section whose feature
    /// hasn't landed — or whose store isn't wired into this window — is one line
    /// of grey text, and the sections around it still render.
    ///
    /// - Parameters:
    ///   - loop: the refill loop, or nil when it isn't wired into this window.
    ///     Nil takes state, passes and budget with it — all three are the
    ///     loop's own facts and none can be guessed.
    ///   - projects: the portfolio as the screen knows it, or nil when it hasn't
    ///     been read here. An *empty* array is a legitimate portfolio, not a
    ///     missing one, and renders as an empty section rather than as absent.
    ///   - report: the merged ÷ filed rollup, or why there isn't one.
    ///   - controls: what the panel's switches may do. Defaults to `.unwired`,
    ///     which draws every control disabled with its reason — the same
    ///     degradation as the sections above, applied to the operable half.
    static func make(loop: LoopSnapshot?,
                     projects: [ProjectInput]?,
                     report: ReportInput,
                     controls: Controls = .unwired) -> CoordinatorPanelModel {
        let noLoop = "The refill loop isn't wired into this window."

        let state: Availability<LoopState> = loop.map {
            .shown(LoopState(enabled: $0.enabled, isPassing: $0.isPassing))
        } ?? .notAvailable(noLoop)

        let passes: Availability<BoundedList<Pass>> = loop.map {
            .shown(BoundedList($0.passes, limit: passLimit))
        } ?? .notAvailable(noLoop)

        let budget: Availability<Budget> = loop.map {
            .shown(Budget(spentUSD: $0.budget.spentUSD,
                          capUSD: $0.budget.capUSD,
                          passes: $0.budget.passes,
                          maxPasses: $0.budget.maxPasses,
                          exhaustionReason: $0.budget.exhaustionReason))
        } ?? .notAvailable(noLoop)

        // The threshold is the loop's, when there is one; the policy default
        // otherwise, so the project list still explains itself with the loop
        // unwired instead of going blank alongside it.
        let threshold = loop?.threshold ?? QueueRefill.Policy.default.sanitized.threshold
        let projectSection: Availability<BoundedList<ProjectRow>> = projects.map {
            .shown(BoundedList(rank($0, threshold: threshold), limit: projectLimit))
        } ?? .notAvailable("The portfolio hasn't been read here.")

        let reportSection: Availability<PortfolioReport>
        switch report {
        case .ready(let value): reportSection = .shown(value)
        case .reading: reportSection = .loading
        case .unavailable:
            reportSection = .notAvailable("No run or grooming ledger is wired into this window.")
        }

        return CoordinatorPanelModel(state: state, passes: passes,
                                     budget: budget, projects: projectSection,
                                     report: reportSection, controls: controls)
    }

    /// Order the portfolio the way the loop weighs it, and mark the one it would
    /// groom for next.
    ///
    /// The order is the loop's own, minus the tiebreak it can't reach from here:
    /// paused last (a paused project is never a choice), then the emptiest
    /// queue, then the name so the same portfolio always renders the same way.
    /// `QueueRefill` breaks a depth tie by idle time, which needs an open
    /// project; queue depth is the closest thing a closed one can offer, and it
    /// is the quantity the refill is *about*.
    static func rank(_ projects: [ProjectInput], threshold: Int) -> [ProjectRow] {
        let threshold = max(0, threshold)
        var rows = projects.map { project -> ProjectRow in
            let standing: ProjectRow.Standing
            if project.paused {
                standing = .paused
            } else if !project.hasBacklog {
                standing = .noBacklog
            } else if project.readyCount < threshold {
                // Depth is read before runnability on purpose: the loop tops up
                // on depth, so a shallow queue is what it would groom for next
                // whether or not the items in it can run. A row that claimed
                // otherwise would misreport what the loop does — the shortfall
                // is said in the reason instead.
                standing = .queueLow
            } else if project.queue.isStalled {
                standing = .queueStalled
            } else {
                standing = .queueHealthy
            }
            return ProjectRow(id: project.id, name: project.name, paused: project.paused,
                              goal: project.goal, readyCount: project.readyCount,
                              queue: project.queue, standing: standing,
                              threshold: threshold, isNext: false)
        }

        rows.sort { lhs, rhs in
            let (lRank, rRank) = (standingRank(lhs.standing), standingRank(rhs.standing))
            if lRank != rRank { return lRank < rRank }
            if lhs.readyCount != rhs.readyCount { return lhs.readyCount < rhs.readyCount }
            return lhs.name < rhs.name
        }

        // Exactly one "next", and only when something is actually hungry.
        guard let next = rows.firstIndex(where: { $0.standing == .queueLow }) else { return rows }
        let row = rows[next]
        rows[next] = ProjectRow(id: row.id, name: row.name, paused: row.paused,
                                goal: row.goal, readyCount: row.readyCount,
                                queue: row.queue, standing: row.standing,
                                threshold: row.threshold, isNext: true)
        return rows
    }

    /// Hungry first, then stalled, then healthy, then the two the loop will never
    /// pick. Lower sorts first.
    ///
    /// A stalled queue outranks a healthy one because it is the one that needs a
    /// human: it is deep enough that the loop will never groom for it, and empty
    /// enough that nothing will run in it either.
    private static func standingRank(_ standing: ProjectRow.Standing) -> Int {
        switch standing {
        case .queueLow: return 0
        case .queueStalled: return 1
        case .queueHealthy: return 2
        case .noBacklog: return 3
        case .paused: return 4
        }
    }
}

// MARK: - Capture

extension CoordinatorPanelModel.LoopSnapshot {

    /// Read the live loop into a value. The one place the panel touches
    /// `CoordinatorQueueRefill`, and it only reads.
    ///
    /// Returns nil when the loop has nothing wired to it — an unwired loop holds
    /// every pass, so reporting it as merely "off" would be a different and
    /// wrong claim about why nothing is happening.
    @MainActor
    static func capture(_ refill: CoordinatorQueueRefill) -> Self? {
        guard refill.isConfigured else { return nil }
        return CoordinatorPanelModel.LoopSnapshot(
            enabled: refill.enabled,
            isPassing: refill.isPassing,
            threshold: refill.policy.sanitized.threshold,
            budget: refill.budget,
            // One outcome is all the loop keeps today; the list is already the
            // shape a pass history will arrive in, so gaining one is a change to
            // what is passed here and to nothing downstream.
            passes: refill.lastOutcome.map { [CoordinatorPanelModel.Pass($0, index: 0)] } ?? []
        )
    }
}

extension CoordinatorPanelModel.Controls {

    /// Read what the controls are allowed to do out of the live objects they
    /// write to. Like `LoopSnapshot.capture` this only reads — the writing
    /// happens when someone presses something.
    @MainActor
    static func capture(refill: CoordinatorQueueRefill,
                        scheduler: CoordinatorRunScheduler?,
                        store: GlobalConfigStore?) -> Self {
        CoordinatorPanelModel.Controls(
            refillWired: refill.isConfigured,
            schedulerWired: scheduler?.isConfigured ?? false,
            storeWired: store != nil,
            runningBudgetUSD: store?.config.dailyBudgetUSD,
            schedulingEnabled: scheduler?.enabled ?? false,
            refillEnabled: refill.enabled
        )
    }
}

extension CoordinatorPanelModel.Pass {

    /// One outcome as a row. `index` only makes the id unique — outcomes carry no
    /// timestamp, and two identical holds in a row are two rows.
    init(_ outcome: CoordinatorQueueRefill.PassOutcome, index: Int) {
        let kind: Kind
        let project: String?
        switch outcome {
        case .disabled:
            kind = .held
            project = nil
        case .held:
            kind = .held
            project = nil
        case .noDrafts(let name):
            kind = .nothing
            project = name
        case .filed(let name, _, _, _):
            kind = .filed
            project = name
        case .triaged(let name, _):
            kind = .triaged
            project = name
        case .abandoned(let name, _, _, _):
            kind = .stalled
            project = name
        }
        self.init(id: "\(index)-\(outcome.summary)", kind: kind,
                  project: project, summary: outcome.summary)
    }
}
