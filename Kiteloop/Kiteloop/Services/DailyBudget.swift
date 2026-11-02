import Foundation
import KiteloopCore
import os.log

private let dailyBudgetLog = Logger(subsystem: "ai.kasatkin.kiteloop", category: "daily-budget")

/// Who asked for a run. The daily budget governs **autonomy, not the person**:
/// an exhausted budget refuses an autonomous start and still lets a human start
/// one, so the ceiling can never lock the user out of their own app.
///
/// Absent from a control-API body means `.human` — the conservative reading of a
/// caller that predates the field is a person at a keyboard, and a person is
/// always allowed to spend.
enum RunInitiator: String, Sendable, Codable {
    case human
    case autonomous
}

/// One daily ceiling, joined with what the day has actually cost against it. A
/// value, so the decision ("may an autonomous run start?") is pure arithmetic
/// testable without files, a clock, or a run loop.
///
/// Two of these govern an autonomous start — the portfolio's ceiling and the
/// project's own — and `ProjectDailyBudget` is the pair. `scope` is what makes a
/// refusal readable: "which budget stopped this?" has two possible answers now,
/// and a refusal that didn't say would send the operator to raise the wrong one.
///
/// Distinct from the autopilot's two per-*run* ceilings: the derived item cap
/// bounds one item and the session cap bounds one session, but neither
/// bounds a coordinator that keeps starting fresh sessions all night.
struct DailyBudget: Sendable, Equatable {
    /// Which ceiling this is — and, for a project's own, whose.
    enum Scope: Sendable, Equatable {
        /// The portfolio-wide ceiling in `~/.kiteloop/global-config.json`.
        case portfolio
        /// One project's own ceiling, named as the operator knows it.
        case project(String)

        /// How the refusal names the ceiling mid-sentence. The portfolio wording
        /// is unqualified because that is what it was before there was anything
        /// to distinguish it from, and the log lines of every past night read
        /// that way.
        var noun: String {
            switch self {
            case .portfolio: return "daily budget"
            case .project(let name): return "\(name)'s daily budget"
            }
        }

        /// The same, opening a sentence. A project's name is a proper noun and
        /// is left exactly as the folder spells it.
        var sentenceNoun: String {
            switch self {
            case .portfolio: return "Daily budget"
            case .project(let name): return "\(name)'s daily budget"
            }
        }
    }

    /// The ceiling for one local day; nil = no ceiling.
    var budgetUSD: Double?
    /// What today has cost so far against it (see `DailySpendLedger`).
    var spentUSD: Double = 0
    /// Whose ceiling this is. Portfolio unless said otherwise, so every existing
    /// construction site keeps meaning what it meant.
    var scope: Scope = .portfolio
    /// True when today's spend could not be read — see `DailySpendLedger.loadProblem`.
    /// `spentUSD` is then not what the day cost; it is only what this process has
    /// charged since it gave up on the file.
    ///
    /// Unknown is never free, here as in `resolveCharge`: an autonomous start
    /// under a ceiling is refused while this holds, because a ceiling enforced
    /// against a number nobody can vouch for is not a ceiling. False by default,
    /// so every existing construction site keeps meaning what it meant.
    var spendUnknown: Bool = false

    /// Budget left today; nil when uncapped. Never negative — an overspent day
    /// has nothing left, not a negative allowance.
    var remainingUSD: Double? {
        budgetUSD.map { max(0, $0 - spentUSD) }
    }

    /// True when there is nothing left to spend today. A non-positive budget is
    /// treated as no budget rather than a permanent refusal, matching how the
    /// cost caps read a cleared field.
    var isExhausted: Bool {
        guard let budgetUSD, budgetUSD > 0 else { return false }
        return spentUSD >= budgetUSD
    }

    /// Why an autonomous start was refused, with the wording the log and the
    /// control API report. Carries the numbers so a quiet night is explainable
    /// rather than mysterious.
    struct Refusal: Sendable, Equatable {
        /// Why the ceiling refused. Both are the ceiling doing its job; they send
        /// the operator to different places, so they say different things.
        enum Cause: Sendable, Equatable {
            /// The day's spend is known, and it has reached the ceiling.
            case exhausted
            /// The day's spend could not be read, so the ceiling has nothing to
            /// be enforced against.
            case spendUnknown
        }

        var budgetUSD: Double
        var spentUSD: Double
        /// Which ceiling refused — so the operator raises the one that actually
        /// stopped the run rather than the other one.
        var scope: Scope = .portfolio
        /// Exhausted unless said otherwise: that is what a refusal meant before
        /// there was a second reason for one.
        var cause: Cause = .exhausted

