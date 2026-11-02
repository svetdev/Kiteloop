import Foundation
import KiteloopCore

/// What work of a given size *actually* costs and how long it *actually* takes,
/// derived from recorded runs.
///
/// An item's `size` drives its cost ceiling, and until now nothing checked that
/// the label predicted anything. Measured over the merged items of 2026-08-08,
/// `escaped-defect-tracking` was sized **S**, ran 14.5 minutes and cost $13.27 —
/// 3.4× the mean S — and was capped as an S the whole way, while an item sized
/// **M** finished in 7 minutes for $3.82. The labels were not wrong so much as
/// unmeasured: nothing said what an S costs, so nothing could say this one
/// wasn't one.
///
/// So the expectation is read off the history instead: p10/p50/p90 of cost and
/// duration per size, over a recent window. That distribution is what the cap is
/// based on (`CostGovernor`'s size rung) and what an item's prediction is checked
/// against at pickup.
///
/// Two rules keep it honest:
/// - **Only runs that produced something count.** Nine of thirty-one runs on
///   2026-08-08 recorded $0 and four produced no diff at all. Calibrating on
///   those trains the band on a broken pipeline and drags every number toward
///   zero — see `TaskMetricRecord.producedWork`.
/// - **Too few samples means no band.** Three runs make a confident-looking
///   number that is mostly noise; below `minimumSamples` there is no band and
///   the caller keeps whatever fixed cap it had.
///
/// Pure, so the bands can be checked without a store or a repo on disk.
enum SizeCalibration {

    /// How far back evidence is read. Long enough for a size to accumulate
    /// samples, short enough that a change in how the team works — a new model,
    /// a different reviewer loop — shows up in the band within a season rather
    /// than being averaged against a year of history.
    static let windowDays = 90

    /// Fewest evidence records a size needs before its band is trusted enough to
    /// base a ceiling on. The alternative to a band is the fixed cap that has
    /// always been there, which is a better answer than a p90 derived from three
    /// runs — one freak run moves that p90 by more than the whole band is wide.
    static let minimumSamples = 8

    // MARK: - The distribution

    /// The three points of one measurement's distribution.
    struct Percentiles: Equatable, Sendable {
        let p10: Double
        let p50: Double
        let p90: Double
    }

    /// What a size class is measured to be: the middle of it (`p50`, the typical
    /// run) and its edges (`p10`…`p90`, where "this doesn't look like an S"
    /// starts).
    struct Band: Equatable, Sendable {
        /// `ItemSize.rawValue` this band describes.
        let size: String
        /// Evidence records it was computed from — never below
        /// `minimumSamples`, since a band is not produced below that.
        let sampleCount: Int
        let costUSD: Percentiles
        let durationSeconds: Percentiles

        /// Whether a cost sits inside the band. The edges are inclusive: a
        /// prediction exactly at p90 is the ninetieth-percentile run, not an
        /// outlier.
        func contains(costUSD cost: Double) -> Bool {
            cost >= costUSD.p10 && cost <= costUSD.p90
        }

        /// "n=84, $0.98–$4.20, 3.4–10.9 min" — the evidence behind a flag, so a
        /// log line says what the band is rather than only that something was
        /// outside it.
        var summary: String {
            String(
                format: "n=%d, $%.2f–$%.2f, %.1f–%.1f min",
                sampleCount, costUSD.p10, costUSD.p90,
                durationSeconds.p10 / 60, durationSeconds.p90 / 60
            )
        }
    }

    // MARK: - What counts as evidence

    /// Whether a recorded run says anything about what its size costs.
    ///
    /// A run that changed no file did not do the work its size describes, and a
    /// run whose cost never got attributed ($0) says nothing about price. Both
    /// happen for reasons that have nothing to do with how big the item was, so
    /// both are dropped rather than averaged in.
    static func isEvidence(_ record: TaskMetricRecord) -> Bool {
        record.costUSD > 0 && record.producedWork
    }

    /// The evidence for one size in one project, newest window only.
    ///
    /// Scoped to the project on purpose — a size class pooled across unrelated
    /// projects predicts nothing useful about this one, which is the same reason
    /// `CostGovernor.projectPath` exists.
    static func evidence(
        in records: [TaskMetricRecord],
        size: String,
        projectPath: String,
        now: Date = Date(),
        windowDays: Int = SizeCalibration.windowDays
    ) -> [TaskMetricRecord] {
        let canonical = KiteloopProject.canonicalPath(projectPath)
        let cutoff = now.addingTimeInterval(-Double(windowDays) * 86_400)
        return records.filter {
            $0.declaredSize?.uppercased() == size.uppercased()
                && KiteloopProject.canonicalPath($0.projectPath) == canonical
                && $0.completedAt >= cutoff
                && isEvidence($0)
        }
    }

