import Foundation
import KiteloopCore

/// `GET /v1/spend`: the spend ledger over a window, grouped the way the caller
/// asks — and `GET /v1/spend/forecast`: what that history says is coming.
@MainActor
struct SpendEndpoints {
    let ledger: SpendLedger?
    /// The rate-limit reading each open agent last reported — the headroom
    /// token-equivalent spend is drawn from.
    var readings: [AgentActivityEvent.RateLimitInfo] = []

    /// How many days the window covers when the caller doesn't say, and the
    /// most it will cover.
    static let defaultDays = 7
    static let maxDays = 90

    func answer(_ query: [String: String]) async -> HTTPServer.Response {
        guard let grouping = query["by"].flatMap(SpendBreakdown.Grouping.init(rawValue:)) else {
            return .error("\"by\" must be agent, project, routine, model or day", status: 400)
        }
        guard let ledger else { return .error("This Kiteloop keeps no spend ledger", status: 503) }
        let (from, to) = Self.window(days: query["days"], now: Date(), calendar: .current)
        // Off the main actor: the ledger is a file read end to end.
        let rows = await Task.detached { ledger.rows() }.value
        let breakdown = SpendBreakdown.make(rows: rows, by: grouping, from: from, to: to)
        let iso = ISO8601DateFormatter()
        return .json([
            "by": grouping.rawValue,
            "from": iso.string(from: from),
            "to": iso.string(from: to),
            "basis": breakdown.basis.rawValue,
            "rateLimit": rateLimit(for: breakdown.basis) ?? NSNull(),
            "totalUSD": breakdown.totalUSD,
            "rows": breakdown.rows.map { ["key": $0.key, "costUSD": $0.costUSD, "count": $0.count] }
        ])
    }

    /// What each routine's next run and each project's month will probably
    /// cost. `project` narrows the projections to one root path.
    func forecast(_ query: [String: String], now: Date = Date(),
                  calendar: Calendar = .current) async -> HTTPServer.Response {
        guard let ledger else { return .error("This Kiteloop keeps no spend ledger", status: 503) }
        // Off the main actor: the ledger is a file read end to end.
        let rows = await Task.detached { ledger.rows() }.value
        let forecast = SpendForecast.make(rows: rows, now: now, calendar: calendar)
        let projects = forecast.projects.filter { query["project"] == nil || $0.project == query["project"] }
        return .json([
            "month": forecast.month,
            "asOf": ISO8601DateFormatter().string(from: now),
            "projects": projects.map(Self.projectJSON),
            "routines": forecast.routines.map(Self.routineJSON)
        ])
    }

    private static func projectJSON(_ project: SpendForecast.Project) -> [String: Any] {
        ["project": project.project,
         "monthToDateUSD": project.monthToDateUSD,
         "daysElapsed": project.daysElapsed,
         "daysInMonth": project.daysInMonth,
         "projectedMonthEndUSD": project.projectedMonthEndUSD,
         "basis": project.basis.rawValue]
    }

    private static func routineJSON(_ routine: SpendForecast.Routine) -> [String: Any] {
        ["routine": routine.routine,
         "runs": routine.runs,
         "expectedUSD": routine.expectedUSD as Any? ?? NSNull(),
         "lowUSD": routine.lowUSD as Any? ?? NSNull(),
         "highUSD": routine.highUSD as Any? ?? NSNull(),
         "basis": routine.basis.rawValue]
    }

    /// The reading closest to its limit, when the window holds spend drawn
    /// from a subscription: billed dollars have no window to run out of.
    private func rateLimit(for basis: SpendBreakdown.Basis) -> [String: Any]? {
        guard basis != .usd else { return nil }
        return UsageSummary.closest(readings).map(KiteloopControlServer.rateLimitJSON)
    }

    /// `days` back from today's local midnight, through `now`: 1 is today
    /// alone. Unparseable is the default; anything else is clamped to 1…90.
    static func window(days: String?, now: Date, calendar: Calendar) -> (from: Date, to: Date) {
        let count = min(max(days.flatMap { Int($0) } ?? defaultDays, 1), maxDays)
        let midnight = calendar.startOfDay(for: now)
        let from = calendar.date(byAdding: .day, value: -(count - 1), to: midnight) ?? midnight
        return (from, now)
    }
}
