import Foundation

/// What the spend ledger's history says is coming — what
/// `GET /v1/spend/forecast` answers. Every figure is read off rows already
/// written: nothing here knows a price, and a routine with too little history
/// reports no figure rather than a guess.
package struct SpendForecast: Equatable, Sendable {

    /// What a routine's next run will probably cost, from its own past runs.
    package struct Routine: Equatable, Sendable {
        package var routine: String
        /// How many past runs the figures are read off.
        package var runs: Int
        /// The median of those runs; nil when there are too few to forecast.
        package var expectedUSD: Double?
        /// The cheapest and the costliest of those runs; nil with `expectedUSD`.
        package var lowUSD: Double?
        package var highUSD: Double?
        package var basis: SpendBreakdown.Basis
    }

    /// What a project will have spent by the end of the calendar month, at
    /// the daily rate it has spent at so far this month.
    package struct Project: Equatable, Sendable {
        package var project: String
        package var monthToDateUSD: Double
        /// Days of the month begun so far: today counts, so never under 1.
        package var daysElapsed: Int
        package var daysInMonth: Int
        package var projectedMonthEndUSD: Double
        package var basis: SpendBreakdown.Basis
    }

    /// The month the projection is for, as `yyyy-MM` in `calendar`.
    package var month: String
    package var projects: [Project]
    package var routines: [Routine]

    /// The most runs of one routine a forecast reads: its latest ones, so a
    /// routine whose prompt or model changed is forecast from how it runs now.
    package static let runsConsidered = 20

    /// The fewest runs that make a forecast. A median needs a middle run that
    /// is neither the cheapest nor the costliest; under three there is none,
    /// and the "range" is just the runs themselves.
    package static let fewestRuns = 3

    package static func make(rows: [SpendRow], now: Date, calendar: Calendar) -> SpendForecast {
        let parts = calendar.dateComponents([.year, .month], from: now)
        return SpendForecast(month: String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0),
                             projects: monthEnd(rows: rows, now: now, calendar: calendar),
                             routines: routines(rows: rows))
    }

    /// One forecast per routine that has ever been charged, costliest expected
    /// run first (ties by id; routines with no forecast last).
    package static func routines(rows: [SpendRow]) -> [Routine] {
        let charged = rows.filter { $0.source == .routine && !($0.routine ?? "").isEmpty }
        let forecasts = Dictionary(grouping: charged) { $0.routine ?? "" }.map { id, runs in
            routine(id, runs: runs.sorted { $0.at < $1.at }.suffix(runsConsidered))
        }
        return forecasts.sorted { ($0.expectedUSD ?? -1, $1.routine) > ($1.expectedUSD ?? -1, $0.routine) }
    }

    private static func routine(_ id: String, runs: ArraySlice<SpendRow>) -> Routine {
        let costs = runs.map(\.costUSD).sorted()
        let enough = costs.count >= fewestRuns
        return Routine(routine: id, runs: costs.count,
                       expectedUSD: enough ? median(ofSorted: costs) : nil,
                       lowUSD: enough ? costs.first : nil,
                       highUSD: enough ? costs.last : nil,
                       basis: SpendBreakdown.basis(of: Array(runs)))
    }

    /// The middle value, or the mean of the middle two. `costs` is not empty.
    private static func median(ofSorted costs: [Double]) -> Double {
        let middle = costs.count / 2
        return costs.count.isMultiple(of: 2) ? (costs[middle - 1] + costs[middle]) / 2 : costs[middle]
    }

    /// One projection per project charged since the start of `now`'s calendar
    /// month, highest projection first (ties by project). Linear: the month to
    /// date, divided by the days begun, times the days the month has.
    package static func monthEnd(rows: [SpendRow], now: Date, calendar: Calendar) -> [Project] {
        guard let month = calendar.dateInterval(of: .month, for: now),
              let daysInMonth = calendar.range(of: .day, in: .month, for: now)?.count else { return [] }
        let daysElapsed = max(calendar.component(.day, from: now), 1)
        let thisMonth = rows.filter { $0.at >= month.start && $0.at <= now }
        let projections = Dictionary(grouping: thisMonth) { row -> String in
            guard let project = row.project, !project.isEmpty else { return SpendBreakdown.unknownKey }
            return project
        }.map { project, charged in
            let spent = charged.reduce(0) { $0 + $1.costUSD }
            return Project(project: project, monthToDateUSD: spent, daysElapsed: daysElapsed,
                           daysInMonth: daysInMonth,
                           projectedMonthEndUSD: spent / Double(daysElapsed) * Double(daysInMonth),
                           basis: SpendBreakdown.basis(of: charged))
        }
        return projections.sorted {
            ($0.projectedMonthEndUSD, $1.project) > ($1.projectedMonthEndUSD, $0.project)
        }
    }
}
