import Foundation
import KiteloopCore

/// What a run is buying, in money: what one delivered item costs, and how much
/// of the spend bought nothing.
///
/// The cost caps bound *one item's* spend; they say nothing about whether the
/// spending is producing anything. These two figures do, and they are the pair a
/// marathon is actually called off on — a run whose waste share is climbing is
/// burning budget on a broken pipeline, however well-behaved each individual
/// item's cost looks.
///
/// Both numbers were already in the data before anything rendered them: this
/// reads the `TaskMetricRecord` lines the run loop has already written, so
/// **measuring spend costs no spend** — no agent starts, nothing is re-run.
///
/// Pure, like `PortfolioReport`: it takes the ledger *and* the backlog as
/// values and holds no reference to anything live, so the whole arithmetic is
/// exercised without an app, a run or a repo.
///
/// **Whether the spend bought anything is asked of the item, not of the run.**
/// A run's `outcome` is stamped when the run ends and never revisited, so a run
/// that finished `awaiting-approval` — or that a gate returned as `blocked` —
/// wears that outcome for good, including after its work is approved and merged
/// minutes later. Counting every non-`done` outcome as waste therefore counted
/// delivered work as waste permanently: measured over 2026-08-10's 159 runs and
/// $714.19 of attributed spend, it reported 34% wasted ($243.51) when $235.68 of
/// that belonged to items that had since shipped — about 1% was real. A figure
/// wrong by thirty times in that direction invites throttling a queue that is
/// working. The item's current status is the fact that settles it, and the
/// backlog is the one place that holds it: `outcome` and `TaskMetricRecord.merged`
/// are deliberately not consulted here, so there is no second answer to disagree
/// with the first.
///
/// **Attempts are the cost of the thing that shipped.** An item that took three
/// tries cost what all three cost, and that is what `costPerDeliveredItemUSD`
/// divides by items — not by runs, which would report delivery as cheaper than
/// it was every time an item needed a second pass.
///
/// **Unattributed runs are excluded, never averaged in as free.** A run recorded
/// at $0 is one whose cost attribution missed, not one that was cheap. On
/// 2026-08-08, 9 of 31 runs were in that state and every one of them was
/// `blocked` — precisely the runs the waste share exists to expose, so folding
/// them in as free would have understated the problem this metric is for. They
/// are counted in `unattributed` and reported beside the figures instead of
/// disappearing into them.
struct RunEconomics: Sendable, Equatable {

    /// Runs in the window whose cost was attributed — the population every
    /// figure below is computed over.
    let runs: Int
    /// Distinct items those runs were spent on that the backlog now has as
    /// `done`. Items, not runs: three attempts at one item delivered one item.
    let deliveredItems: Int
    /// What those items cost — *every* attributed attempt at them in the window,
    /// including the ones that were rejected on the way.
    let deliveredSpendUSD: Double
    /// Spend on items that have resolved without shipping — the waste numerator.
    /// Work that was paid for and produced nothing standing today.
    let unshippedSpendUSD: Double
    /// Spend on items still in play: `active`, `in-review`, or parked at the
    /// approval gate. Neither delivered nor wasted **yet**, so it is in neither
    /// figure — a run that has just finished must not spike the waste share for
    /// the minutes before its item is approved, and must not flatter the cost per
    /// delivered item either.
    let inFlightSpendUSD: Double
    /// Spend on runs whose item the backlog no longer has. Nothing can say
    /// whether they shipped, so they are excluded and reported rather than
    /// guessed at in either direction.
    let unknownItemSpendUSD: Double
    /// Runs in the window recorded at $0 — excluded from every figure above.
    let unattributed: Int

    /// A window with nothing in it. Also what the "this run" window is before a
    /// run has started, so the panel has something honest to render.
    static let empty = RunEconomics(runs: 0, deliveredItems: 0, deliveredSpendUSD: 0,
                                    unshippedSpendUSD: 0, inFlightSpendUSD: 0,
                                    unknownItemSpendUSD: 0, unattributed: 0)

    /// Attributed spend in the window, whatever became of the item. Unattributed
    /// runs contribute nothing to it by definition — they are counted, not costed.
    var spendUSD: Double {
        deliveredSpendUSD + unshippedSpendUSD + inFlightSpendUSD + unknownItemSpendUSD
    }

    /// The part of `spendUSD` whose item has settled one way or the other — the
    /// waste share's denominator. Spend still in flight is not in it: dividing by
    /// it would move the ratio every time an item is picked up and again when it
    /// is approved, without anything having gone right or wrong.
    var resolvedSpendUSD: Double { deliveredSpendUSD + unshippedSpendUSD }