        var logLine: String {
            switch cause {
            case .exhausted:
                return String(
                    format: "%@ $%.2f spent ($%.2f today) — autonomous start refused. "
                        + "A run you start yourself still runs; raise the %@ or wait for local midnight.",
                    scope.sentenceNoun, budgetUSD, spentUSD, scope.noun
                )
            case .spendUnknown:
                return String(
                    format: "%@ $%.2f — today's spend could not be read, so the %@ cannot bound "
                        + "anything: autonomous start refused. A run you start yourself still runs, "
                        + "and writes today's tally back.",
                    scope.sentenceNoun, budgetUSD, scope.noun
                )
            }
        }
        var eventReason: String {
            switch cause {
            case .exhausted:
                return String(format: "%@ $%.2f exhausted ($%.2f spent today)",
                              scope.noun, budgetUSD, spentUSD)
            case .spendUnknown:
                return String(format: "%@ $%.2f — today's spend could not be read",
                              scope.noun, budgetUSD)
            }
        }
    }

    enum Decision: Sendable, Equatable {
        case allow
        case refuse(Refusal)
    }

    /// The gate. Autonomy stops at the ceiling; a human never does.
    ///
    /// Spend that could not be read is refused ahead of spend that is exhausted:
    /// a day whose total is unknown cannot be called exhausted or not, and the
    /// safe reading of "unknown" under a ceiling is the same one `resolveCharge`
    /// takes — it is not free. A ceiling of nothing still governs nothing, so
    /// unknown spend refuses only where a budget was actually set.
    func decision(for initiator: RunInitiator) -> Decision {
        guard initiator == .autonomous, let budgetUSD, budgetUSD > 0 else { return .allow }
        if spendUnknown {
            return .refuse(Refusal(budgetUSD: budgetUSD, spentUSD: spentUSD,
                                   scope: scope, cause: .spendUnknown))
        }
        guard isExhausted else { return .allow }
        return .refuse(Refusal(budgetUSD: budgetUSD, spentUSD: spentUSD, scope: scope))
    }

    // MARK: - What the panel shows

    /// "$12.40 of $20.00" — just the spend when there's no budget, since "of
    /// nothing" would read as a ceiling of zero. Same formatting as the cost
    /// caps, because it sits next to them.
    var text: String { CostGovernor.Readout.format(spend: spentUSD, cap: budgetUSD) }

    /// Past 80% of the budget the panel says so, early enough to raise it before
    /// the night goes quiet.
    var isNearBudget: Bool {
        (CostGovernor.Readout.utilization(spend: spentUSD, cap: budgetUSD) ?? 0)
            >= CostGovernor.Readout.warnThreshold
    }
}

/// The two ceilings one project's autonomous start has to clear: its own, and
/// the portfolio's.
///
/// **Both apply.** A project's own budget does not license it past the portfolio
/// ceiling — the portfolio ceiling is what bounds the bill — and the portfolio
/// ceiling does not override a stricter project one. So this refuses when either
/// is exhausted, and the refusal it hands back is the exhausted one's, which is
/// how the operator learns which number to raise.
///
/// The project's own ceiling is asked first: it is the narrower statement, and
/// when both are spent, naming the project's is the more actionable answer.
struct ProjectDailyBudget: Sendable, Equatable {
    /// This project's own ceiling and its own share of today's spend. A nil
    /// `budgetUSD` means the project has no ceiling of its own and is governed
    /// by the portfolio's alone.
    var project: DailyBudget
    /// The portfolio-wide ceiling and every project's spend against it.
    var portfolio: DailyBudget

    /// Autonomy stops at whichever ceiling is spent; a human stops at neither.
    func decision(for initiator: RunInitiator) -> DailyBudget.Decision {
        if case .refuse(let refusal) = project.decision(for: initiator) { return .refuse(refusal) }
        return portfolio.decision(for: initiator)
    }
}

/// What has been spent today — portfolio-wide and per project — persisted to
/// `~/.kiteloop/daily-spend.json`.
///
/// One instance per app: the ledger is portfolio-wide by definition, and two
/// instances writing the same file would lose each other's charges.
///
/// **The day is a local calendar day.** Spend resets at the user's midnight, not
/// UTC — a budget that rolled over at 5pm local would hand an overnight run a
/// second allowance in the middle of the night it was written to bound.
@Observable
@MainActor
final class DailySpendLedger {

