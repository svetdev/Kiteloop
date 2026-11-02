import XCTest
import KiteloopCore
@testable import Kiteloop

/// `CoordinatorQueueRefill.answerFromSource` — the Planner reading one named
/// project's source for what the backlog cannot answer.
///
/// What is asserted here is every gate the answer has to pass on its way out,
/// and — as much as the gates — what each refusal *costs*: an unknown name, an
/// unwired window and a spent ceiling must each come back without a model call
/// having happened at all, since the whole reason this path is asked for by name
/// is that it is the expensive one.
@MainActor
final class CoordinatorQueueRefillRepoReadTests: XCTestCase {

    private var tempDir: URL!
    private var registry: ControlSessionRegistry!
    private var globalConfigStore: GlobalConfigStore!
    private var refill: CoordinatorQueueRefill!
    /// The one runtime every configured loop in a test hands out, so a test can
    /// read what the session was rooted at and how often one was started.
    private var runtime: StubHeadlessRuntime!

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "coordinator-repo-read")
        registry = ControlSessionRegistry()
        globalConfigStore = GlobalConfigStore(storageURL: tempDir.appending(path: "global.json"))
        refill = CoordinatorQueueRefill(ledgerURL: tempDir.appending(path: "refill.jsonl"))
        runtime = StubHeadlessRuntime(behavior: .events([]))
    }

    override func tearDown() async throws {
        refill?.stop()
        refill = nil
        registry = nil
        globalConfigStore = nil
        runtime = nil
    }

    // MARK: - Answering

    func testAnswersAQuestionAboutANamedProjectsSource() async throws {
        let root = try registerProject(named: "alpha")
        configure(reply: "Services/Foo.swift:12 still declares `Foo`. I read that file.")

        let outcome = await refill.answerFromSource(project: "alpha",
                                                    question: "does Foo still exist?")

        guard case .answered(let project, let answer, _) = outcome else {
            return XCTFail("expected an answer, got \(outcome)")
        }
        XCTAssertEqual(project, "alpha")
        XCTAssertEqual(answer.text, "Services/Foo.swift:12 still declares `Foo`. I read that file.")
        XCTAssertFalse(answer.wasCapped)
        XCTAssertEqual(runtime.startedCwds.count, 1, "exactly one read, for the one project named")
        XCTAssertEqual(runtime.startedCwds.first.map(Self.dirPath), root)
    }

    /// One project at a time, named explicitly — and the root read is the
    /// *resolved* entry's, not the string that was asked with.
    func testReadsOnlyTheNamedProjectWhenSeveralAreOpen() async throws {
        let alpha = try registerProject(named: "alpha")
        let beta = try registerProject(named: "beta")
        configure(reply: "read it")

        _ = await refill.answerFromSource(project: "beta", question: "q")

        XCTAssertEqual(runtime.startedCwds.map(Self.dirPath), [beta],
                       "alpha's files were never in scope")
        XCTAssertNotEqual(runtime.startedCwds.first.map(Self.dirPath), alpha)
    }

    /// The agent that does the reading carries the grant's tools and nothing
    /// else — asserted here as well as in `HeadlessAgentRunnerTests`, because
    /// this is the caller that actually hands one out in production.
    func testTheReadingAgentCanOnlyRead() async throws {
        _ = try registerProject(named: "alpha")
        configure(reply: "read it")

        _ = await refill.answerFromSource(project: "alpha", question: "q")

        let agent = try XCTUnwrap(runtime.startedAgents.first)
        XCTAssertEqual(agent.tools, RepoRead.allowedTools)
        XCTAssertTrue(Set(agent.tools).isDisjoint(with: RepoRead.forbiddenTools))
        XCTAssertTrue(RepoRead.forbiddenTools.isSubset(of: Set(agent.denied)))
    }

    /// The contract goes with the grant, so the refusal the tool-less Planner
    /// made correctly survives it gaining eyes.
    func testTheReadingAgentIsToldToSayWhenItHasNotLooked() async throws {
        _ = try registerProject(named: "alpha")
        configure(reply: "read it")

        _ = await refill.answerFromSource(project: "alpha", question: "q")

        let prompt = try XCTUnwrap(runtime.startedAgents.first?.systemPrompt)
        XCTAssertTrue(prompt.contains("If you did not read something, say you did not read it"))
        XCTAssertTrue(prompt.contains("cannot write a file, run a command, or reach the network"))
    }

    func testALongAnswerComesBackCappedAndSaysSo() async throws {
        _ = try registerProject(named: "alpha")
        configure(reply: String(repeating: "match at Services/Foo.swift ", count: 500))

        let outcome = await refill.answerFromSource(project: "alpha", question: "q")

        let answer = try XCTUnwrap(outcome.answer)
        XCTAssertTrue(answer.wasCapped)
        XCTAssertLessThanOrEqual(answer.text.count, RepoRead.answerCharacterLimit)
        XCTAssertTrue(outcome.message.contains(RepoRead.capNotice))
    }

    /// Silence is not a finding. A call that came back with nothing must not be
    /// reported as an answer — that is exactly the invention this path is
    /// written to avoid.
    func testAnEmptyReplyIsNotReportedAsAnAnswer() async throws {
        _ = try registerProject(named: "alpha")
        configure(reply: "   ")

        let outcome = await refill.answerFromSource(project: "alpha", question: "q")

        guard case .noAnswer = outcome else {
            return XCTFail("expected noAnswer, got \(outcome)")
        }
    }

    // MARK: - The budget

    func testReadingChargesTheDailyBudget() async throws {
        _ = try registerProject(named: "alpha")
        configure(reply: "read it", costUSD: 0.75)
        refill.setBudgetLimits(capUSD: .some(10))
        let before = refill.budget.spentUSD

        let outcome = await refill.answerFromSource(project: "alpha", question: "q")

        guard case .answered(_, _, let costUSD) = outcome else {
            return XCTFail("expected an answer, got \(outcome)")
        }
        XCTAssertEqual(costUSD, 0.75, accuracy: 0.0001)
        XCTAssertEqual(refill.budget.spentUSD, before + 0.75, accuracy: 0.0001,
                       "a read draws on the same pool grooming does")
    }

    /// The ceiling is read *before* the call, so an exhausted day costs nothing
    /// at all rather than one more read on top of the spend that exhausted it.
    func testAnExhaustedBudgetRefusesAndSpendsNothing() async throws {
        _ = try registerProject(named: "alpha")
        configure(reply: "read it", costUSD: 5)
        refill.setBudgetLimits(capUSD: .some(4))
        refill.recordSpend(4)

        let outcome = await refill.answerFromSource(project: "alpha", question: "q")

        guard case .budgetExhausted(let reason) = outcome else {
            return XCTFail("expected budgetExhausted, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("alpha"), "the refusal names what was not read")
        XCTAssertTrue(runtime.startedCwds.isEmpty, "nothing may be read once the ceiling is spent")
        XCTAssertEqual(refill.budget.spentUSD, 4, accuracy: 0.0001)
    }

    /// The portfolio's shared number is the ceiling when there is one — the same
    /// ceiling a grooming pass is bounded by, so a day spent reading is a day
    /// that has stopped grooming and vice versa.
    func testThePortfolioCeilingIsTheOneThatRefuses() async throws {
        _ = try registerProject(named: "alpha")
        configure(reply: "read it")
        globalConfigStore.setDailyBudgetUSD(2)
        refill.recordSpend(2)

        let outcome = await refill.answerFromSource(project: "alpha", question: "q")

        guard case .budgetExhausted = outcome else {
            return XCTFail("expected budgetExhausted, got \(outcome)")
        }
    }

    /// `maxPasses` bounds how often the *loop* wakes up to groom, which is no
    /// business of a question somebody asked. Only the money ceiling applies.
    func testThePassCeilingDoesNotRefuseARead() async throws {
        _ = try registerProject(named: "alpha")
        configure(reply: "read it")
        refill.setBudgetLimits(capUSD: .some(50), maxPasses: .some(1))
        for _ in 0..<5 { refill.recordSpend(0) }

        let outcome = await refill.answerFromSource(project: "alpha", question: "q")

        XCTAssertNotNil(outcome.answer, "a spent pass ceiling is not a reason to refuse a read")
    }

    /// Grooming off means the loop files nothing unattended; it does not mean
    /// the operator may not ask a question.
    func testAReadWorksWithGroomingSwitchedOff() async throws {
        _ = try registerProject(named: "alpha")
        configure(reply: "read it")
        XCTAssertFalse(refill.enabled, "Precondition: off is the shipped default")

        let outcome = await refill.answerFromSource(project: "alpha", question: "q")

        XCTAssertNotNil(outcome.answer)
    }

    // MARK: - Refusals

    /// A name that missed is a refusal naming the open projects, never the
    /// nearest one — substituting a project for the one that was asked about is
    /// the failure `ProjectInspection.resolve` exists to avoid, and this path
    /// inherits it rather than resolving names of its own.
    func testAnUnknownProjectIsRefusedAndNamesTheOpenOnes() async throws {
        _ = try registerProject(named: "alpha")
        configure(reply: "read it")

        let outcome = await refill.answerFromSource(project: "alfa", question: "q")

        guard case .unknownProject(let reason) = outcome else {
            return XCTFail("expected unknownProject, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("alfa"))
        XCTAssertTrue(reason.contains("alpha"), "the open ones are named — a near miss usually is one")
        XCTAssertTrue(runtime.startedCwds.isEmpty, "an unresolved name costs nothing")
    }

    func testAnUnwiredLoopSaysSoRatherThanReadingAnything() async throws {
        let outcome = await refill.answerFromSource(project: "alpha", question: "q")

        guard case .unavailable = outcome else {
            return XCTFail("expected unavailable, got \(outcome)")
        }
        XCTAssertTrue(runtime.startedCwds.isEmpty)
    }

    /// A read starts no pass and holds no flag, so it cannot wedge the loop the
    /// way a pass can — and cannot be blocked by one either.
    func testAReadStartsNoPass() async throws {
        _ = try registerProject(named: "alpha")
        configure(reply: "read it")

        _ = await refill.answerFromSource(project: "alpha", question: "q")

        XCTAssertFalse(refill.isPassing)
        XCTAssertNil(refill.lastOutcome, "a question is not a grooming pass and leaves no pass outcome")
    }

    // MARK: - Helpers

    private func configure(reply: String, costUSD: Double = 0) {
        runtime = StubHeadlessRuntime(behavior: .events([
            .result(.init(text: reply, costUSD: costUSD, durationMs: 0,
                          inputTokens: 0, outputTokens: 0,
                          cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                          sessionID: "stub-session", permissionDenials: []))
        ]))
        let runtime = runtime!
        refill.configure(registry: registry,
                         globalConfigStore: globalConfigStore,
                         runtimeFactory: { runtime })
    }

    @discardableResult
    /// A cwd's path with no trailing separator, so an assertion compares the
    /// directory rather than the `isDirectory` flag the URL happened to carry.
    /// `registerProject` hands back a path built with `isDirectory: false` while
    /// the runtime is given real directory URLs, so the two spell the same
    /// directory differently — which reddened both of these on 2026-08-21.
    private static func dirPath(_ url: URL) -> String {
        let p = url.path(percentEncoded: false)
        return p.count > 1 && p.hasSuffix("/") ? String(p.dropLast()) : p
    }

    private func registerProject(named name: String) throws -> String {
        let root = tempDir.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rootURL = URL(fileURLWithPath: root.path(percentEncoded: false), isDirectory: false)
        let project = KiteloopProject(rootURL: rootURL)
        try project.ensureDirectoryExists()

        let eventBus = EventBus(eventsURL: project.eventsURL)
        let orchestrator = Orchestrator(
            runtime: MockAgentRuntime(),
            eventBus: eventBus,
            subscriptionEngine: SubscriptionEngine(eventBus: eventBus),
            memoryManager: MemoryManager(project: project)
        )
        let session = ProjectSession(
            project: project,
            projectURL: rootURL,
            orchestrator: orchestrator,
            sessionStore: SessionStore(projectDir: rootURL),
            knowledgeStore: AgentKnowledgeStore(baseURL: project.knowledgeURL),
            knowledgeIndex: KnowledgeIndex(baseURL: project.knowledgeURL),
            context: ProjectSessionContext(
                runtimeFactory: { MockAgentRuntime() },
                agentCatalogStore: AgentCatalogStore(
                    storageURL: tempDir.appending(path: "catalog-\(name).json")),
                packageResolver: nil,
                globalConfigStore: globalConfigStore,
                orgManifestLoader: OrgManifestLoader(),
                repoCloneService: RepoCloneService()
            )
        )
        registry.register(session: session, autopilot: BacklogAutopilot())
        return rootURL.path(percentEncoded: false)
    }
}