    /// The band for one size, or nil when the size has too little evidence to
    /// have one — the cold start the caller must fall back from rather than
    /// paper over.
    static func band(
        forSize size: String,
        records: [TaskMetricRecord],
        projectPath: String,
        now: Date = Date(),
        windowDays: Int = SizeCalibration.windowDays,
        minimumSamples: Int = SizeCalibration.minimumSamples
    ) -> Band? {
        let pool = evidence(in: records, size: size, projectPath: projectPath,
                            now: now, windowDays: windowDays)
        guard pool.count >= minimumSamples else { return nil }
        return Band(
            size: size.uppercased(),
            sampleCount: pool.count,
            costUSD: percentiles(of: pool.map(\.costUSD)),
            durationSeconds: percentiles(of: pool.map(\.durationSeconds))
        )
    }

    /// One band per size that has enough evidence, smallest size first.
    static func bands(
        records: [TaskMetricRecord],
        projectPath: String,
        now: Date = Date(),
        windowDays: Int = SizeCalibration.windowDays,
        minimumSamples: Int = SizeCalibration.minimumSamples
    ) -> [Band] {
        let sizes = Set(records.compactMap { $0.declaredSize?.uppercased() })
        return sizes.compactMap {
            band(forSize: $0, records: records, projectPath: projectPath,
                 now: now, windowDays: windowDays, minimumSamples: minimumSamples)
        }
        .sorted { sizeRank($0.size) < sizeRank($1.size) }
    }

    // MARK: - The pickup check

    /// An item whose forecast doesn't match the label it carries.
    struct Flag: Equatable, Sendable {
        enum Edge: String, Sendable {
            /// Predicted above the size's p90 — an M wearing an S label, which
            /// is the direction that spends a run against the wrong ceiling.
            case above
            /// Predicted below the size's p10 — smaller than it claims. Cheap,
            /// but still a label that isn't describing the work.
            case below
        }
        let edge: Edge
        let predictedCostUSD: Double
        let band: Band

        /// What the run log says at pickup. Names the number, the edge it
        /// crossed and the evidence behind the band — the cheap moment to say
        /// "this looks like an M wearing an S label", before a run spends
        /// against the wrong ceiling.
        var summary: String {
            let above = edge == .above
            return String(
                format: "predicted $%.2f is %@ the %@ band's %@ ($%.2f) — this looks %@ than an %@ (%@)",
                predictedCostUSD,
                above ? "above" : "below",
                band.size,
                above ? "p90" : "p10",
                above ? band.costUSD.p90 : band.costUSD.p10,
                above ? "bigger" : "smaller",
                band.size,
                band.summary
            )
        }
    }

    /// Checks a prediction against its size's band. Nil when the prediction sits
    /// inside the band, and nil when there is no band to check it against —
    /// there is nothing to say about a size nobody has measured yet.
    static func flag(predictedCostUSD predicted: Double, band: Band?) -> Flag? {
        guard let band, predicted > 0 else { return nil }
        if predicted > band.costUSD.p90 {
            return Flag(edge: .above, predictedCostUSD: predicted, band: band)
        }
        if predicted < band.costUSD.p10 {
            return Flag(edge: .below, predictedCostUSD: predicted, band: band)
        }
        return nil
    }

    // MARK: - Arithmetic

    /// p10/p50/p90 of a sample, by linear interpolation between the two
    /// neighbouring order statistics — the same rule `numpy.percentile` and a
    /// spreadsheet's `PERCENTILE` use, so a band computed here matches one
    /// checked by hand. Empty input is the caller's to rule out; it reads as all
    /// zeroes rather than trapping.
    static func percentiles(of values: [Double]) -> Percentiles {
        let sorted = values.sorted()
        return Percentiles(
            p10: percentile(sorted, 0.10),
            p50: percentile(sorted, 0.50),
            p90: percentile(sorted, 0.90)
        )
    }

    /// `quantile` of an already-sorted sample.
    static func percentile(_ sorted: [Double], _ quantile: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        guard sorted.count > 1 else { return sorted[0] }
        let position = Double(sorted.count - 1) * min(max(quantile, 0), 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
    }

    private static func sizeRank(_ size: String) -> Int {
        ["XS", "S", "M", "L", "XL"].firstIndex(of: size.uppercased()) ?? 99
    }
}