    /// The mean cost of a delivered item: everything spent on the items that
    /// shipped ÷ how many shipped. Nil when nothing has shipped — rendered as a
    /// phrase, never as $0.00, which would read as free delivery.
    var costPerDeliveredItemUSD: Double? {
        deliveredItems > 0 ? deliveredSpendUSD / Double(deliveredItems) : nil
    }

    /// The share of settled spend that bought nothing. Nil when nothing has
    /// settled: 0/0 is "not measured", not "nothing wasted".
    var wasteShare: Double? {
        resolvedSpendUSD > 0 ? unshippedSpendUSD / resolvedSpendUSD : nil
    }

    /// No attributed run in the window. The panel says so rather than showing a
    /// row of zeroes, which reads as "nothing wasted" — a claim the data has not
    /// made.
    var isEmpty: Bool { runs == 0 }

    // MARK: - Rendering

    /// The one line the panel shows, e.g. `$5.50/delivered · 1% wasted · 9 unattributed`.
    var text: String {
        guard !isEmpty else {
            guard unattributed > 0 else { return "no completed runs yet" }
            return "\(unattributed) run\(Self.s(unattributed)), none with a recorded cost"
        }
        var parts = [costPerDeliveredItemText, wasteShareText]
        if unattributed > 0 { parts.append("\(unattributed) unattributed") }
        return parts.joined(separator: " · ")
    }

    /// `$5.50/delivered`, or the plain statement that nothing has shipped — an
    /// average over zero items is not $0.
    var costPerDeliveredItemText: String {
        guard let cost = costPerDeliveredItemUSD else { return "nothing delivered" }
        return "\(PortfolioReport.usd(cost))/delivered"
    }

    /// `1% wasted` — the share of settled spend on items that did not ship.
    var wasteShareText: String {
        guard let share = wasteShare else { return "—% wasted" }
        return "\(Int((share * 100).rounded()))% wasted"
    }

    /// The long form for a tooltip: the same figures spelled out, plus the three
    /// things the headline compresses — that the question is asked of the item
    /// and not of the run, what is still in flight and so counted nowhere yet,
    /// and why the excluded runs are excluded.
    var detail: String {
        guard !isEmpty else {
            var out = "No run in this window has a recorded cost yet."
            if unattributed > 0 {
                out += " \(unattributed) run\(Self.s(unattributed)) finished with no cost attributed,"
                out += " so there is nothing to divide."
            }
            return out + " Computed from records already written — nothing runs to produce it."
        }

        var out = "\(runs) attributed run\(Self.s(runs)) delivered \(deliveredItems)"
        out += " item\(Self.s(deliveredItems)) that the backlog now has as done."
        out += " \(PortfolioReport.usd(deliveredSpendUSD)) on those items — every attempt they took"
        out += ", which is why the cost is per item and not per run —"
        out += " and \(PortfolioReport.usd(unshippedSpendUSD)) on items that have not shipped."
        if inFlightSpendUSD > 0 {
            out += " \(PortfolioReport.usd(inFlightSpendUSD)) is on items still in flight"
            out += " — running, in review, or parked at the approval gate — and counts as neither"
            out += " until they resolve, so a run that has just finished does not move either figure."
        }
        if unknownItemSpendUSD > 0 {
            out += " \(PortfolioReport.usd(unknownItemSpendUSD)) is on items the backlog no longer has"
            out += ", which nothing can place, and is excluded rather than guessed at."
        }
        if unattributed > 0 {
            out += " \(unattributed) run\(Self.s(unattributed)) recorded $0 and"
            out += " \(unattributed == 1 ? "is" : "are") excluded from both figures:"
            out += " attribution that missed is not free work, and averaging it in"
            out += " would make waste read smaller than it is."
        }
        return out
    }

    private static func s(_ count: Int) -> String { count == 1 ? "" : "s" }

    // MARK: - What a run's spend bought

    /// What the backlog says became of the item a run was spent on — the only
    /// question that decides which bucket the money is in.
    ///
    /// Four answers, not two, and the last two are the point. Spend on an item
    /// that has not settled yet is not waste and not delivery; spend on an item
    /// nobody can find is not evidence of either. Both are excluded and reported
    /// rather than folded into a figure they would falsify.
    enum Delivery: Sendable, Equatable {
        /// The item shipped. Everything spent on it, over however many attempts,
        /// is what shipping it cost.
        case delivered
        /// The item is still moving — `active`, `in-review`, or waiting on a
        /// human at the approval gate.
        case inFlight
        /// The item has settled without shipping: bounced back to `ready`,
        /// `blocked`, or dropped to `draft`. This is the waste.
        case unshipped
        /// The backlog has no such item, so it cannot answer.
        case unknown
    }

