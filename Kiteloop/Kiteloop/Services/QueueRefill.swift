import Foundation
import KiteloopCore

/// The queue-refill loop's decision half: **which** project gets more work
/// drafted for it, **how much**, and **when not to bother**.
///
/// The constraint this answers is throughput, not quality. The executor is
/// faster than the groomer — on 2026-08-06 both open queues drained inside a few
/// hours and then sat idle waiting for a human to write specs. Filling a queue
/// is judgment, but *deciding to fill one* is arithmetic, and arithmetic belongs
/// in a pure function rather than in a prompt.
///
/// Everything here is a value: no registry, no backlog, no clock of its own.
/// `CoordinatorQueueRefill` is the half that observes and writes; this half only
/// decides, so the whole selection policy — the paused hard stop, the priority
/// order, the budget refusal, the bound on how much gets filed — is exercised
/// without an app running.
enum QueueRefill {

    // MARK: - Policy

    /// How empty is empty, and how full is full enough.
    ///
    /// `targetDepth` is the point of the whole thing: a loop that grooms whenever
    /// it *can* produces infinite plausible work. Topping up to a depth and then
    /// stopping is what keeps the backlog a queue rather than a wishlist.
    struct Policy: Sendable, Equatable {
        /// Refill when a project's `ready` count is **below** this.
        var threshold: Int
        /// Fill back up to this many `ready` items, and no further.
        ///
        /// It defaults to `maxItemsPerPass` rather than above it, and that is the
        /// fix rather than a coincidence: a target of 5 over a per-pass cap of 3
        /// was unreachable by construction, so the cap was what actually decided
        /// every fill and the target described a depth no pass could deliver. A
        /// queue at zero now reaches it in one pass. Raising the cap instead
        /// would have been the other way to make the two agree, and the wrong
        /// one — three items is a reasonable ceiling on how much unreviewed work
        /// is filed at once, and starvation was never a question of how much.
        var targetDepth: Int
        /// The most items one pass may draft **for one project**, however deep
        /// the hole. A project that has never been groomed shouldn't get twenty
        /// specs in one go.
        ///
        /// It binds only above the default target: an operator who raises
        /// `targetDepth` through the control API gets a deeper queue at three
        /// items a pass rather than in one go.
        var maxItemsPerPass: Int
        /// The most projects one pass may serve.
        ///
        /// A pass used to top up exactly one, so the grooming cadence divided by
        /// however many projects there were and a project that drained faster
        /// than its turn came round sat at zero. Measured on 2026-08-12: three
        /// autopilot-ready projects on a 300-second interval, two of them idle at
        /// `ready=0`, and grooming had spent 1 of 150 passes and $3.85 of $350 —
        /// nothing capped, nothing wedged, and the queue simply could not be
        /// refilled as fast as it drained.
        var maxProjectsPerPass: Int

        init(threshold: Int = 2, targetDepth: Int = 3, maxItemsPerPass: Int = 3,
             maxProjectsPerPass: Int = 3) {
            self.threshold = threshold
            self.targetDepth = targetDepth
            self.maxItemsPerPass = maxItemsPerPass
            self.maxProjectsPerPass = maxProjectsPerPass
        }

        static let `default` = Policy()

        /// A hand-edited config can't turn the bound off: a target below the
        /// threshold, or a non-positive per-pass cap, would either never settle
        /// or never stop. A pass that served no project at all would be the same
        /// starvation the project cap exists to end, so it is held at one.
        var sanitized: Policy {
            let threshold = max(0, self.threshold)
            return Policy(threshold: threshold,
                          targetDepth: max(threshold, self.targetDepth),
                          maxItemsPerPass: max(1, self.maxItemsPerPass),
                          maxProjectsPerPass: max(1, self.maxProjectsPerPass))
        }
    }

    // MARK: - Budget

    /// What grooming is allowed to cost in a day.
    ///
    /// Exhausted means **stop**, not degrade: a coordinator that responds to an
    /// empty budget by drafting something cheaper and worse is exactly the
    /// failure a budget exists to prevent. `decide` refuses the whole pass before
    /// any model is called.
    struct Budget: Sendable, Equatable {
        /// Spent on grooming so far today.
        var spentUSD: Double
        /// The day's ceiling; nil = uncapped.
        var capUSD: Double?
        /// Passes started today.
        var passes: Int
        /// The most passes a day may run; nil = uncapped.
        var maxPasses: Int?
        /// How many of those passes were ended rather than finished — they
        /// outlived their deadline, or the loop was switched off under them.
        ///
        /// Counted **beside** `passes`, never inside it: an abandoned pass and
        /// one that filed work are both passes spent against the ceiling, and
        /// telling them apart is the whole reason this exists. `passStalled`
        /// says a pass is stuck *now* and goes back to false the moment the
        /// deadline ends one, so a night that hung repeatedly and self-healed
        /// each time read exactly like a night that never hung at all — the
        /// only record being one line in a 50-entry history nobody reads.
        var abandonedPasses: Int
        /// Any instant inside the day these counters describe. Compared by
        /// calendar day, so the counters zero themselves at the boundary rather
        /// than needing something to reset them.
        var day: Date

        init(spentUSD: Double = 0, capUSD: Double? = nil,
             passes: Int = 0, maxPasses: Int? = nil,
             abandonedPasses: Int = 0, day: Date = Date()) {
            self.spentUSD = spentUSD
            self.capUSD = capUSD
            self.passes = passes
            self.maxPasses = maxPasses
            self.abandonedPasses = abandonedPasses
            self.day = day
        }

        /// Why the *money* ceiling is spent. Nil when there is spend left.
        ///
        /// Separate from `exhaustionReason` because the two ceilings bound
        /// different things: the cost cap bounds what a day of coordinating may
        /// cost on the subscription, and `maxPasses` bounds how often the refill
        /// *loop* wakes up to groom. A spender that isn't a pass — a human
        /// asking the coordinator a question — is bound by the first and has no
        /// business being refused by the second.
        var spendExhaustionReason: String? {
            if let cap = capUSD, spentUSD >= cap {
                return String(format: "daily grooming budget spent ($%.2f of $%.2f)", spentUSD, cap)
            }
            return nil
        }