    /// What one run is charged when its cost is unknown. Deliberately **not
    /// zero**: some runs (worktree-isolated ones especially) report `costUSD = 0`
    /// because their spend was never attributed, and counting those as free would
    /// silently disable the ceiling — the one outcome the budget exists to
    /// prevent. $2 is close to the median measured item cost, so an unattributed
    /// run moves the needle by roughly what it likely cost. Over-charging a run
    /// that genuinely spent nothing is the cheaper mistake.
    /// `nonisolated` so `resolveCharge` — which is deliberately pure and callable
    /// off the main actor — can read it.
    nonisolated static let assumedUnknownRunCostUSD = 2.0

    /// One charge against the day, and what it was based on.
    struct Charge: Sendable, Equatable {
        /// Where the number came from: measured spend, the item's own predicted
        /// cost, the flat assumption of last resort — or nothing at all, for a
        /// run git says produced nothing.
        enum Basis: String, Sendable {
            case measured
            case predicted
            case assumed
            case noWork = "no-work"
        }

        var amountUSD: Double
        var basis: Basis

        /// True when the run's real cost was never reported and this charge is a
        /// stand-in for it. A `noWork` charge is not a stand-in — it is the
        /// positive statement that the run cost the day nothing.
        var wasUnknown: Bool { basis == .predicted || basis == .assumed }

        /// How the charge reads in the run log — silent for a measured cost,
        /// explicit when the number is a stand-in, so nobody has to wonder why
        /// the day's total moved by $2 on a run that reported nothing, or why a
        /// dead session moved it by nothing at all.
        var note: String? {
            switch basis {
            case .measured: return nil
            case .predicted: return String(format: "cost unknown — charged its predicted $%.2f", amountUSD)
            case .assumed: return String(format: "cost unknown — charged the assumed $%.2f", amountUSD)
            case .noWork: return "run produced no work — charged $0.00"
            }
        }
    }

    /// The day's running total. `day` is a local `yyyy-MM-dd` key.
    struct Day: Codable, Sendable, Equatable {
        var day: String
        var spentUSD: Double = 0
        /// How many of the day's charges were stand-ins for an unknown cost —
        /// kept so a day whose total looks wrong can be read against how much of
        /// it was measured.
        var unknownRuns: Int = 0
        /// What each project spent today, keyed by its root path (the same key
        /// `PortfolioSnapshot` and `RunEconomics` identify a project by — names
        /// collide, paths don't).
        ///
        /// In the *same* day-keyed record as the portfolio total on purpose: a
        /// stale day already reads as zero portfolio-wide, and a per-project
        /// total kept anywhere else would roll yesterday's spend into today's
        /// ceiling. `spentUSD` stays the sum of these plus whatever was charged
        /// without a project to attribute it to.
        var byProject: [String: Double] = [:]

        init(day: String, spentUSD: Double = 0, unknownRuns: Int = 0,
             byProject: [String: Double] = [:]) {
            self.day = day
            self.spentUSD = spentUSD
            self.unknownRuns = unknownRuns
            self.byProject = byProject
        }

