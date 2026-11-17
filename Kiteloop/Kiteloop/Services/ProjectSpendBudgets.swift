import Foundation
import KiteloopCore

/// The day or month budgets unattended work in one project answers to beyond
/// the daily ones: the project's own, then each of the agents the work would
/// use that carries one. Read against the spend ledger by the one decision
/// routines' budgets share (`OwnedSpendBudget`).
struct ProjectSpendBudgets {
    let budgets: [OwnedSpendBudget]

    init(project: KiteloopProject, agents: [Agent]) {
        budgets = [Self.owned(project)].compactMap { $0 } + agents.compactMap { Self.owned($0) }
    }

    /// The project's budget with the project as its owner; nil without one.
    /// Read from the project's settings on disk unless `config` is given.
    static func owned(_ project: KiteloopProject, config: ProjectConfig? = nil) -> OwnedSpendBudget? {
        (config ?? project.loadConfig()).budget.map {
            OwnedSpendBudget(owner: .project(path: project.rootURL.path(percentEncoded: false),
                                             name: project.rootURL.lastPathComponent), budget: $0)
        }
    }

    /// The agent's budget with the agent as its owner; nil without one.
    static func owned(_ agent: Agent) -> OwnedSpendBudget? {
        agent.budget.map { OwnedSpendBudget(owner: .agent(id: agent.id, name: agent.name), budget: $0) }
    }

    /// Why one of the budgets refuses unattended work now; nil when none
    /// does. The ledger is read only when there is a budget to read it
    /// against, and no ledger is no ceiling.
    func refusal(ledger: SpendLedger?, now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard !budgets.isEmpty, let ledger else { return nil }
        return OwnedSpendBudget.refusal(among: budgets, rows: ledger.rows(), now: now, calendar: calendar)
    }
}

extension KiteloopControlServer {

    /// Each budget as the API reports it, in the order given: its fields,
    /// what its owner spent in the current window and where that leaves it.
    /// With no budget the ledger is not read; with no ledger nothing is known
    /// to have been spent.
    func budgetReadings(_ budgets: [OwnedSpendBudget], now: Date = Date(),
                        calendar: Calendar = .current) async -> [[String: Any]] {
        guard !budgets.isEmpty else { return [] }
        let ledger = spendLedger
        // Off the main actor: the ledger is a file read end to end.
        let rows = await Task.detached { ledger?.rows() ?? [] }.value
        return budgets.map { $0.reading(in: rows, now: now, calendar: calendar) }
    }

    /// Why the project's budget, or the budget of the agent a routine is
    /// aimed at, refuses an autonomous firing; nil when neither does.
    func spendBudgetRefusal(for target: RoutineAgent, ledger: SpendLedger) -> String? {
        guard let entry = registry.entry(forProject: target.folder.path(percentEncoded: false)) else { return nil }
        let agents = entry.session.orchestrator.agents.filter { $0.id == target.agentID }
        return ProjectSpendBudgets(project: entry.session.project, agents: agents).refusal(ledger: ledger)
    }
}