        /// Why the *pass* ceiling is used up. Nil when there are passes left.
        var passExhaustionReason: String? {
            if let maxPasses, passes >= maxPasses {
                return "daily grooming passes used (\(passes) of \(maxPasses))"
            }
            return nil
        }

        /// Why the budget is spent, phrased for the refusal record. Nil when
        /// there is budget left.
        var exhaustionReason: String? {
            spendExhaustionReason ?? passExhaustionReason
        }

        var isExhausted: Bool { exhaustionReason != nil }

        // MARK: - Reading

        /// 0…1 of the day's spend against its cap, or nil when uncapped —
        /// there is no proportion to state for a ceiling that doesn't exist,
        /// and stating one would read as a limit of zero.
        var spendFraction: Double? {
            guard let capUSD, capUSD > 0 else { return nil }
            return min(1, max(0, spentUSD / capUSD))
        }

        var passFraction: Double? {
            guard let maxPasses, maxPasses > 0 else { return nil }
            return min(1, max(0, Double(passes) / Double(maxPasses)))
        }

        /// e.g. `$1.20 of $5.00`, or `$1.20 · no cap set`.
        var spendText: String {
            guard let capUSD else { return "\(PortfolioReport.usd(spentUSD)) · no cap set" }
            return "\(PortfolioReport.usd(spentUSD)) of \(PortfolioReport.usd(capUSD))"
        }

        /// e.g. `3 of 12 passes`, or `3 passes · no cap set`.
        var passText: String {
            guard let maxPasses else { return "\(passCount) · no cap set" }
            return "\(passes) of \(maxPasses) passes"
        }

        /// e.g. `2 passes abandoned today` — the standing counterpart to
        /// `passStalled`, which only ever answers "right now".
        ///
        /// It states the number even when it is zero: a day with no abandoned
        /// pass has something to say, and a reading that simply went absent
        /// would be the same silence this counter exists to break.
        var abandonedText: String {
            "\(abandonedPasses) pass\(abandonedPasses == 1 ? "" : "es") abandoned today"
        }

        private var passCount: String { "\(passes) pass\(passes == 1 ? "" : "es")" }

        /// The ceiling nearest to stopping grooming, as one line for a surface
        /// that has room for exactly one.
        ///
        /// Three ceilings can stop autonomous work and they stop unlike things:
        /// the coordinator's `capUSD` and `maxPasses` stop *grooming*, while a
        /// project's session and per-item caps stop that project's run. Only the
        /// coordinator's two are read here, so this is never an average of unlike
        /// quantities — it names which of the two is closest and what reaching it
        /// stops. Aggregating them would imply one cliff where there are three,
        /// and the nearest is not always the same one.
        struct Ceiling: Sendable, Equatable {
            enum Kind: String, Sendable {
                /// `capUSD` — what a day of grooming may cost.
                case spend
                /// `maxPasses` — how often the loop may wake up to groom.
                case passes
                /// Neither ceiling is set, so there is nothing to be near. A
                /// state in its own right: uncapped is not a cap of zero.
                case uncapped
            }

            let kind: Kind
            /// 0…1 against this ceiling, or nil when there is no ceiling to
            /// measure against.
            let fraction: Double?
            /// The numbers, e.g. `$18.00 of $250.00` or `4 of 12 passes`.
            let text: String
            /// The budget's own phrasing for why grooming has stopped. Nil
            /// while there is room.
            let exhaustionReason: String?

            var isExhausted: Bool { exhaustionReason != nil }

            /// What reaching this ceiling stops. Both of the coordinator's
            /// ceilings stop the same thing, and saying so is the point: a
            /// reader shown only a number cannot tell whether it bounds
            /// grooming or a run.
            var stops: String { "grooming" }

            /// The one line a footer shows. Once it has stopped, the budget's
            /// own reason already carries the numbers, so it replaces the
            /// reading rather than sitting beside it.
            var summary: String {
                if let exhaustionReason { return "Stopped — \(exhaustionReason)" }
                switch kind {
                case .spend, .passes: return "\(text) · stops \(stops)"
                case .uncapped: return "\(text) · \(stops) uncapped"
                }
            }
        }

        var nearestCeiling: Ceiling {
            // An exhausted ceiling is the nearest one by definition, and which
            // one stopped grooming is not a question of proportion: a cap of $0
            // has no fraction to measure against and has still stopped it.
            if let reason = spendExhaustionReason {
                return Ceiling(kind: .spend, fraction: spendFraction ?? 1,
                               text: spendText, exhaustionReason: reason)
            }
            if let reason = passExhaustionReason {
                return Ceiling(kind: .passes, fraction: passFraction ?? 1,
                               text: passText, exhaustionReason: reason)
            }
            switch (spendFraction, passFraction) {
            // Proportionally closer wins; a tie goes to the money, which is the
            // ceiling someone reading a budget came to read.
            case let (spend?, pass?): return pass > spend ? passCeiling : spendCeiling
            case (.some, nil): return spendCeiling
            case (nil, .some): return passCeiling
            case (nil, nil):
                return Ceiling(kind: .uncapped, fraction: nil,
                               text: "\(PortfolioReport.usd(spentUSD)) · \(passCount)",
                               exhaustionReason: nil)
            }
        }

        private var spendCeiling: Ceiling {
            Ceiling(kind: .spend, fraction: spendFraction, text: spendText, exhaustionReason: nil)
        }

        private var passCeiling: Ceiling {
            Ceiling(kind: .passes, fraction: passFraction, text: passText, exhaustionReason: nil)
        }