    /// The single join between a run and whether its work shipped.
    ///
    /// `ready` counts as unshipped rather than in flight on purpose. An item
    /// bounced by review may well ship on the next pass — and when it does, every
    /// attempt at it moves to `delivered` at once, because this is asked afresh
    /// each time the figure is drawn. Until then the money is spent and nothing
    /// is standing, and an item cycling ready → rejected → ready forever is the
    /// exact failure this metric exists to expose; parking it in a bucket that
    /// counts as neither would hide it.
    static func delivery(of status: BacklogItemStatus?) -> Delivery {
        guard let status else { return .unknown }
        switch status {
        case .done: return .delivered
        case .active, .inReview, .awaitingApproval: return .inFlight
        case .ready, .blocked, .draft: return .unshipped
        }
    }

    // MARK: - Build

    /// Aggregate one window of the ledger.
    ///
    /// - Parameters:
    ///   - records: every run metric on record. Filtered here by `completedAt`,
    ///     like `PortfolioReport` — an item is counted in the window it
    ///     *finished* in, so an item straddling a boundary is counted once.
    ///     Note that this also bounds which *attempts* at a delivered item are
    ///     charged to it: an attempt from yesterday is yesterday's spend.
    ///   - projectPath: the project to scope to; nil counts every project. The
    ///     panel scopes to its own project — another project's spend has no
    ///     business in this run's figures.
    ///   - itemStatus: what the backlog has for each item id, right now
    ///     (`BacklogFile.statusByItemID`). The one source that decides whether
    ///     spend bought anything; an id missing from it is `unknown`, not waste.
    ///   - from: window start, inclusive.
    ///   - to: window end, inclusive.
    static func make(records: [TaskMetricRecord], projectPath: String?,
                     itemStatus: [String: BacklogItemStatus],
                     from: Date, to: Date) -> RunEconomics {
        let canonical = projectPath.map(KiteloopProject.canonicalPath)
        var runs = 0, unattributed = 0
        var deliveredSpend = 0.0, unshippedSpend = 0.0, inFlight = 0.0, unknown = 0.0
        var deliveredItems = Set<String>()

        for record in records {
            guard record.completedAt >= from, record.completedAt <= to else { continue }
            if let canonical, KiteloopProject.canonicalPath(record.projectPath) != canonical { continue }
            // A refusal at pickup is in neither count. It spawned no session, so
            // its $0 is what it cost rather than a cost that went missing — and
            // reporting it as unattributed would put "3 runs finished with no
            // cost attributed" on screen for three runs that never started.
            guard !record.didNotRun else { continue }
            // A $0 run is attribution that missed, not a run that was free.
            guard record.costUSD > 0 else { unattributed += 1; continue }

            runs += 1
            switch delivery(of: itemStatus[record.itemID]) {
            case .delivered:
                deliveredItems.insert(record.itemID)
                deliveredSpend += record.costUSD
            case .unshipped:
                unshippedSpend += record.costUSD
            case .inFlight:
                inFlight += record.costUSD
            case .unknown:
                unknown += record.costUSD
            }
        }

        return RunEconomics(runs: runs, deliveredItems: deliveredItems.count,
                            deliveredSpendUSD: deliveredSpend,
                            unshippedSpendUSD: unshippedSpend,
                            inFlightSpendUSD: inFlight,
                            unknownItemSpendUSD: unknown,
                            unattributed: unattributed)
    }

    // MARK: - Windows

    /// The two windows the panel shows. A lifetime average changes too slowly to
    /// act on — the run in front of you and the day it is part of are what a
    /// decision to keep going is made on.
    struct Windows: Sendable, Equatable {
        /// The run in flight, or the last one started this session.
        let run: RunEconomics
        /// Since midnight, local time — the marathon, not the item.
        let today: RunEconomics
    }

    /// Both windows in one pass over the ledger.
    ///
    /// `runStartedAt` nil means no run has started this session, and the run
    /// window is `.empty` rather than silently borrowing today's figures.
    static func windows(records: [TaskMetricRecord], projectPath: String?,
                        itemStatus: [String: BacklogItemStatus],
                        runStartedAt: Date?, now: Date,
                        calendar: Calendar = .current) -> Windows {
        Windows(
            run: runStartedAt.map {
                make(records: records, projectPath: projectPath, itemStatus: itemStatus,
                     from: $0, to: now)
            } ?? .empty,
            today: make(records: records, projectPath: projectPath, itemStatus: itemStatus,
                        from: calendar.startOfDay(for: now), to: now)
        )
    }
}