        /// Decoded field by field so a file written by an older build — one with
        /// no `byProject`, or no `unknownRuns` — still loads. A throw here used to
        /// be swallowed by `load()`, which reset the day to zero mid-day and left
        /// the ceiling silently bounding nothing until midnight; it now records
        /// `loadProblem`, which refuses an autonomous start instead.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            day = try container.decode(String.self, forKey: .day)
            spentUSD = try container.decodeIfPresent(Double.self, forKey: .spentUSD) ?? 0
            unknownRuns = try container.decodeIfPresent(Int.self, forKey: .unknownRuns) ?? 0
            byProject = try container.decodeIfPresent([String: Double].self, forKey: .byProject) ?? [:]
        }
    }

    private(set) var today: Day

    /// Why today's spend could not be read, or nil when it could.
    ///
    /// Non-nil means `today` is not the day's tally — it is whatever this process
    /// has charged since it gave up on the file, starting from zero. That is the
    /// state the ceiling used to be enforced against silently; `DailyBudget`
    /// carries it as `spendUnknown` and refuses an autonomous start on it.
    ///
    /// No file at all is *not* a problem: every one of these stores is created by
    /// its first save, so a missing one is a genuinely fresh day.
    private(set) var loadProblem: String?

    /// Why the last `save()` could not write today's spend back, or nil when it
    /// wrote cleanly.
    ///
    /// A charge that never reaches disk is the write-side twin of `loadProblem`:
    /// the in-memory total this process holds keeps being right, but the next
    /// launch reads a stale or absent file and hands the day a fresh allowance,
    /// silently lifting the ceiling. `DailyBudget` carries it into `spendUnknown`
    /// the same way, and a save that later succeeds clears it.
    private(set) var saveProblem: String?

    /// The name this ledger reports under. A human reads it in a notification
    /// title, and it is half the reporter's dedup key, so it is spelled once.
    static let storeName = "Daily spend"

    private let storageURL: URL
    private let calendar: Calendar
    private let clock: () -> Date
    private let reporter: StoreProblemReporter

    static var defaultURL: URL {
        let dir = KiteloopHome.url.appending(path: ".kiteloop")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "daily-spend.json")
    }

    /// `calendar` and `clock` are seams for tests — production uses the user's
    /// own calendar (hence their own midnight) and the real clock.
    init(
        storageURL: URL? = nil,
        calendar: Calendar = .current,
        clock: @escaping () -> Date = { Date() },
        reporter: StoreProblemReporter = .shared
    ) {
        self.storageURL = storageURL ?? Self.defaultURL
        self.calendar = calendar
        self.clock = clock
        self.reporter = reporter
        self.today = Day(day: Self.dayKey(clock(), calendar: calendar))
        load()
    }

    /// The local calendar day a moment falls in, as `yyyy-MM-dd`. Built from
    /// calendar components rather than a formatter so the key is unambiguous and
    /// the file stays readable.
    nonisolated static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Whether the stored day is still the current one. A stored total from an
    /// earlier day reads as zero rather than rolling forward — the reads below
    /// are *reads*, so they must not mutate state a SwiftUI view is in the
    /// middle of rendering; the stale day is cleared on the next charge.
    private var isStoredDayCurrent: Bool {
        today.day == Self.dayKey(clock(), calendar: calendar)
    }

    /// What the portfolio has spent today, every project together.
    var spentTodayUSD: Double {
        isStoredDayCurrent ? today.spentUSD : 0
    }

    /// What one project has spent today, by root path. Zero for a project that
    /// hasn't run — and zero for every project once the stored day is stale, on
    /// the same terms as the portfolio total.
    func spentTodayUSD(inProject path: String) -> Double {
        guard isStoredDayCurrent, let key = Self.projectKey(path) else { return 0 }
        return today.byProject[key] ?? 0
    }

    /// The key a project's spend is filed under. Nil for a path that says
    /// nothing, so an empty string never becomes a project with a budget.
    nonisolated static func projectKey(_ path: String?) -> String? {
        guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Charges the day for one finished run.
    ///
    /// `costUSD` is the measured spend. Non-positive or nil means the run's cost
    /// was never attributed — it is charged the item's own predicted cost when
    /// there is one, and `assumedUnknownRunCostUSD` when there isn't. Unknown is
    /// never free.
    ///
    /// `evidence` is what git said the run left behind. A run it can show
    /// produced nothing is charged nothing; anything else — including evidence
    /// nobody could read — keeps paying the stand-in.
    ///
    /// `project` is the root path the spend belongs to. It always lands on the
    /// portfolio total; naming a project files it under that project as well, so
    /// a per-project ceiling has a total to be enforced against. Nil is spend
    /// nobody could attribute — it still counts against the portfolio, because
    /// the alternative is a ceiling that stops bounding the moment attribution
    /// fails.
    @discardableResult
    func charge(
        costUSD: Double?,
        estimateUSD: Double? = nil,
        evidence: RunWorkEvidence.Verdict? = nil,
        project: String? = nil
    ) -> Charge {
        let charge = Self.resolveCharge(costUSD: costUSD, estimateUSD: estimateUSD, evidence: evidence)
        let key = Self.dayKey(clock(), calendar: calendar)
        if today.day != key { today = Day(day: key) }
        today.spentUSD += charge.amountUSD
        if let projectKey = Self.projectKey(project) {
            today.byProject[projectKey, default: 0] += charge.amountUSD
        }
        if charge.wasUnknown { today.unknownRuns += 1 }
        save()
        dailyBudgetLog.info(
            "charge basis=\(charge.basis.rawValue, privacy: .public) amountUSD=\(String(format: "%.4f", charge.amountUSD), privacy: .public) day=\(self.today.day, privacy: .public) spentUSD=\(String(format: "%.4f", self.today.spentUSD), privacy: .public) project=\(Self.projectKey(project) ?? "-", privacy: .public)"
        )
        return charge
    }

    /// The charge a cost + estimate pair resolves to, read against what the run
    /// left behind. Pure, so "what does an unknown cost count as?" is answerable
    /// without a ledger.
    ///
    /// The stand-in exists so an unmeasured run can't spend without limit, and
    /// it is kept for exactly that case: a run that *did* work and whose cost
    /// never arrived. What it must not do is charge a run that did nothing. A
    /// day of dead sessions charged ~$3.35 each put $1,016 on 2026-08-08 against
    /// $244.99 actually spent, exhausted a $150 ceiling, and left seven ready
    /// items unstarted — so a burst of dead sessions was a denial of service
    /// against the automation, at the moment it could least recover on its own.
    ///
    /// Order matters. Measured spend is charged whatever the evidence says: a
    /// run that really consumed tokens consumed them even if it committed
    /// nothing. Only an *unreported* cost is read against the evidence, and only
    /// evidence — not `.unknown` — buys a run out of the stand-in.
    nonisolated static func resolveCharge(
        costUSD: Double?,
        estimateUSD: Double?,
        evidence: RunWorkEvidence.Verdict? = nil
    ) -> Charge {
        if let costUSD, costUSD > 0 { return Charge(amountUSD: costUSD, basis: .measured) }
        if evidence?.producedNothing == true { return Charge(amountUSD: 0, basis: .noWork) }
        if let estimateUSD, estimateUSD > 0 { return Charge(amountUSD: estimateUSD, basis: .predicted) }
        return Charge(amountUSD: assumedUnknownRunCostUSD, basis: .assumed)
    }

    /// Today's portfolio spend against a ceiling — the value the gate and the
    /// panel ask.
    func budget(_ budgetUSD: Double?) -> DailyBudget {
        DailyBudget(budgetUSD: budgetUSD, spentUSD: spentTodayUSD,
                    spendUnknown: loadProblem != nil || saveProblem != nil)
    }

    /// One project's own ceiling against its own share of today. `name` is only
    /// how the refusal reads; `path` is what the spend is filed under.
    func budget(_ budgetUSD: Double?, inProject path: String, named name: String) -> DailyBudget {
        DailyBudget(budgetUSD: budgetUSD,
                    spentUSD: spentTodayUSD(inProject: path),
                    scope: .project(name),
                    spendUnknown: loadProblem != nil || saveProblem != nil)
    }

    // MARK: - Persistence

    /// Reads the day back, keeping the file when it will not decode.
    ///
    /// `try?` here merged the two cases this has to tell apart: a file that will
    /// not decode read exactly like no file at all, so the day came up at zero
    /// mid-day, the very next `charge()` saved over the bytes that said otherwise,
    /// and the ceiling stopped bounding anything until midnight with nothing
    /// anywhere saying why. The refusal is moved aside and reported instead, and
    /// what it said is kept in `loadProblem` — not only reported — because the
    /// gate has to act on it.
    private func load() {
        let outcome = QuarantiningJSONFile.read(Day.self, from: storageURL,
                                                store: Self.storeName, reporter: reporter)
        loadProblem = outcome.problem
        if let problem = outcome.problem {
            dailyBudgetLog.error(
                "today's spend could not be read — \(problem, privacy: .public). Autonomous starts are refused while a daily budget is set."
            )
        }
        if let decoded = outcome.value { today = decoded }
    }

    /// Writes the day back, keeping the failure rather than dropping it.
    ///
    /// `try?` here used to merge every failure into silence: a charge that never
    /// reached disk left the in-memory total right for this process and nothing
    /// anywhere saying the file no longer agreed with it, so the next launch read
    /// a stale or absent file and handed the day a fresh allowance — the ceiling
    /// stopped bounding anything with nobody told. The failure is now kept in
    /// `saveProblem`, logged, and reported through `reporter`, the write-side
    /// twin of what `load()` already does for a file that will not decode.
    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(today)
            try AtomicFileWriter.write(data, to: storageURL)
            saveProblem = nil
        } catch {
            let reason = String(describing: error)
            saveProblem = reason
            dailyBudgetLog.error(
                "today's spend could not be written to \(self.storageURL.path(percentEncoded: false), privacy: .public) — \(reason, privacy: .public). Autonomous starts are refused while a daily budget is set."
            )
            reporter.report(store: Self.storeName, operation: .write, url: storageURL, error: error)
        }
    }
}
