import Foundation

/// One unit of spend: a chat turn, a routine's turn, an autopilot run or a
/// Planner pass — one line of `~/.kiteloop/spend-ledger.jsonl`.
package struct SpendRow: Codable, Equatable, Sendable {

    /// What spent it. Each unit of spend is written once, by the one place that
    /// owns it: a turn a run or a routine already charges is not also a chat row.
    package enum Source: String, Codable, Sendable, CaseIterable {
        case chat
        case routine
        case autopilot
        case planner
    }

    /// What kind of figure `costUSD` is. On a subscription login the CLI's
    /// dollar figure is a token-equivalent — what the turn would have cost at
    /// list price — not a bill.
    package enum Basis: String, Codable, Sendable {
        case usd
        case tokenEquivalent = "token-equivalent"

        /// The basis a figure has under the login it was spent on.
        package init(auth method: ClaudeAuthMethod) {
            self = method == .subscription ? .tokenEquivalent : .usd
        }
    }

    package var at: Date
    /// The local calendar day `at` falls in, as `yyyy-MM-dd` (`DayKey`).
    package var day: String
    package var source: Source
    /// The project's root path; nil when nobody could attribute it.
    package var project: String?
    package var agent: String?
    package var routine: String?
    /// Nil or empty groups as "unknown".
    package var model: String?
    package var costUSD: Double
    package var basis: Basis

    package init(at: Date, day: String? = nil, source: Source, project: String? = nil,
                 agent: String? = nil, routine: String? = nil, model: String? = nil,
                 costUSD: Double, basis: Basis) {
        self.at = at
        self.day = day ?? DayKey.string(for: at)
        self.source = source
        self.project = project
        self.agent = agent
        self.routine = routine
        self.model = model
        self.costUSD = costUSD
        self.basis = basis
    }
}

/// Who a charge belongs to — what `DailySpendLedger.charge` needs, beyond the
/// amount and the project, to write the charge's ledger row.
package struct SpendAttribution: Equatable, Sendable {
    package var source: SpendRow.Source
    package var agent: String?
    package var routine: String?
    package var model: String?

    package init(source: SpendRow.Source, agent: String? = nil, routine: String? = nil, model: String? = nil) {
        self.source = source
        self.agent = agent
        self.routine = routine
        self.model = model
    }
}

/// The append-only record of every unit of spend, one JSON line per row.
///
/// Holds no state but its URL: every read goes to the file, so two instances
/// over the same file agree, and a write never waits on an earlier read.
package final class SpendLedger: Sendable {

    package let url: URL

    package init(url: URL) {
        self.url = url
    }

    /// `~/.kiteloop/spend-ledger.jsonl`.
    package static var defaultURL: URL {
        KiteloopHome.url.appending(path: ".kiteloop/spend-ledger.jsonl")
    }

    /// Appends one row. Through `AtomicFileWriter.append`, which starts a new
    /// line first when the file doesn't end in one, so a row a kill cut short
    /// costs only itself. A row that cannot be written is logged and dropped:
    /// the ledger records spend, it never stands in the way of it.
    package func append(_ row: SpendRow) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            var data = try Self.encoder.encode(row)
            data.append(UInt8(ascii: "\n"))
            try AtomicFileWriter.append(data, to: url)
        } catch {
            StoreProblemReporter.shared.report(store: "Spend ledger", operation: .write, url: url, error: error)
        }
    }

    /// Every row the file holds, in the order written. A damaged line costs
    /// only itself; a missing file is an empty ledger.
    package func rows() -> [SpendRow] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: UInt8(ascii: "\n")).compactMap {
            try? Self.decoder.decode(SpendRow.self, from: Data($0))
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// The ledger's rows over a window, grouped one way — what `GET /v1/spend`
/// answers.
package struct SpendBreakdown: Equatable, Sendable {

    /// How rows are grouped.
    package enum Grouping: String, Sendable, CaseIterable {
        case agent, project, routine, model, day
    }

    /// What kind of figure the total is: every row's own basis when they agree,
    /// `mixed` when they don't. An empty window reads as `usd`.
    package enum Basis: String, Sendable {
        case usd
        case tokenEquivalent = "token-equivalent"
        case mixed
    }

    package struct Row: Equatable, Sendable {
        package var key: String
        package var costUSD: Double
        package var count: Int
    }

    package var rows: [Row]
    package var totalUSD: Double
    package var basis: Basis

    /// The key a row with nothing to group by is filed under.
    package static let unknownKey = "unknown"

    /// Rows whose `at` falls in `from...to`, grouped by `by`, costliest first
    /// (ties by key, so the order is stable).
    package static func make(rows: [SpendRow], by grouping: Grouping, from: Date, to: Date) -> SpendBreakdown {
        let inWindow = rows.filter { $0.at >= from && $0.at <= to }
        var totals: [String: Row] = [:]
        for row in inWindow {
            let key = Self.key(of: row, by: grouping)
            totals[key, default: Row(key: key, costUSD: 0, count: 0)].costUSD += row.costUSD
            totals[key]?.count += 1
        }
        let sorted = totals.values.sorted { ($0.costUSD, $1.key) > ($1.costUSD, $0.key) }
        return SpendBreakdown(rows: sorted,
                              totalUSD: inWindow.reduce(0) { $0 + $1.costUSD },
                              basis: basis(of: inWindow))
    }

    private static func key(of row: SpendRow, by grouping: Grouping) -> String {
        let value: String?
        switch grouping {
        case .agent: value = row.agent
        case .project: value = row.project
        case .routine: value = row.routine
        case .model: value = row.model
        case .day: value = row.day
        }
        guard let value, !value.isEmpty else { return unknownKey }
        return value
    }

    /// Every row's own basis when they agree, `mixed` when they don't.
    package static func basis(of rows: [SpendRow]) -> Basis {
        let kinds = Set(rows.map(\.basis))
        if kinds == [.tokenEquivalent] { return .tokenEquivalent }
        return kinds.count > 1 ? .mixed : .usd
    }
}

// MARK: - A budget's window over the ledger

extension SpendBudget {
    /// What the matching rows cost in the budget's current window: the local
    /// day `now` falls in, or its calendar month. A row belongs to the day it
    /// was filed under (`SpendRow.day`, a `DayKey`), so a month is every day
    /// key that shares today's `yyyy-MM`.
    package func spent(in rows: [SpendRow], now: Date, calendar: Calendar,
                       where matches: (SpendRow) -> Bool) -> Double {
        let window = window(now: now, calendar: calendar)
        return rows.reduce(0) { total, row in
            row.day.hasPrefix(window) && matches(row) ? total + row.costUSD : total
        }
    }

    /// The budget's current window by name: the day key of `now`, or its
    /// `yyyy-MM` for a month. Two moments in one window share a name.
    package func window(now: Date, calendar: Calendar) -> String {
        let today = DayKey.string(for: now, timeZone: calendar.timeZone)
        return period == .day ? today : String(today.prefix(Self.monthKeyLength))
    }

    /// `yyyy-MM`, the part of a day key that names its month.
    private static let monthKeyLength = 7
}
