import KiteloopCore
import XCTest
@testable import Kiteloop

/// The budgets a project's unattended work answers to — the project's own and
/// each agent's — read from the project's settings and its team, and how an
/// agent's budget is edited and kept in the team file.
final class ProjectSpendBudgetsTests: XCTestCase {

    private var tempDir: URL!
    private var project: KiteloopProject!
    private var ledger: SpendLedger!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "project-spend-budgets")
        project = KiteloopProject(rootURL: tempDir.appendingPathComponent("vault"))
        try project.ensureDirectoryExists()
        ledger = SpendLedger(url: tempDir.appendingPathComponent("spend-ledger.jsonl"))
    }

    private var path: String { project.rootURL.path(percentEncoded: false) }

    private func agent(_ name: String, budget: SpendBudget? = nil) -> Agent {
        var agent = Agent(name: name, model: "sonnet", systemPrompt: "", tools: [], denied: [],
                          permissionMode: "acceptEdits")
        agent.budget = budget
        return agent
    }

    private func daily(_ ceiling: Double) -> SpendBudget {
        SpendBudget(ceilingUSD: ceiling, period: .day, consequence: .refuse)
    }

    private func setProjectBudget(_ budget: SpendBudget?) throws {
        var config = project.loadConfig()
        config.budget = budget
        try project.saveConfig(config)
    }

    private func spend(_ cost: Double, agent: String?, source: SpendRow.Source = .chat) {
        ledger.append(SpendRow(at: Date(), source: source, project: path, agent: agent, costUSD: cost, basis: .usd))
    }

    // MARK: - Which budgets

    func testAProjectAndAgentsWithNoBudgetAnswerToNone() {
        let budgets = ProjectSpendBudgets(project: project, agents: [agent("Dev")])

        XCTAssertEqual(budgets.budgets, [])
        XCTAssertNil(budgets.refusal(ledger: ledger))
    }

    func testTheProjectsBudgetComesFirstThenEachAgentThatCarriesOne() throws {
        try setProjectBudget(daily(20))
        let dev = agent("Dev", budget: daily(5))

        let budgets = ProjectSpendBudgets(project: project, agents: [agent("Quiet"), dev]).budgets

        XCTAssertEqual(budgets, [
            OwnedSpendBudget(owner: .project(path: path, name: "vault"), budget: daily(20)),
            OwnedSpendBudget(owner: .agent(id: dev.id, name: "Dev"), budget: daily(5))
        ])
    }

    // MARK: - The refusal

    func testAnAgentAtItsBudgetRefusesAndOneUnderItDoesNot() {
        let dev = agent("Dev", budget: daily(5))
        let budgets = ProjectSpendBudgets(project: project, agents: [dev])

        spend(4.99, agent: dev.id)
        XCTAssertNil(budgets.refusal(ledger: ledger))

        spend(0.01, agent: dev.id, source: .autopilot)
        XCTAssertEqual(budgets.refusal(ledger: ledger),
                       "Dev's agent budget $5.00 per day exhausted ($5.00 spent today)")
    }

    func testTheProjectsBudgetCountsEveryAgentAndTheRowsWithNone() throws {
        try setProjectBudget(daily(10))
        let dev = agent("Dev", budget: daily(100))
        spend(4, agent: dev.id)
        spend(3, agent: "someone-else", source: .routine)
        spend(3, agent: nil, source: .planner)

        let refusal = ProjectSpendBudgets(project: project, agents: [dev]).refusal(ledger: ledger)

        XCTAssertEqual(refusal, "vault's project budget $10.00 per day exhausted ($10.00 spent today)")
    }

    func testNoLedgerIsNoCeiling() {
        let budgets = ProjectSpendBudgets(project: project, agents: [agent("Dev", budget: daily(1))])

        XCTAssertNil(budgets.refusal(ledger: nil))
    }

    // MARK: - Editing an agent's budget

    func testAnEditSetsKeepsAndClearsAnAgentsBudget() throws {
        var dev = agent("Dev")

        try AgentEdit.parse(["budget": ["ceilingUSD": 40, "period": "month"]]).get().apply(to: &dev)
        XCTAssertEqual(dev.budget, SpendBudget(ceilingUSD: 40, period: .month, consequence: .refuse))

        try AgentEdit.parse(["model": "opus"]).get().apply(to: &dev)
        XCTAssertEqual(dev.budget?.ceilingUSD, 40, "an edit that does not name the budget keeps it")

        try AgentEdit.parse(["budget": NSNull()]).get().apply(to: &dev)
        XCTAssertNil(dev.budget)
    }

    func testABudgetAloneIsAnEditAndReachesTheSessionAtOnce() throws {
        let dev = agent("Dev")
        let edit = try AgentEdit.parse(["budget": ["ceilingUSD": 5]]).get()

        XCTAssertFalse(edit.changesSpawnValues(of: dev), "nothing the CLI process reads at spawn")
    }

    func testABudgetThatCannotBeKeptIsRefusedByName() {
        let cases: [(body: [String: Any], reason: String)] = [
            (["budget": 5], "\"budget\" is an object, or null to clear it"),
            (["budget": ["ceilingUSD": 0]], "\"budget.ceilingUSD\" is above zero"),
            (["budget": ["ceilingUSD": 5, "consequence": "pause"]],
             "\"budget.consequence\" \"pause\" is not yet available for agents: an agent's budget takes \"refuse\"")
        ]
        for testCase in cases {
            XCTAssertEqual(AgentEdit.parse(testCase.body), .failure(.init(reason: testCase.reason)))
        }
    }

    // MARK: - In the team file

    func testAnAgentsBudgetSurvivesTheTeamFile() throws {
        let dev = agent("Dev", budget: daily(5))

        let data = try JSONEncoder().encode([AgentTemplate(from: dev), AgentTemplate(from: agent("Quiet"))])
        let read = try JSONDecoder().decode([AgentTemplate].self, from: data).map { $0.instantiateAgentWithFixedID() }

        XCTAssertEqual(read.map(\.budget), [daily(5), nil])
        XCTAssertEqual(read.first?.id, dev.id, "the id the ledger's rows are filed under")
    }

    func testATeamFileWithABudgetThatDoesNotParseStillLoads() throws {
        let data = Data(#"[{"name":"Dev","budget":{"ceilingUSD":"lots"}}]"#.utf8)

        let read = try JSONDecoder().decode([AgentTemplate].self, from: data)

        XCTAssertEqual(read.map(\.name), ["Dev"])
        XCTAssertNil(read.first?.budget)
    }
}