        /// Both ceilings spelled out, for a tooltip, and what the day has lost
        /// to passes that never finished. The footer names only the nearest
        /// ceiling; the other one belongs somewhere a reader can ask for it.
        var helpText: String {
            var text = "Grooming budget \(spendText) · \(passText) · \(abandonedText)."
            if let exhaustionReason { text += " Grooming has stopped: \(exhaustionReason)." }
            return text
        }

        /// The same budget seen from `now`: unchanged within the day, zeroed
        /// across the boundary. Pure — the caller stores what it returns.
        func rolled(to now: Date, calendar: Calendar = .current) -> Budget {
            guard !calendar.isDate(day, inSameDayAs: now) else { return self }
            return Budget(spentUSD: 0, capUSD: capUSD, passes: 0, maxPasses: maxPasses,
                          abandonedPasses: 0, day: now)
        }

        /// After a pass has started and cost what it cost.
        func charged(_ costUSD: Double, at now: Date) -> Budget {
            var next = rolled(to: now)
            next.spentUSD += max(0, costUSD)
            next.passes += 1
            return next
        }

        /// After a pass that had already been charged was ended without
        /// finishing. `passes` is deliberately untouched: the pass was spent
        /// when it started, and counting it twice would make the ceiling read
        /// nearer than it is.
        ///
        /// Unlike `charged` this does **not** roll the day. An abandonment is
        /// stamped with the deadline the pass outlived, which can sit a little
        /// ahead of the clock, and rolling from an instant that hasn't arrived
        /// would zero a day's spend before the day was over. The counter rolls
        /// with `passes` and `spentUSD` when the next pass charges the day.
        func abandonedAPass() -> Budget {
            var next = self
            next.abandonedPasses += 1
            return next
        }
    }

    // MARK: - Decision

    /// The project to groom for, and how deep the hole is.
    struct Target: Sendable, Equatable {
        let project: String
        let path: String
        /// `ready` items right now.
        let readyCount: Int
        /// How many of those could actually start, when the snapshot carried the
        /// figure — nil when it didn't, in which case it equals `readyCount`.
        /// Carried separately from `readyCount` so a prompt can say when the two
        /// disagree, rather than stating a bare ready count for a queue that
        /// can't run any of it.
        let startableCount: Int?
        /// How many to draft this pass — the shortfall, capped by the policy.
        let count: Int

        init(project: String, path: String, readyCount: Int, startableCount: Int? = nil, count: Int) {
            self.project = project
            self.path = path
            self.readyCount = readyCount
            self.startableCount = startableCount
            self.count = count
        }
    }

    /// Why a pass isn't happening. Each case is a state worth seeing in the log:
    /// "nothing to do" and "not allowed to do it" are very different, and a loop
    /// that reported both as silence would be impossible to trust.
    ///
    /// `Codable` because a held pass is written to the pass ledger whole — see
    /// `CoordinatorQueueRefill.PassLedger`. A hold read back as a bare tag would
    /// lose the budget's own numbers, which is the half of it worth keeping.
    enum Hold: Sendable, Equatable, Codable {
        /// The budget said no. Carries the budget's own phrasing.
        case budgetExhausted(String)
        /// Nothing open that the coordinator may groom for — every project is
        /// paused, or has no worker/reviewer assigned, or none is open at all.
        case noEligibleProject
        /// Projects could be groomed, but none has consented to autonomous
        /// work; the loop grooms only for projects that opted in.
        case noProjectOptedIn
        /// Every eligible queue is at or above the threshold. The healthy case,
        /// and the common one.
        case queuesHealthy
        /// Grooming for one project is held: consecutive passes drafted and
        /// produced nothing runnable, so repeating the attempt would spend
        /// passes on the same refusals. A human releases it — by approving or
        /// dismissing one of the project's pending drafts, or by naming the
        /// project in a by-hand pass, which ignores the hold.
        case groomingHeld(project: String, streak: Int)

        var reason: String {
            switch self {
            case .budgetExhausted(let detail): return detail
            case .noEligibleProject: return "no eligible project — all paused, unready, or none open"
            case .noProjectOptedIn: return "no project has autonomous work switched on — opt one in "
                + "from its Autopilot settings"
            case .queuesHealthy: return "every eligible queue is above the threshold"
            case .groomingHeld(let project, let streak):
                return "\(project): grooming held — \(streak) futile passes in a row; "
                    + "approve or dismiss its drafts, or groom it by hand to resume"
            }
        }

        /// The case as a stable tag. `reason` is phrased for a human and carries
        /// the budget's own numbers; something deciding whether to alert needs a
        /// value it can compare, not a sentence it has to match.
        var kind: String {
            switch self {
            case .budgetExhausted: return "budgetExhausted"
            case .noEligibleProject: return "noEligibleProject"
            case .noProjectOptedIn: return "noProjectOptedIn"
            case .queuesHealthy: return "queuesHealthy"
            case .groomingHeld: return "groomingHeld"
            }
        }
    }

    enum Decision: Sendable, Equatable {
        case refill(Target)
        case hold(Hold)

        var target: Target? { if case .refill(let t) = self { return t } else { return nil } }
        var hold: Hold? { if case .hold(let h) = self { return h } else { return nil } }

        /// The same decision as a whole pass's worth. A caller that named one
        /// project has decided which; everything downstream is the timer's own.
        var asPass: PassDecision {
            switch self {
            case .refill(let target): return .refill([target])
            case .hold(let hold): return .hold(hold)
            }
        }
    }

    /// Every project one pass should serve, in the order it should serve them —
    /// or why it serves none.
    ///
    /// A list rather than a single target because a pass that tops up one project
    /// divides the grooming cadence by the size of the fleet: with three projects
    /// on a 300-second interval a queue's turn came round every twenty minutes,
    /// and a project that drained in ten spent the other ten at zero.
    enum PassDecision: Sendable, Equatable {
        case refill([Target])
        case hold(Hold)

        var targets: [Target] { if case .refill(let t) = self { return t } else { return [] } }
        var hold: Hold? { if case .hold(let h) = self { return h } else { return nil } }
    }

