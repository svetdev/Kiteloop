import Foundation

/// The worker node's and the merge gate's deadlines, the worker's turn
/// budget and the per-item cost cap, read off the project's own landed runs instead of set by hand.
///
/// Both used to be numbers on the Autopilot page — `stallTimeoutMinutes` and
/// `autoMergeVerifyTimeoutMinutes` — and neither was ever a preference: they
/// describe how long this project's work actually takes, which the ledger
/// already records. A number guessed once and never revisited fails in both
/// directions, and both failures have been seen here: a literal 600 seconds
/// killed nine worker rounds whose trees were green, and a 15-minute gate
/// refused merges whose verify was simply a long suite.
///
/// Each deadline is derived from the phase it bounds — the worker's from the
/// worker phase, the gate's from the gate and pre-review verify phases — never
/// from the whole run: a run's duration is the sum of phases plus everything
/// between them, so bounding one phase with it sets a clock nothing ever runs
/// against.
///
/// The gate's clock reads two phases because the same clock times two of them:
/// the merge gate's verify and the pre-review verify are the item's own
/// `verify:` run on the same class of tree, held to the one deadline. Reading
/// only the merge phase left every project running under `propose` — which
/// parks a passed run at the approval gate and so never measures a merge
/// phase — on the 15-minute default its cold builds outgrew, with no way to
/// ever earn a measured one. Now a project at `propose` gets a measured gate
/// deadline after the same number of runs as a project at `land`.
package enum RunTimeouts {
    /// What a project ran on before the derivation existed, and what one
    /// without enough history still runs on.
    package static let defaultWorkerMinutes = 20
    /// 30, not 15: a merge-gate verify on a cold worktree compiles the API from
    /// zero before any suite runs, and 15 minutes killed the-booking-page-counts-
    /// its-visitors on 2026-09-13 with the work green (one project's ci-local takes
    /// 12–20 minutes cold). A project earns a measured deadline only after five
    /// landed runs, and none land while auto-merge is not attempted.
    package static let defaultGateMinutes = 30
    /// Below this many samples a phase is not a distribution, it is a handful
    /// of anecdotes — one long night would set the deadline for every run
    /// after it. Each deadline counts its own phase's samples, so a project
    /// whose runs stop before the merge gate measures its worker deadline and
    /// keeps the default gate one until it lands runs.
    package static let minimumLandedRuns = 5
    /// The worker's deadline never drops below this, however fast the project's
    /// runs have been: a watchdog that fires inside a normal round turns a
    /// working run into a blocked item.
    package static let workerFloorMinutes = 15
    /// …and never rises above this: past an hour with no progress, a worker is
    /// not slow, it is stuck, and the whole point of the watchdog is that an
    /// unattended run cannot be killed by a single hang.
    package static let workerCapMinutes = 60
    /// The gate's floor. Lower than the worker's because a gate runs commands
    /// rather than a model, and uncapped because a project whose merge-verify
    /// is its whole CI is a project whose gate legitimately takes as long as
    /// its CI does.
    package static let gateFloorMinutes = 10
    /// The p95 plus half again. The p95 is what a slow-but-normal phase costs;
    /// the headroom is the margin that keeps the slowest normal phase from
    /// reading as a hang.
    package static let headroom = 1.5
    package static let percentile = 0.95

    /// The worker's turn budget before a project has enough runs carrying a
    /// turn count, and the least it is ever given after: a budget measured
    /// below what every project ran on before would cut short work that used
    /// to finish.
    package static let workerTurnsFloor = 50
    /// …and the most: a worker that needs more turns than this on one item is
    /// working on an item too big to be one, and the budget is what says so.
    package static let workerTurnsCap = 150

    /// Where a deadline came from — what `GET /v1/autopilot` reports beside
    /// each of the two numbers, so a reader can tell "this project measured
    /// it" from "this project has not landed enough runs to measure it yet".
    /// One per deadline, because the two are measured separately.
    package enum Source: String, Sendable, Equatable {
        case derived
        case `default`
    }

    /// One run's phase durations, in seconds — either absent when that phase
    /// never happened, or was never measured.
    ///
    /// A run that ended before the merge gate measured no merge phase, and it
    /// is still a worker sample: holding it out would leave a project whose
    /// runs stop at the gate — every project running under `propose`, which
    /// parks a passed run at the approval gate — on the 20-minute default its
    /// worker rounds outgrew, with no way to ever earn a measured one.
    ///
    /// `gateSeconds` is one run's worth of "how long do this project's verify
    /// commands take", which two phases answer: the merge gate's verify and the
    /// pre-review one. `gateSeconds(merge:verify:)` is how a caller holding
    /// both readings folds them into the one number.
    package struct Sample: Sendable, Equatable {
        package let workerSeconds: Double?
        package let gateSeconds: Double?
        /// The turns the run's worker session reported on its last hand-off;
        /// nil for a run that recorded none.
        package let workerTurns: Int?
        /// What the whole run cost, in USD; nil for a run that recorded no
        /// spend, so a run that never reached the model is no cost sample.
        package let costUSD: Double?

        package init(workerSeconds: Double? = nil, gateSeconds: Double? = nil, workerTurns: Int? = nil,
                     costUSD: Double? = nil) {
            self.workerSeconds = workerSeconds
            self.gateSeconds = gateSeconds
            self.workerTurns = workerTurns
            self.costUSD = costUSD
        }
    }

    /// The gate seconds one run contributes, given what it measured of each
    /// verify it ran: the larger of the two where it ran both, the one it ran
    /// where it ran one, and nil where it ran neither — a run that measured no
    /// verify at all is no gate sample, never a stand-in zero.
    ///
    /// The larger rather than the mean or the merge one: both are the same
    /// commands on the same class of tree, and a deadline is only useful if it
    /// clears the slowest of the runs it was measured from. Taking the smaller
    /// would let a warm pre-review tree set the clock a cold merge tree is then
    /// killed by.
    package static func gateSeconds(merge: Double?, verify: Double?) -> Double? {
        [merge, verify].compactMap { $0 }.max()
    }

    /// One deadline, in whole minutes, and where that number came from.
    package struct Deadline: Sendable, Equatable {
        package let minutes: Int
        package let source: Source

        package init(minutes: Int, source: Source) {
            self.minutes = minutes
            self.source = source
        }
    }

    /// The worker node's turn budget, and where that number came from.
    package struct TurnBudget: Sendable, Equatable {
        package let turns: Int
        package let source: Source

        package init(turns: Int, source: Source) {
            self.turns = turns
            self.source = source
        }
    }

    /// The per-item cost ceiling this project's landed runs imply, before any
    /// one item's prediction is folded in — see `itemCapUSD(predicted:)`.
    /// `usd` is nil while the project has too few runs carrying a cost.
    package struct CostBound: Sendable, Equatable {
        package let usd: Double?
        package let source: Source

        package init(usd: Double?, source: Source) {
            self.usd = usd
            self.source = source
        }

        /// One item's ceiling. Measured: the project's p95 cost plus half
        /// again, never below the item's own predicted cost. Unmeasured: the
        /// predicted cost plus the same half again. Nil — uncapped, the
        /// project's budget still bounding it — when there is neither.
        package func itemCapUSD(predicted: Double?) -> Double? {
            let predicted = predicted.flatMap { $0 > 0 ? $0 : nil }
            if let usd { return max(usd, predicted ?? 0) }
            return predicted.map { $0 * headroom }
        }
    }

    /// The pair of deadlines a run is given, and the worker's turn budget, each
    /// with its own source: one may be measured while another is still the
    /// default.
    package struct Deadlines: Sendable, Equatable {
        package let worker: Deadline
        package let gate: Deadline
        package let workerTurns: TurnBudget
        package let itemCost: CostBound

        package var workerMinutes: Int { worker.minutes }
        package var gateMinutes: Int { gate.minutes }

        package init(worker: Deadline, gate: Deadline,
                     workerTurns: TurnBudget = TurnBudget(turns: workerTurnsFloor, source: .default),
                     itemCost: CostBound = CostBound(usd: nil, source: .default)) {
            self.worker = worker
            self.gate = gate
            self.workerTurns = workerTurns
            self.itemCost = itemCost
        }

        /// What a project runs on until its ledger can answer for itself.
        package static let defaults = Deadlines(
            worker: Deadline(minutes: defaultWorkerMinutes, source: .default),
            gate: Deadline(minutes: defaultGateMinutes, source: .default))
    }

    /// The deadlines `landed` implies, each read off its own phase's samples
    /// and each answering for itself: fewer than `minimumLandedRuns` samples of
    /// a phase is answered with that phase's default rather than with a number
    /// derived from too little. The caller cannot tell the two apart by value
    /// alone, which is why each answer carries its own `source`.
    package static func deadlines(landed: [Sample]) -> Deadlines {
        Deadlines(
            worker: deadline(landed.compactMap(\.workerSeconds), fallback: defaultWorkerMinutes,
                             floor: workerFloorMinutes, cap: workerCapMinutes),
            gate: deadline(landed.compactMap(\.gateSeconds), fallback: defaultGateMinutes,
                           floor: gateFloorMinutes, cap: nil),
            workerTurns: turnBudget(landed.compactMap(\.workerTurns)),
            itemCost: costBound(landed.compactMap(\.costUSD).filter { $0 > 0 }))
    }

    /// The project's cost bound: the p95 of `costs` plus half again, or none
    /// while too few runs carry a cost to measure.
    private static func costBound(_ costs: [Double]) -> CostBound {
        guard costs.count >= minimumLandedRuns else { return CostBound(usd: nil, source: .default) }
        return CostBound(usd: p95(costs) * headroom, source: .derived)
    }

    /// The worker's turn budget: the p95 of `turns` plus half again, rounded up
    /// and held between `workerTurnsFloor` and `workerTurnsCap`, or the floor
    /// while too few runs carry a turn count to measure.
    private static func turnBudget(_ turns: [Int]) -> TurnBudget {
        guard turns.count >= minimumLandedRuns else {
            return TurnBudget(turns: workerTurnsFloor, source: .default)
        }
        let raw = Int(ceil(p95(turns.map(Double.init)) * headroom))
        return TurnBudget(turns: min(max(raw, workerTurnsFloor), workerTurnsCap), source: .derived)
    }

    /// One phase's deadline: its p95 plus half again, held between `floor` and
    /// `cap`, or `fallback` while the phase has too few samples to measure.
    private static func deadline(_ seconds: [Double], fallback: Int,
                                 floor: Int, cap: Int?) -> Deadline {
        guard seconds.count >= minimumLandedRuns else {
            return Deadline(minutes: fallback, source: .default)
        }
        return Deadline(minutes: minutes(p95(seconds), floor: floor, cap: cap), source: .derived)
    }

    /// The 95th percentile of `seconds` by nearest rank — the smallest sample
    /// at or above which 95% of the run sits. Nearest rank rather than an
    /// interpolated percentile because every value here is a measured run and
    /// a deadline should be one a run actually took, not a number between two
    /// of them. Empty is 0, which only reaches a caller that bypassed
    /// `deadlines(landed:)`; there the floor answers.
    package static func p95(_ seconds: [Double]) -> Double {
        let sorted = seconds.sorted()
        guard let last = sorted.indices.last else { return 0 }
        let rank = Int(ceil(percentile * Double(sorted.count))) - 1
        return sorted[min(max(rank, 0), last)]
    }

    /// `seconds` plus half again, in whole minutes, held between `floor` and
    /// `cap`. Rounded up: a deadline rounded down is one that fires on the very
    /// phase it was measured from.
    private static func minutes(_ seconds: Double, floor: Int, cap: Int?) -> Int {
        let raw = Int(ceil(seconds * headroom / 60))
        return min(max(raw, floor), cap ?? Int.max)
    }
}
