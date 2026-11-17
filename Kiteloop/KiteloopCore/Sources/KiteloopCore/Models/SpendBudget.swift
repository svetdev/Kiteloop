import Foundation

/// A ceiling on spend over a day or a month, where it warns, and what
/// reaching it does — the one shape a budget takes, whatever it is set on.
///
/// It holds no spend of its own: what was spent is read off the spend
/// ledger's rows (`spent(in:now:calendar:where:)`, beside `SpendLedger`), and
/// where that leaves the budget is `standing(spentUSD:)`.
package struct SpendBudget: Codable, Equatable, Sendable {

    /// The window the ceiling is over.
    package enum Period: String, Codable, Sendable, CaseIterable {
        /// The current local calendar day.
        case day
        /// The current local calendar month.
        case month
    }

    /// What reaching the ceiling does.
    package enum Consequence: String, Codable, Sendable, CaseIterable {
        /// A person is asked whether to go on.
        case ask
        /// What the budget is on stops until a person starts it again.
        case pause
        /// Each autonomous start is refused until the window turns over.
        case refuse
    }

    /// Where spend leaves a budget.
    package enum Standing: String, Sendable {
        case under
        /// At or past the warning point, under the ceiling.
        case warning
        /// At or past the ceiling.
        case atLimit
    }

    /// The share of a ceiling at which a budget warns unless it says
    /// otherwise — the one figure every budget in the app warns at.
    package static let defaultWarnAtFraction = 0.8

    /// Above zero.
    package var ceilingUSD: Double
    package var period: Period
    /// The share of the ceiling at which the budget warns: above 0, at most 1.
    package var warnAtFraction: Double
    package var consequence: Consequence

    package init(ceilingUSD: Double, period: Period, warnAtFraction: Double = SpendBudget.defaultWarnAtFraction,
                 consequence: Consequence) {
        self.ceilingUSD = ceilingUSD
        self.period = period
        self.warnAtFraction = warnAtFraction
        self.consequence = consequence
    }

    /// A budget written without a warning point warns at the default.
    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ceilingUSD = try container.decode(Double.self, forKey: .ceilingUSD)
        period = try container.decode(Period.self, forKey: .period)
        warnAtFraction = try container.decodeIfPresent(Double.self, forKey: .warnAtFraction)
            ?? Self.defaultWarnAtFraction
        consequence = try container.decode(Consequence.self, forKey: .consequence)
    }

    // MARK: - Spend against it

    package func standing(spentUSD: Double) -> Standing {
        if spentUSD >= ceilingUSD { return .atLimit }
        return spentUSD >= ceilingUSD * warnAtFraction ? .warning : .under
    }

    /// The window in the words a refusal uses: `($5.20 spent today)`.
    package var windowWords: String {
        period == .day ? "today" : "this month"
    }

    // MARK: - As the API reads and writes it

    package var json: [String: Any] {
        ["ceilingUSD": ceilingUSD, "period": period.rawValue, "warnAtFraction": warnAtFraction,
         "consequence": consequence.rawValue]
    }

    /// What is wrong with the figures; empty for a budget that can be kept.
    package var problems: [String] {
        var found: [String] = []
        if !(ceilingUSD > 0) { found.append("\"budget.ceilingUSD\" is above zero") }
        if !(warnAtFraction > 0 && warnAtFraction <= 1) {
            found.append("\"budget.warnAtFraction\" is above 0 and at most 1")
        }
        return found
    }

    /// The budget a request body's `budget` object describes, or what is
    /// wrong with it. The ceiling is required — there is no amount to assume;
    /// an absent `period` is a day, an absent `warnAtFraction` the default and
    /// an absent `consequence` a refusal, as the app's daily budgets already
    /// behave.
    package static func parse(_ json: [String: Any]) -> (value: SpendBudget?, problems: [String]) {
        var problems: [String] = []
        let period = choice(json["period"], default: Period.day, named: "period", problems: &problems)
        let consequence = choice(json["consequence"], default: Consequence.refuse, named: "consequence",
                                 problems: &problems)
        let warnAt = json["warnAtFraction"].map { amount($0) } ?? defaultWarnAtFraction
        let budget = SpendBudget(ceilingUSD: amount(json["ceilingUSD"]), period: period,
                                 warnAtFraction: warnAt, consequence: consequence)
        problems = budget.problems + problems
        return problems.isEmpty ? (budget, []) : (nil, problems)
    }

    /// A JSON number as an amount, whole or not; zero — which no field takes
    /// — for anything that is not a number.
    private static func amount(_ value: Any?) -> Double {
        (value as? NSNumber)?.doubleValue ?? 0
    }

    /// One of an enum's cases by name: `fallback` when the body does not say,
    /// and a problem listing the choices when it says something else.
    private static func choice<Choice: RawRepresentable & CaseIterable>(
        _ value: Any?, default fallback: Choice, named field: String, problems: inout [String]
    ) -> Choice where Choice.RawValue == String {
        guard let value else { return fallback }
        if let text = value as? String, let choice = Choice(rawValue: text) { return choice }
        let choices = Choice.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
        problems.append("\"budget.\(field)\" is one of \(choices)")
        return fallback
    }
}