    /// Every project this pass should groom for, neediest first — or why none
    /// qualifies.
    ///
    /// Order of the gates matters and is the point:
    ///   1. **budget** — an exhausted budget stops the pass before a project is
    ///      even chosen, so nothing downstream can decide to spend "just a bit".
    ///   2. **paused** — read through `selectableProjects`, so a paused project is
    ///      not a choice that gets declined, it is one never offered.
    ///   3. **runnable** — a project without a worker and reviewer can't run what
    ///      it's given, so grooming for it fills a queue nothing draws from.
    ///   4. **below threshold** — an idle project with a full queue needs nothing.
    ///   5. **priority, then emptiest, then idle longest** — the human's stated
    ///      priority decides; when two projects are stated the same the emptier
    ///      queue is the one nearer to starving, and between two equally empty
    ///      ones the one idle longer has been waiting longer.
    ///
    /// What survives is capped at `maxProjectsPerPass`, so one pass has a bounded
    /// amount of drafting to do however wide the fleet gets — a pass is raced
    /// against a deadline it does not get to extend by serving more projects.
    ///
    /// - Parameter idleSince: when each project was last observed to have no run
    ///   in flight. A project absent from the map — or one currently running —
    ///   has been idle for no time at all.
    static func decidePass(portfolio: PortfolioSnapshot,
                           policy: Policy = .default,
                           budget: Budget = Budget(),
                           idleSince: [String: Date] = [:],
                           now: Date = Date()) -> PassDecision {
        if let reason = budget.rolled(to: now).exhaustionReason {
            return .hold(.budgetExhausted(reason))
        }

        let policy = policy.sanitized
        let capable = portfolio.selectableProjects.filter(\.autopilotReady)
        guard !capable.isEmpty else { return .hold(.noEligibleProject) }

        // Consent, after capability — the same order the run scheduler reads
        // them in. The named-project `decide(portfolio:project:)` is not gated:
        // asking for one project by name is the explicit request this loop
        // isn't.
        let eligible = capable.filter(\.autonomousWorkEnabled)
        guard !eligible.isEmpty else { return .hold(.noProjectOptedIn) }

        let hungry = eligible.filter { ($0.startable ?? $0.count(.ready)) < policy.threshold }
        guard !hungry.isEmpty else { return .hold(.queuesHealthy) }

        let targets = hungry
            .sorted { prefersForRefill($0, over: $1, idleSince: idleSince, now: now) }
            .compactMap { target(for: $0, policy: policy) }
            .prefix(policy.maxProjectsPerPass)
        guard !targets.isEmpty else { return .hold(.queuesHealthy) }

        return .refill(Array(targets))
    }

    /// The neediest project alone — what a caller wanting one target reads.
    /// Decided by `decidePass`, so "which project first" has exactly one answer
    /// whether a pass serves one project or several.
    static func decide(portfolio: PortfolioSnapshot,
                       policy: Policy = .default,
                       budget: Budget = Budget(),
                       idleSince: [String: Date] = [:],
                       now: Date = Date()) -> Decision {
        switch decidePass(portfolio: portfolio, policy: policy, budget: budget,
                          idleSince: idleSince, now: now) {
        case .hold(let hold): return .hold(hold)
        case .refill(let targets):
            guard let first = targets.first else { return .hold(.queuesHealthy) }
            return .refill(first)
        }
    }

    /// How much this project gets drafted for it: the shortfall against
    /// `targetDepth`, bounded by `maxItemsPerPass`. Nil when it needs nothing —
    /// unreachable for a project below a sanitized threshold, and kept because a
    /// target of zero items is not a target.
    ///
    /// The shortfall is measured against how many items could actually start,
    /// not the raw `ready` tally — a queue of three that nothing can pick up is
    /// as hungry as an empty one, and topping it up against the tally alone
    /// would leave it reading full while nothing in it runs.
    private static func target(for project: PortfolioSnapshot.Project, policy: Policy) -> Target? {
        let ready = project.count(.ready)
        let startable = project.startable ?? ready
        let count = min(policy.targetDepth - startable, policy.maxItemsPerPass)
        guard count > 0 else { return nil }
        return Target(project: project.name, path: project.path, readyCount: ready,
                      startableCount: project.startable, count: count)
    }

    /// The same decision for a project someone **named**, rather than the one
    /// the loop would have chosen for itself.
    ///
    /// Exactly one gate is dropped, and it is the one the caller is standing in
    /// for: "is this the hungriest project I could groom for". Every other gate
    /// holds unchanged — an exhausted budget still refuses first, a paused
    /// project is still never groomed for, a project without a worker and a
    /// reviewer is still not given work it can't run, and the pass is still
    /// bounded by `targetDepth` and `maxItemsPerPass`. A queue already at the
    /// target depth holds as `queuesHealthy`: "groom this one now" is a choice
    /// of target, not permission to draft past the depth the policy stops at.
    ///
    /// `idleSince` has no part here — it only ever broke a tie between
    /// candidates, and there is one candidate.
    static func decide(project name: String,
                       portfolio: PortfolioSnapshot,
                       policy: Policy = .default,
                       budget: Budget = Budget(),
                       now: Date = Date()) -> Decision {
        if let reason = budget.rolled(to: now).exhaustionReason {
            return .hold(.budgetExhausted(reason))
        }
        let policy = policy.sanitized
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let chosen = portfolio.selectableProjects.first(where: { $0.name == wanted }),
              chosen.autopilotReady else {
            return .hold(.noEligibleProject)
        }
        guard let target = target(for: chosen, policy: policy) else { return .hold(.queuesHealthy) }
        return .refill(target)
    }

