import Foundation
import KiteloopCore

/// `GET /v1/spend`: the spend ledger over a window, grouped the way the caller
/// asks.
extension KiteloopControlServer {

    /// How many days the window covers when the caller doesn't say, and the
    /// most it will cover.
    static let spendDefaultDays = 7
    static let spendMaxDays = 90

    func spend(_ query: [String: String]) async -> HTTPServer.Response {
        guard let grouping = query["by"].flatMap(SpendBreakdown.Grouping.init(rawValue:)) else {
            return .error("\"by\" must be agent, project, routine, model or day", status: 400)
        }
        guard let ledger = spendLedger else { return .error("This Kiteloop keeps no spend ledger", status: 503) }
        let (from, to) = Self.spendWindow(days: query["days"], now: Date(), calendar: .current)
        // Off the main actor: the ledger is a file read end to end.
        let rows = await Task.detached { ledger.rows() }.value
        let breakdown = SpendBreakdown.make(rows: rows, by: grouping, from: from, to: to)
        let iso = ISO8601DateFormatter()
        return .json([
            "by": grouping.rawValue,
            "from": iso.string(from: from),
            "to": iso.string(from: to),
            "basis": breakdown.basis.rawValue,
            "totalUSD": breakdown.totalUSD,
            "rows": breakdown.rows.map { ["key": $0.key, "costUSD": $0.costUSD, "count": $0.count] }
        ])
    }

    /// `days` back from today's local midnight, through `now`: 1 is today
    /// alone. Unparseable is the default; anything else is clamped to 1…90.
    static func spendWindow(days: String?, now: Date, calendar: Calendar) -> (from: Date, to: Date) {
        let count = min(max(days.flatMap { Int($0) } ?? spendDefaultDays, 1), spendMaxDays)
        let midnight = calendar.startOfDay(for: now)
        let from = calendar.date(byAdding: .day, value: -(count - 1), to: midnight) ?? midnight
        return (from, now)
    }
}
