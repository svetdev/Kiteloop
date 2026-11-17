import Foundation

/// A budget and what it is on: a routine, an agent or a project.
///
/// The owner decides which of the spend ledger's rows count against it; what
/// reaching the ceiling means is the same for all three, and is decided in one
/// place — `refusal(spentUSD:)` — so the three cannot drift.
package struct OwnedSpendBudget: Equatable, Sendable {

    /// What a budget is on.
    package enum Owner: Hashable, Sendable {
        /// Every turn the routine started, by the routine's id.
        case routine(String)
        /// Everything the agent spent, whatever started it, by the agent's id.
        case agent(id: String, name: String)
        /// Every source in the project, by its root path.
        case project(path: String, name: String)

        /// How a refusal names the budget: `routine budget`,
        /// `Dev's agent budget`, `vault's project budget`.
        package var words: String {
            switch self {
            case .routine: return "routine budget"
            case .agent(_, let name): return "\(name)'s agent budget"
            case .project(_, let name): return "\(name)'s project budget"
            }
        }

        /// Whether a ledger row counts against a budget on this owner.
        package func covers(_ row: SpendRow) -> Bool {
            switch self {
            case .routine(let id): return row.routine == id
            case .agent(let id, _): return row.agent == id
            case .project(let path, _): return row.project.map(Self.rootPath) == Self.rootPath(path)
            }
        }

        /// A root path as rows are compared: a folder is the same folder with
        /// or without its closing slash.
        private static func rootPath(_ path: String) -> String {
            path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        }
    }

    package var owner: Owner
    package var budget: SpendBudget

    package init(owner: Owner, budget: SpendBudget) {
        self.owner = owner
        self.budget = budget
    }

    /// What the owner's rows cost in the budget's current day or month.
    package func spent(in rows: [SpendRow], now: Date, calendar: Calendar) -> Double {
        budget.spent(in: rows, now: now, calendar: calendar, where: owner.covers)
    }

    /// Why this budget refuses unattended work, given what its owner has spent
    /// in the current window; nil while it is under its ceiling.
    package func refusal(spentUSD: Double) -> String? {
        guard budget.standing(spentUSD: spentUSD) == .atLimit else { return nil }
        return String(format: "%@ $%.2f per %@ exhausted ($%.2f spent %@)",
                      owner.words, budget.ceilingUSD, budget.period.rawValue, spentUSD, budget.windowWords)
    }

    /// The first of `budgets` that refuses unattended work, in the order
    /// given, read against the ledger's rows; nil when every one is under its
    /// ceiling. Every budget applies: one under its ceiling licenses nothing
    /// past another that is spent.
    package static func refusal(among budgets: [OwnedSpendBudget], rows: [SpendRow], now: Date,
                                calendar: Calendar) -> String? {
        for owned in budgets {
            if let refusal = owned.refusal(spentUSD: owned.spent(in: rows, now: now, calendar: calendar)) {
                return refusal
            }
        }
        return nil
    }

    /// The budget as the API reports it: its own fields, what has been spent
    /// in the current window and where that leaves it — `under`, `warning`
    /// from the budget's own warning point, `atLimit` from the ceiling.
    package func reading(in rows: [SpendRow], now: Date, calendar: Calendar) -> [String: Any] {
        let spentUSD = spent(in: rows, now: now, calendar: calendar)
        var json = budget.json
        json["spentUSD"] = spentUSD
        json["standing"] = budget.standing(spentUSD: spentUSD).rawValue
        return json
    }
}

// MARK: - A budget in a request body

extension SpendBudget {

    /// What a request body's `budget` field asks for.
    package enum Edit: Equatable, Sendable {
        /// The body does not name it.
        case keep
        /// `null`.
        case clear
        case set(SpendBudget)

        /// The budget that stands once the edit is applied to `existing`.
        package func applied(to existing: SpendBudget?) -> SpendBudget? {
            switch self {
            case .keep: return existing
            case .clear: return nil
            case .set(let budget): return budget
            }
        }
    }

    /// What kind of thing a budget is being set on, for the words of a
    /// refused edit.
    package enum Holder: String, Sendable {
        case routine, agent, project

        var plural: String { rawValue + "s" }
        var possessive: String { (self == .agent ? "an " : "a ") + rawValue + "'s" }
    }

    /// Reads a body's `budget`: absent keeps what is there, `null` clears it
    /// and an object is the new one. A budget on a routine, an agent or a
    /// project refuses; the other consequences are named as not yet available.
    /// With problems, the edit is `keep`.
    package static func edit(_ value: Any?, on holder: Holder) -> (edit: Edit, problems: [String]) {
        guard let value else { return (.keep, []) }
        if value is NSNull { return (.clear, []) }
        guard let object = value as? [String: Any] else {
            return (.keep, ["\"budget\" is an object, or null to clear it"])
        }
        let parsed = parse(object)
        guard let budget = parsed.value else { return (.keep, parsed.problems) }
        guard budget.consequence == .refuse else {
            return (.keep, ["\"budget.consequence\" \"\(budget.consequence.rawValue)\" is not yet available "
                            + "for \(holder.plural): \(holder.possessive) budget takes \"refuse\""])
        }
        return (.set(budget), [])
    }
}

// MARK: - Saying so once

/// The line a chat shows when its agent is over its budget — said once per
/// window, not once per message. A person typing is never refused; this is
/// what they are told instead.
package struct OverBudgetNotice: Equatable, Sendable {

    /// The window the line was last said in.
    private var saidIn: String?

    package init() {}

    /// The line to show now, or nil: while the budget is under its ceiling,
    /// and once it has been said in the budget's current day or month.
    package mutating func line(for owned: OwnedSpendBudget, rows: [SpendRow], now: Date,
                               calendar: Calendar) -> String? {
        let spentUSD = owned.spent(in: rows, now: now, calendar: calendar)
        guard let refusal = owned.refusal(spentUSD: spentUSD) else { return nil }
        let window = owned.budget.window(now: now, calendar: calendar)
        guard saidIn != window else { return nil }
        saidIn = window
        return "Over budget: \(refusal). Routines, triggers and autopilot runs that use this agent are "
            + "refused until the \(owned.budget.period.rawValue) turns over; your own messages still run."
    }
}