    /// Whether `a` deserves the coordinator's attention before `b`: whichever
    /// has been waiting longer, then the name so the same portfolio always
    /// resolves the same way.
    ///
    /// Fairness is the whole ordering. With several projects running at once the
    /// idle clock is the only thing a human needs the fleet to honour, and a
    /// project the human wants left alone is parked rather than ranked last.
    ///
    /// Shared with `RunScheduling` deliberately. Grooming for a project and
    /// starting a run in one are the same question — which project matters most
    /// right now — and two copies of the answer would drift apart the first time
    /// either was tuned.
    static func prefers(_ a: PortfolioSnapshot.Project, over b: PortfolioSnapshot.Project,
                        idleSince: [String: Date] = [:], now: Date = Date()) -> Bool {
        let (idleA, idleB) = (idleDuration(a, idleSince: idleSince, now: now),
                              idleDuration(b, idleSince: idleSince, now: now))
        if idleA != idleB { return idleA > idleB }
        return a.name < b.name
    }

    /// The same question for *grooming*: which project needs work written for it
    /// first. The emptier queue goes first, and only then the one that has been
    /// idle longer.
    ///
    /// Deliberately **not** `prefers`, which `RunScheduling` shares. Idle time
    /// means the same thing to both; queue depth means the opposite. The
    /// emptiest queue is the one most in need of grooming and the one with the
    /// least left to run, so folding need into the shared comparator would have
    /// the scheduler reach first for the project that has nothing to start.
    static func prefersForRefill(_ a: PortfolioSnapshot.Project, over b: PortfolioSnapshot.Project,
                                 idleSince: [String: Date] = [:], now: Date = Date()) -> Bool {
        let (readyA, readyB) = (a.count(.ready), b.count(.ready))
        if readyA != readyB { return readyA < readyB }
        let (idleA, idleB) = (idleDuration(a, idleSince: idleSince, now: now),
                              idleDuration(b, idleSince: idleSince, now: now))
        if idleA != idleB { return idleA > idleB }
        return a.name < b.name
    }

    /// How long a project has had nothing running. A project with a run in
    /// flight is not idle whatever the map says — it is being worked on right
    /// now, and the map's entry is just the last time it wasn't.
    static func idleDuration(_ project: PortfolioSnapshot.Project,
                             idleSince: [String: Date], now: Date) -> TimeInterval {
        guard !project.isRunning, let since = idleSince[project.name] else { return 0 }
        return max(0, now.timeIntervalSince(since))
    }

    /// Update the idle clock from a fresh snapshot: a project with no run keeps
    /// the instant it was first seen idle; one that has started running loses
    /// its entry, and a project that has closed drops out entirely.
    static func trackIdle(_ idleSince: [String: Date],
                          portfolio: PortfolioSnapshot, now: Date) -> [String: Date] {
        var next: [String: Date] = [:]
        for project in portfolio.projects where !project.isRunning {
            next[project.name] = idleSince[project.name] ?? now
        }
        return next
    }

    // MARK: - Ledger

    /// What the coordinator has already groomed, so it does not fill the same
    /// gap twice.
    ///
    /// The rule is deliberately blunt: **filed once for a project, never filed
    /// again**. It could instead track why each item died and allow a second
    /// attempt at the ones that failed for a fixable reason — but that is the
    /// mechanism by which an item a human rejected comes back next pass, slightly
    /// reworded, forever. A gap worth a second attempt is worth a human saying so.
    ///
    /// Only items actually written are recorded — plus proposals a human
    /// explicitly **dismissed**, which is the same fact arrived at from the other
    /// side. A proposal merely sitting unreviewed is not recorded, or advisory
    /// mode would silently burn every idea it showed you.
    struct Ledger: Sendable, Equatable {
        private(set) var entries: [Entry]

        struct Entry: Codable, Sendable, Equatable {
            let at: Date
            let project: String
            let itemID: String
            /// The normalized title — what "the same item" means here.
            let fingerprint: String
            /// `ready` or `draft` (what it was filed as), or `dismissed`.
            let disposition: String
        }

        /// The disposition of a proposal a human rejected. Not a
        /// `BacklogItemStatus` because nothing was written — the entry exists so
        /// the drafter doesn't offer the same gap again.
        static let dismissed = "dismissed"

        init(entries: [Entry] = []) {
            self.entries = entries
        }

        /// Has this project already had this item — by id or by title — filed
        /// for it? Scoped per project: the same idea in two repos is two items.
        func hasFiled(project: String, id: String, title: String) -> Bool {
            let print = Self.fingerprint(title)
            return entries.contains {
                $0.project == project && ($0.itemID == id || (!print.isEmpty && $0.fingerprint == print))
            }
        }

        /// Every id this project has been given, so a new draft doesn't collide
        /// with one already on disk under a different title.
        func filedIDs(project: String) -> Set<String> {
            Set(entries.filter { $0.project == project }.map(\.itemID))
        }

        /// The same ids, oldest first — what the drafter is *shown*.
        ///
        /// `filedIDs(project:)` answers "is this id taken", and a set is the
        /// right shape for that. This one exists because the drafter is judged
        /// against the whole ledger by `hasFiled(project:id:title:)`, so the
        /// list it is given has to be the whole ledger too: a prompt showing
        /// only the newest filings lets it spend a candidate slot on something
        /// the loop then drops, and the pass quietly files fewer items than it
        /// was asked for.
        func filedIDsInOrder(project: String) -> [String] {
            entries.filter { $0.project == project }.map(\.itemID)
        }

        mutating func record(project: String, id: String, title: String,
                             disposition: BacklogItemStatus, at: Date = Date()) {
            record(project: project, id: id, title: title,
                   disposition: disposition.rawValue, at: at)
        }

        /// The same, for a disposition that isn't a status — `dismissed`.
        mutating func record(project: String, id: String, title: String,
                             disposition: String, at: Date = Date()) {
            entries.append(Entry(at: at, project: project, itemID: id,
                                 fingerprint: Self.fingerprint(title),
                                 disposition: disposition))
        }

        /// A title reduced to the words that carry it, so trivial rewording is
        /// still the same item. Not a semantic match — that would need a model,
        /// and this has to be cheap enough to run on every candidate.
        static func fingerprint(_ title: String) -> String {
            title.lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { !stopWords.contains($0) }
                .sorted()
                .joined(separator: "-")
        }