/// An autopilot's start against the project's and the staffed agents' own
/// budgets: autonomy stops at them, a person's own run does not.
@MainActor
final class AutopilotSpendBudgetStartTests: XCTestCase {

    private var root: URL!
    private var ledger: SpendLedger!
    private var orchestrator: Orchestrator!
    private var autopilot: BacklogAutopilot!

    override func setUp() async throws {
        root = try makeTemporaryDirectory(prefix: "autopilot-spend-budget")
        try KiteloopProject(rootURL: root).ensureDirectoryExists()
        ledger = SpendLedger(url: root.appendingPathComponent("spend-ledger.jsonl"))
        orchestrator = Orchestrator(runtime: MockAgentRuntime())
        autopilot = BacklogAutopilot()
        autopilot.configure(
            orchestrator: orchestrator,
            backlogViewModel: BacklogViewModel(
                globalConfigStore: GlobalConfigStore(storageURL: root.appendingPathComponent("global-config.json"))),
            configURL: root.appendingPathComponent("autopilot-config.json"),
            projectPath: root.path(percentEncoded: false),
            dailySpendLedger: DailySpendLedger(storageURL: root.appendingPathComponent("daily-spend.json"),
                                               spendLedger: ledger))
    }

    private func hire(_ name: String, ceiling: Double?) -> String {
        var agent = Agent(name: name, model: "sonnet", systemPrompt: "", tools: [], denied: [],
                          permissionMode: "acceptEdits")
        agent.budget = ceiling.map { SpendBudget(ceilingUSD: $0, period: .day, consequence: .refuse) }
        orchestrator.addAgent(agent)
        return agent.id
    }

    private func spend(_ cost: Double, agent: String) {
        ledger.append(SpendRow(at: Date(), source: .autopilot, project: root.path(percentEncoded: false),
                               agent: agent, costUSD: cost, basis: .usd))
    }

    func testAnAutonomousStartIsRefusedWhenTheWorkerIsAtItsBudget() async {
        let worker = hire("Builder", ceiling: 5)
        autopilot.workerAgentID = worker
        spend(5, agent: worker)

        await autopilot.start(initiator: .autonomous)

        XCTAssertEqual(autopilot.lastStartOutcome?.refusal, .spendBudget)
        XCTAssertTrue(autopilot.lastStartOutcome?.detail.contains("Builder's agent budget $5.00 per day exhausted") == true)
        XCTAssertEqual(autopilot.status, .idle)
    }

    func testTheReviewersBudgetRefusesTheRunToo() async {
        autopilot.workerAgentID = hire("Builder", ceiling: nil)
        let reviewer = hire("Critic", ceiling: 1)
        autopilot.reviewerAgentID = reviewer
        spend(2, agent: reviewer)

        await autopilot.start(initiator: .autonomous)

        XCTAssertEqual(autopilot.lastStartOutcome?.refusal, .spendBudget)
        XCTAssertTrue(autopilot.lastStartOutcome?.detail.contains("Critic's agent budget") == true)
    }

    func testAnAgentTheRunDoesNotUseRefusesNothing() {
        autopilot.workerAgentID = hire("Builder", ceiling: nil)
        let bystander = hire("Writer", ceiling: 1)
        spend(2, agent: bystander)

        XCTAssertNil(autopilot.spendBudgetRefusal)
    }

    func testTheProjectsBudgetRefusesAnAutonomousStart() async throws {
        let worker = hire("Builder", ceiling: nil)
        autopilot.workerAgentID = worker
        let project = KiteloopProject(rootURL: root)
        var config = project.loadConfig()
        config.budget = SpendBudget(ceilingUSD: 3, period: .month, consequence: .refuse)
        try project.saveConfig(config)
        spend(3, agent: worker)

        await autopilot.start(initiator: .autonomous)

        XCTAssertEqual(autopilot.lastStartOutcome?.refusal, .spendBudget)
        XCTAssertTrue(autopilot.lastStartOutcome?.detail.contains("project budget $3.00 per month exhausted") == true)
    }

    func testARunAPersonStartsIsNotRefusedByASpentBudget() async {
        let worker = hire("Builder", ceiling: 5)
        autopilot.workerAgentID = worker
        spend(50, agent: worker)

        await autopilot.start()

        XCTAssertNotEqual(autopilot.lastStartOutcome?.refusal, .spendBudget,
                          "it goes on to whichever gate would ordinarily refuse it next")
    }
}