        /// Words that say nothing about which item this is. Small on purpose:
        /// dropping too much would collapse distinct items onto one fingerprint
        /// and silently refuse real work.
        private static let stopWords: Set<String> = [
            "a", "an", "the", "to", "of", "for", "in", "on", "and", "or", "is",
            "it", "its", "that", "this", "with", "when", "so", "as", "by", "at"
        ]

        /// The item already in the backlog that a candidate would duplicate, by
        /// the same fingerprint the ledger matches on — nil when it duplicates
        /// nothing.
        ///
        /// The ledger above only knows what the *coordinator* filed, and a bare
        /// id collision is renamed rather than refused
        /// (`Draft.uniqueID(_:taken:)`), so a hand-written item passed every
        /// gate there was and came back re-proposed under `<id>-2` — a whole
        /// worker/reviewer run spent on work already on the board. Whoever wrote
        /// the item is not the question: it is there.
        ///
        /// Every item in the file, `done` ones included. A finished item is the
        /// clearest case of work not worth drafting again, and the fingerprint
        /// is exact enough that only a near-verbatim title reaches it.
        static func duplicate(of title: String, in items: [BacklogItem]) -> BacklogItem? {
            let print = fingerprint(title)
            // A title made of nothing but stop words fingerprints to "", which
            // would otherwise match every other such title rather than none.
            guard !print.isEmpty else { return nil }
            return items.first { fingerprint($0.title) == print }
        }

        // MARK: Persistence

        /// Append-only JSONL beside the coordinator's other logs, so a restart
        /// doesn't wipe the memory of what was already groomed — which would
        /// re-invent every rejected item on the next launch.
        static func defaultURL(home: URL = KiteloopHome.url) -> URL {
            home.appending(path: ".kiteloop").appending(path: "coordinator-refill.jsonl")
        }

        /// Reads what's there. A corrupt line is skipped rather than failing the
        /// load: a half-written record must not cost the whole memory.
        ///
        /// Split on the newline byte rather than on a string of the whole file:
        /// a kill that cuts a line inside a multi-byte character leaves the file
        /// invalid UTF-8, and a whole-file string read would then load nothing.
        static func load(from url: URL) -> Ledger {
            guard let data = try? Data(contentsOf: url) else { return Ledger() }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let entries = data.split(separator: UInt8(ascii: "\n")).compactMap { line -> Entry? in
                try? decoder.decode(Entry.self, from: Data(line))
            }
            return Ledger(entries: entries)
        }

        static func append(_ entry: Entry, to url: URL) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(entry),
                  let line = String(data: data, encoding: .utf8) else { return }

            // Through `AtomicFileWriter.append`, which makes the directory when it
            // is missing and starts a new line first when the ledger doesn't end in
            // one. A plain seek-to-end writes this entry onto the remnant of one a
            // kill cut short, and the pair decodes as neither — so the gap filled
            // after the crash is forgotten, and the next pass pays the model to
            // propose the very item it already filed.
            try? AtomicFileWriter.append(Data((line + "\n").utf8), to: url)
        }
    }

    // MARK: - Drafts

    /// One candidate item, as the drafter returns it and before anything on disk
    /// knows about it. Carries exactly what the Definition-of-Ready asks for, so
    /// a draft that can't be checked can't be produced.
    ///
    /// `Codable` so a gated draft (`CoordinatorQueueRefill.Proposal`) can wrap
    /// one whole.
    struct Draft: Sendable, Equatable, Codable {
        var id: String
        var title: String
        var size: String
        var verify: String
        var what: String
        var how: String
        var validation: [String]
        var outOfScope: [String]
        var epic: String?
        /// The existing item this draft was discovered from — the parent it was
        /// broken out of, or the failed item a regroom turned into new work.
        /// Nil for a gap the drafter found on its own, which is most of them.
        var from: String?
        /// The existing items this draft has to wait for — written on the line as
        /// `needs:<id>` and read at pickup by `DefinitionOfReady.Dependencies`.
        ///
        /// The one thing a draft says that *withholds* it. A pass that splits work
        /// into ordered pieces knows the order at the moment it writes them, and
        /// without this the second piece was filed as runnable as the first, to be
        /// built against something that did not exist yet.
        var needs: [String] = []
        /// The `## Premise` bullets — the claims the item rests on, for the
        /// worker to check before building (`BacklogItemDetail.premise`).
        /// Optional on the wire so a proposal persisted before the field
        /// existed still decodes; nil and empty both mean the item states none.
        var premise: [String]? = nil

        /// The `verify:` the backlog line carries — none for an empty one, the
        /// draft of a project whose verify map has a catch-all rule.
        var lineVerify: String? { verify.isEmpty ? nil : verify }

        /// The backlog line this draft would become.
        func item(status: BacklogItemStatus) -> BacklogItem {
            BacklogItem(id: id, title: title, verify: lineVerify, status: status, type: .local,
                        size: ItemSize(rawValue: size.uppercased()),
                        detailPath: "backlog/\(id).md", from: from, needs: needs)
        }

        /// The detail file this draft would become, for the checks to read
        /// before it is written rather than after.
        var detail: BacklogItemDetail {
            BacklogItemDetail(
                id: id, title: title, status: nil, epic: epic, priority: nil,
                size: size.uppercased(), owner: nil, jira: nil, repo: nil,
                verifyCommands: verify.isEmpty ? [] : [.init(name: "verify", cmd: verify, expect: nil)],
                why: nil, acceptanceCriteria: validation, outOfScope: outOfScope,
                context: nil, notes: nil, what: what, approach: how,
                premise: premise ?? []
            )
        }

        /// `backlog/<id>.md`, in the shape `BacklogViewModel.createDetail`
        /// scaffolds and `BacklogParser.parseDetail` reads back.
        ///
        /// - Parameter notes: why this landed as a draft, when it did. A gated
        ///   item has to say what it failed, or whoever finds it in the backlog
        ///   has no idea why it isn't running.
        func detailMarkdown(notes: [String] = []) -> String {
            // Unquoted, like `BacklogViewModel.createDetail`'s scaffold: the
            // frontmatter reader splits `key: value` on the first colon and does
            // not strip quotes, so quoting a title would make the quotes part of
            // it.
            var out = "---\nid: \(id)\ntitle: \(title)\nsize: \(size.uppercased())\n"
            if let epic, !epic.isEmpty { out += "epic: \(epic)\n" }
            // The `cmd` is quoted and escaped together by the writer paired with
            // the reader that resolves it: escaping only `"` here left a
            // backslashed command — `-exec … {} \;` — to come back short of the
            // backslash, so the run executed something other than what was
            // groomed.
            if !verify.isEmpty {
                out += "verify:\n  - name: verify\n    cmd: \(BacklogParser.doubleQuotedScalarLiteral(verify))\n"
            }
            out += "---\n\n## What\n\n\(what)\n\n"
            // After the What and before the How, where the worker reads it
            // before it reads how to build; omitted, not left as an empty
            // heading, for the item that states no premise.
            if let premise, !premise.isEmpty {
                out += "## Premise\n\n" + premise.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
            }
            out += "## How\n\n\(how)\n\n## Validation\n\n"
            out += validation.map { "- [ ] \($0)" }.joined(separator: "\n")
            out += "\n\n## Out of Scope\n\n"
            out += outOfScope.isEmpty
                ? "- Nothing stated — anything beyond the What above.\n"
                : outOfScope.map { "- \($0)" }.joined(separator: "\n") + "\n"
            if !notes.isEmpty {
                out += "\n## Notes\n\n" + notes.map { "- \($0)" }.joined(separator: "\n") + "\n"
            }
            return out
        }

        /// The drafter's JSON. Anything missing a field the Definition-of-Ready
        /// needs is dropped here rather than filed and refused later — a
        /// half-drafted item is a bad draft, not a backlog entry.
        static func parse(_ text: String) -> [Draft] {
            guard let json = RunQualityJudge.firstJSONObject(in: text),
                  let data = json.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let raw = obj["items"] as? [Any] else { return [] }

            return raw.compactMap { element -> Draft? in
                guard let entry = element as? [String: Any] else { return nil }
                func string(_ key: String) -> String {
                    ((entry[key] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                }
                func list(_ key: String) -> [String] {
                    ((entry[key] as? [Any]) ?? []).compactMap {
                        ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    }.filter { !$0.isEmpty }
                }
                let id = slug(string("id"))
                let draft = Draft(id: id, title: string("title"), size: string("size"),
                                  verify: string("verify"), what: string("what"),
                                  how: string("how"), validation: list("validation"),
                                  outOfScope: list("outOfScope"),
                                  epic: string("epic").isEmpty ? nil : string("epic"),
                                  from: parentID(string("from")),
                                  needs: dependencyIDs(list("needs")))
                // `title` and `verify` are written onto the backlog line as-is, and
                // the line is one line: a newline inside either ends it early, so the
                // item loses its `size:` token, its status and its detail link, and
                // the remainder is read back as an unparsed line. Refused here, with
                // the rest of the half-drafted candidates, rather than repaired
                // silently — a draft that cannot be written down is a bad draft.
                guard !draft.id.isEmpty, !draft.title.isEmpty, !draft.verify.isEmpty,
                      !draft.title.contains(where: \.isNewline),
                      !draft.verify.contains(where: \.isNewline),
                      !draft.what.isEmpty, !draft.how.isEmpty, !draft.validation.isEmpty,
                      let size = ItemSize(rawValue: draft.size.uppercased()),
                      !size.isTooLargeForAutopilot else { return nil }
                return draft
            }
        }

        /// The parent id a draft claims to come from, or nil for none.
        ///
        /// Not slugged: the parent is an id that already exists somewhere, and
        /// reducing it would rename it (a Jira key would lose its case). It is
        /// only checked for what the *line* cannot carry — a newline or the `|`
        /// that separates the line's fields would split the item into nonsense —
        /// so a parent the backlog doesn't have is still written down.
        static func parentID(_ raw: String) -> String? {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !trimmed.contains("|"),
                  !trimmed.contains(where: \.isNewline) else { return nil }
            return trimmed
        }

        /// The ids a draft says it has to wait for, minus any the line cannot
        /// carry.
        ///
        /// Each one gets exactly the treatment a parent gets: it names an item
        /// that already exists, so it is taken as written rather than slugged, and
        /// only a `|` or a newline — which would split the line into nonsense —
        /// refuses it. Refused one at a time rather than all at once: an item that
        /// still names two of its three prerequisites is sequenced behind those
        /// two, which is closer to what the drafter meant than filing it runnable.
        static func dependencyIDs(_ raw: [String]) -> [String] {
            raw.compactMap(parentID)
        }

        /// An id has to survive being a filename and a backlog line, so it is
        /// reduced to what both accept rather than trusted as written.
        static func slug(_ raw: String) -> String {
            let cleaned = raw.lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .joined(separator: "-")
            return String(cleaned.prefix(64))
        }

        /// `<id>`, `<id>-2`, `<id>-3` … — the first form free of a collision with
        /// anything already in the backlog or the ledger.
        static func uniqueID(_ id: String, taken: Set<String>) -> String {
            guard taken.contains(id) else { return id }
            for suffix in 2...99 where !taken.contains("\(id)-\(suffix)") {
                return "\(id)-\(suffix)"
            }
            return id
        }
    }

    /// A draft plus what resolving its `needs:` had to say about it — what a pass
    /// carries between accepting a candidate and gating it.
    ///
    /// The notes are prose for the item's `## Notes`, not a refusal. An id that
    /// named nothing is dropped from the line and written down, and the item is
    /// still filed as `ready` if the gates are happy with it: parking it would
    /// leave a perfectly good item sitting as a `draft` because the drafter
    /// invented a prerequisite — the same never-runs failure by another route.
    struct Drafted: Sendable, Equatable {
        var draft: Draft
        var notes: [String]

        init(draft: Draft, notes: [String] = []) {
            self.draft = draft
            self.notes = notes
        }
    }

    /// Make every `needs:` id a pass files name an item that actually exists.
    ///
    /// Three things happen to an id, in this order:
    ///
    /// * **A renamed sibling is followed.** `Draft.uniqueID(_:taken:)` renames a
    ///   candidate whose id collides with one already in the backlog, and a
    ///   sibling drafted in the same pass named the id the drafter wrote. Left
    ///   alone that id now names the *existing* item it collided with — a real
    ///   id, so nothing downstream notices, and the item waits for the wrong
    ///   thing.
    /// * **What is left has to resolve.** An id in neither the backlog nor this
    ///   pass names nothing, and `DefinitionOfReady.Dependencies.unmet(for:)`
    ///   reads it as `needs <id> — no such item` at every pickup, for ever: the
    ///   item is withheld on each pass, records a check failure each time, and
    ///   nothing ever returns it to the groomer. So it is dropped from the line
    ///   and named in the item's notes instead — the item runs when its turn
    ///   comes, and whoever opens the file learns what the drafter meant.
    /// * **What resolves must not close a loop over this pass's own drafts.** An
    ///   id that names another draft in the pass, followed far enough, can lead
    ///   back to the draft that named it — the self-reference case is the same
    ///   failure with zero steps between. `gate` evaluates the Definition-of-Ready
    ///   without dependencies on purpose, so a cycle like that files as `ready`
    ///   on both ends and then reads as `dependency cycle` at every pickup,
    ///   withheld for ever the same way an unresolvable id used to be. It is
    ///   dropped the same way: off the line, named in the notes. Only one edge of
    ///   a pair needs to go to break the loop, so once an earlier candidate's
    ///   edge has already been dropped the later one, walking the same graph, no
    ///   longer finds a cycle and keeps its own.
    ///
    /// `from` is renamed the same way and never dropped: it records lineage,
    /// blocks nothing, and a parent the backlog doesn't have is still worth
    /// writing down.
    ///
    /// - Parameters:
    ///   - drafts: the candidates this pass accepted, ids already made unique.
    ///   - renamed: what each renamed candidate was called before → after.
    ///   - existingIDs: the ids already in the backlog being filed into.
    static func resolveDependencies(_ drafts: [Draft],
                                    renamed: [String: String] = [:],
                                    existingIDs: Set<String>) -> [Drafted] {
        // The whole pass counts as existing: these are filed together, so a draft
        // may name one written after it.
        let known = existingIDs.union(drafts.map(\.id))

        // What each candidate still needs, keyed by its final id. Seeded from the
        // pass as drafted and narrowed as each candidate is resolved, so a later
        // candidate walks the loop as it stands after earlier edges were cut
        // rather than the loop as originally proposed.
        var liveNeeds: [String: [String]] = Dictionary(
            uniqueKeysWithValues: drafts.map { ($0.id, $0.needs.map { renamed[$0] ?? $0 }) })

        return drafts.map { candidate in
            var draft = candidate
            if let from = draft.from { draft.from = renamed[from] ?? from }
            var notes: [String] = []
            draft.needs = candidate.needs.compactMap { wanted in
                let id = renamed[wanted] ?? wanted
                guard known.contains(id) else {
                    notes.append("dropped needs:\(wanted) — no item with that id in "
                                 + "the backlog or this pass")
                    return nil
                }
                if let chain = cycleBack(to: draft.id, from: id, in: liveNeeds) {
                    notes.append("dropped needs:\(wanted) — dependency cycle: "
                                 + ([draft.id] + chain).joined(separator: " → "))
                    return nil
                }
                return id
            }
            liveNeeds[draft.id] = draft.needs
            return Drafted(draft: draft, notes: notes)
        }
    }

    /// The chain `id → … → start`, when following `graph` from `id` leads back to
    /// `start` — the drafting-time counterpart to
    /// `DefinitionOfReady.Dependencies`'s own cycle probe, but walked over
    /// candidates that don't exist as backlog items yet. `id == start` is the
    /// self-reference case and returns immediately, the same way any other loop
    /// does.
    private static func cycleBack(to start: String, from id: String,
                                  in graph: [String: [String]]) -> [String]? {
        var queue: [[String]] = [[id]]
        var seen: Set<String> = [id]
        while !queue.isEmpty {
            let path = queue.removeFirst()
            guard let tail = path.last else { continue }
            if tail == start { return path }
            for next in graph[tail] ?? [] where !seen.contains(next) {
                seen.insert(next)
                queue.append(path + [next])
            }
        }
        return nil
    }

    /// Bounds one pass's total filing at `limit` — the same cap `draft(target:…)`
    /// already holds the model's own candidates to (`.prefix(target.count)`),
    /// now held over the model's drafts *and* the repo's own signal findings
    /// together.
    ///
    /// `signal` sits at the front of the result, as it always has, and is
    /// trimmed from its own tail — the end nearest the model's drafts — when
    /// the two together run over `limit`. Trimming the signal side rather than
    /// the model's is the point: a signal finding's id is deterministic
    /// (`SignalDrafting.id(for:)`), so a trimmed finding is regathered for free
    /// on the next pass, while a model draft has already been paid for and
    /// cannot be got back.
    ///
    /// - Returns: what to file, and how many signal findings were left over —
    ///   zero whenever nothing needed trimming.
    static func boundedDrafts(signal: [Drafted], model: [Drafted],
                              limit: Int) -> (drafts: [Drafted], leftoverSignal: Int) {
        let room = max(0, limit - model.count)
        guard signal.count > room else { return (signal + model, 0) }
        return (Array(signal.prefix(room)) + model, signal.count - room)
    }
}
