import XCTest
import KiteloopCore
@testable import Kiteloop

/// `GET /v1/memory/proposals` — the read `MemoryManager.pendingProposals()` had
/// no headless equivalent for, so a proposal filed by an agent or the librarian
/// pass during an unattended run sat invisible until someone opened the Memory
/// tab. Over a real loopback socket and a real `MemoryManager`, the same one
/// `ProjectSession` wires the Memory tab to.
@MainActor
final class KiteloopControlServerMemoryProposalsTests: XCTestCase {

    private var tempDir: URL!
    private var registry: ControlSessionRegistry!
    private var harness: ControlServerHarness!
    private let token = "control-memory-proposals-token-" + UUID().uuidString

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "control-memory-proposals")
        registry = ControlSessionRegistry()
        harness = try await ControlServerHarness.start(registry: registry, token: token)
    }

    override func tearDown() async throws {
        harness?.stop()
        harness = nil
        registry = nil
    }

    // MARK: - Pending proposals are reported

    func testAnAddProposalIsReportedWithItsFields() async throws {
        let orchestrator = try registerProject(named: "alpha")
        let proposal = try await orchestrator.memoryManager.proposeUpdate(
            agentID: "builder", content: "The build script lives at scripts/make-release.sh.")

        let (status, body) = try await harness.get("/v1/memory/proposals?project=alpha")

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["project"] as? String, "alpha")
        XCTAssertEqual(body["count"] as? Int, 1)
        let proposals = try XCTUnwrap(body["proposals"] as? [[String: Any]])
        let reported = try XCTUnwrap(proposals.first)
        XCTAssertEqual(reported["id"] as? String, proposal.id)
        XCTAssertEqual(reported["agent"] as? String, "builder")
        XCTAssertEqual(reported["status"] as? String, "pending")
        XCTAssertEqual(reported["source"] as? String, "agent")
        XCTAssertEqual(reported["operation"] as? String, "add")
        XCTAssertNil(reported["topics"], "add acts on no named facts")
        XCTAssertEqual(reported["content"] as? String, "The build script lives at scripts/make-release.sh.")
        XCTAssertNotNil(reported["timestamp"] as? String)
    }

    /// The librarian's shapes — merge, delete, archive — carry the topic names
    /// they act on, and delete carries the evidence a human needs before
    /// pressing an irreversible removal.
    func testALibrarianDeleteProposalCarriesItsTopicAndEvidence() async throws {
        let orchestrator = try registerProject(named: "alpha")
        try await orchestrator.memoryManager.file(MemoryProposal(
            agentID: "librarian",
            proposedContent: "The old deploy path no longer exists.",
            operation: .delete(topic: "legacy-deploy-path"),
            source: .librarian,
            rationale: "Contradicted by the current deploy script.",
            evidence: "scripts/make-release.sh no longer references it."
        ))

        let (_, body) = try await harness.get("/v1/memory/proposals?project=alpha")

        let reported = try XCTUnwrap((body["proposals"] as? [[String: Any]])?.first)
        XCTAssertEqual(reported["source"] as? String, "librarian")
        XCTAssertEqual(reported["operation"] as? String, "delete")
        XCTAssertEqual(reported["topics"] as? [String], ["legacy-deploy-path"])
        XCTAssertEqual(reported["rationale"] as? String, "Contradicted by the current deploy script.")
        XCTAssertEqual(reported["evidence"] as? String, "scripts/make-release.sh no longer references it.")
    }

    /// A merge names every topic it replaces, not just one.
    func testAMergeProposalCarriesEveryTopicItReplaces() async throws {
        let orchestrator = try registerProject(named: "alpha")
        try await orchestrator.memoryManager.file(MemoryProposal(
            agentID: "librarian",
            proposedContent: "Merged summary of two duplicate facts.",
            operation: .merge(topics: ["fact-a", "fact-b"]),
            source: .librarian
        ))

        let (_, body) = try await harness.get("/v1/memory/proposals?project=alpha")

        let reported = try XCTUnwrap((body["proposals"] as? [[String: Any]])?.first)
        XCTAssertEqual(reported["operation"] as? String, "merge")
        XCTAssertEqual(reported["topics"] as? [String], ["fact-a", "fact-b"])
    }

    /// A proposal that has already been resolved is not pending, and must not
    /// appear — the endpoint reports exactly what `pendingProposals()` does.
    func testAnApprovedProposalIsNotReported() async throws {
        let orchestrator = try registerProject(named: "alpha")
        let approved = try await orchestrator.memoryManager.proposeUpdate(agentID: "builder", content: "Approved fact.")
        _ = try await orchestrator.memoryManager.proposeUpdate(agentID: "builder", content: "Still pending fact.")
        try await orchestrator.memoryManager.approve(proposalID: approved.id)

        let (status, body) = try await harness.get("/v1/memory/proposals?project=alpha")

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["count"] as? Int, 1)
        let proposals = try XCTUnwrap(body["proposals"] as? [[String: Any]])
        XCTAssertEqual(proposals.map { $0["content"] as? String }, ["Still pending fact."])
    }

    func testAProjectWithNoProposalsReturnsAnEmptyListRatherThanAnError() async throws {
        try registerProject(named: "alpha")

        let (status, body) = try await harness.get("/v1/memory/proposals?project=alpha")

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["count"] as? Int, 0)
        let proposals = try XCTUnwrap(body["proposals"] as? [[String: Any]])
        XCTAssertTrue(proposals.isEmpty)
    }

    // MARK: - Answering a proposal

    /// Approving over the API is the Memory tab's button pressed remotely: the
    /// operation is applied, so the fact is in the agent's index *on disk* — not
    /// merely marked approved in this process — and the proposal stops being
    /// pending.
    func testApprovingAPendingProposalWritesTheFactToTheIndexOnDisk() async throws {
        let orchestrator = try registerProject(named: "alpha")
        let proposal = try await orchestrator.memoryManager.proposeUpdate(
            agentID: "builder", content: "The release script lives at scripts/make-release.sh.")

        let (status, body) = try await harness.post(
            "/v1/memory/proposals/approve", ["project": "alpha", "id": proposal.id])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["id"] as? String, proposal.id)
        XCTAssertEqual(body["agent"] as? String, "builder")
        XCTAssertEqual(body["operation"] as? String, "add")
        XCTAssertEqual(body["status"] as? String, "approved")
        XCTAssertEqual(indexHeadlines(project: "alpha", agentID: "builder"),
                       ["The release script lives at scripts/make-release.sh."],
                       "approving has to apply the operation, not just mark the proposal")
        let pending = await orchestrator.memoryManager.pendingProposals()
        XCTAssertTrue(pending.isEmpty)
    }

    /// `MemoryManager.approve` returns silently for an id it does not hold, so a
    /// second approve would otherwise read as a write that happened. Answering
    /// the *pending* set is what makes the repeat a 404 — and the index still
    /// carries one fact, not two.
    func testApprovingTheSameProposalTwiceIs404RatherThanASecondWrite() async throws {
        let orchestrator = try registerProject(named: "alpha")
        let proposal = try await orchestrator.memoryManager.proposeUpdate(
            agentID: "builder", content: "The release script lives at scripts/make-release.sh.")
        let payload: [String: Any] = ["project": "alpha", "id": proposal.id]

        let (first, _) = try await harness.post("/v1/memory/proposals/approve", payload)
        let (second, body) = try await harness.post("/v1/memory/proposals/approve", payload)

        XCTAssertEqual(first, 200)
        XCTAssertEqual(second, 404)
        XCTAssertEqual(body["error"] as? String, "No pending memory proposal '\(proposal.id)' in this project")
        XCTAssertEqual(indexHeadlines(project: "alpha", agentID: "builder").count, 1)
    }

    /// A refusal stays a refusal. The index turns away a fact it already covers,
    /// and `approve` rethrows having written nothing — so the answer carries the
    /// reason rather than a 200, and the proposal is still pending for a human to
    /// edit, exactly what `MemoryViewModel.lastWriteError` says in the UI.
    func testAProposalTheIndexRefusesIsNotA200AndStaysPending() async throws {
        let orchestrator = try registerProject(named: "alpha")
        let fact = "The release script lives at scripts/make-release.sh."
        let first = try await orchestrator.memoryManager.proposeUpdate(agentID: "builder", content: fact)
        let duplicate = try await orchestrator.memoryManager.proposeUpdate(agentID: "builder", content: fact)
        let (accepted, _) = try await harness.post(
            "/v1/memory/proposals/approve", ["project": "alpha", "id": first.id])
        XCTAssertEqual(accepted, 200)

        let (status, body) = try await harness.post(
            "/v1/memory/proposals/approve", ["project": "alpha", "id": duplicate.id])

        XCTAssertGreaterThanOrEqual(status, 400, "a refused write must not answer 2xx")
        XCTAssertEqual(status, 422)
        let reason = try XCTUnwrap(body["error"] as? String)
        XCTAssertTrue(reason.contains("already covered"), "the refusal's own reason has to reach the caller: \(reason)")

        let (_, list) = try await harness.get("/v1/memory/proposals?project=alpha")
        let stillPending = try XCTUnwrap(list["proposals"] as? [[String: Any]])
        XCTAssertEqual(stillPending.map { $0["id"] as? String }, [duplicate.id],
                       "a refused approval leaves the proposal pending")
        XCTAssertEqual(indexHeadlines(project: "alpha", agentID: "builder"), [fact])
    }

    func testRejectingAPendingProposalRemovesItWithoutTouchingTheIndex() async throws {
        let orchestrator = try registerProject(named: "alpha")
        let proposal = try await orchestrator.memoryManager.proposeUpdate(
            agentID: "builder", content: "A fact nobody wants recorded.")

        let (status, body) = try await harness.post(
            "/v1/memory/proposals/reject", ["project": "alpha", "id": proposal.id])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["id"] as? String, proposal.id)
        XCTAssertEqual(body["status"] as? String, "rejected")
        let (_, list) = try await harness.get("/v1/memory/proposals?project=alpha")
        XCTAssertEqual(list["count"] as? Int, 0)
        XCTAssertTrue(indexHeadlines(project: "alpha", agentID: "builder").isEmpty,
                      "rejecting writes no fact")
    }

    func testRejectingTheSameProposalTwiceIs404() async throws {
        let orchestrator = try registerProject(named: "alpha")
        let proposal = try await orchestrator.memoryManager.proposeUpdate(agentID: "builder", content: "A fact.")
        let payload: [String: Any] = ["project": "alpha", "id": proposal.id]

        let (first, _) = try await harness.post("/v1/memory/proposals/reject", payload)
        let (second, _) = try await harness.post("/v1/memory/proposals/reject", payload)

        XCTAssertEqual(first, 200)
        XCTAssertEqual(second, 404)
    }

    /// A librarian's delete is applied the same way an add is — the fact and its
    /// body go, and the reported `operation` says which button was pressed.
    func testApprovingALibrarianDeleteRemovesTheFact() async throws {
        let orchestrator = try registerProject(named: "alpha")
        let added = try await orchestrator.memoryManager.proposeUpdate(
            agentID: "builder", content: "The old deploy path is /usr/local/deploy.")
        _ = try await harness.post("/v1/memory/proposals/approve", ["project": "alpha", "id": added.id])
        let topic = try XCTUnwrap(indexTopics(project: "alpha", agentID: "builder").first)
        let deletion = try await orchestrator.memoryManager.file(MemoryProposal(
            agentID: "builder",
            proposedContent: "The old deploy path no longer exists.",
            operation: .delete(topic: topic),
            source: .librarian,
            evidence: "scripts/make-release.sh no longer references it."
        ))

        let (status, body) = try await harness.post(
            "/v1/memory/proposals/approve", ["project": "alpha", "id": deletion.id])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["operation"] as? String, "delete")
        XCTAssertTrue(indexHeadlines(project: "alpha", agentID: "builder").isEmpty)
    }

    // MARK: - Errors

    func testAnIdMatchingNoProposalIs404() async throws {
        try registerProject(named: "alpha")

        for path in ["/v1/memory/proposals/approve", "/v1/memory/proposals/reject"] {
            let (status, body) = try await harness.post(path, ["project": "alpha", "id": "no-such-id"])
            XCTAssertEqual(status, 404, path)
            XCTAssertEqual(body["error"] as? String, "No pending memory proposal 'no-such-id' in this project", path)
        }
    }

    /// Refused exactly as the list endpoint refuses it, so a driver reads one
    /// answer for an unopened project whichever memory call it makes.
    func testAnsweringInAnUnknownProjectIs409() async throws {
        try registerProject(named: "alpha")

        for path in ["/v1/memory/proposals/approve", "/v1/memory/proposals/reject"] {
            let (status, body) = try await harness.post(path, ["project": "beta", "id": "any"])
            XCTAssertEqual(status, 409, path)
            XCTAssertEqual(body["error"] as? String, "Project not open in Kiteloop: beta", path)
        }
    }

    func testAnsweringWithoutProjectOrIdIs400() async throws {
        try registerProject(named: "alpha")

        for path in ["/v1/memory/proposals/approve", "/v1/memory/proposals/reject"] {
            let (missingID, body) = try await harness.post(path, ["project": "alpha"])
            XCTAssertEqual(missingID, 400, path)
            XCTAssertEqual(body["error"] as? String, "Body must include \"project\" and \"id\"", path)
            let (missingProject, _) = try await harness.post(path, ["id": "any"])
            XCTAssertEqual(missingProject, 400, path)
        }
    }

    func testAnsweringRequiresBearerToken() async throws {
        let orchestrator = try registerProject(named: "alpha")
        let proposal = try await orchestrator.memoryManager.proposeUpdate(agentID: "builder", content: "A fact.")

        let (status, body) = try await harness.post(
            "/v1/memory/proposals/approve", ["project": "alpha", "id": proposal.id], bearer: nil)

        XCTAssertEqual(status, 401)
        XCTAssertEqual(body["error"] as? String, "Missing or invalid bearer token")
        let pending = await orchestrator.memoryManager.pendingProposals()
        XCTAssertEqual(pending.map(\.id), [proposal.id],
                       "an unauthenticated caller answers nothing")
        XCTAssertTrue(indexHeadlines(project: "alpha", agentID: "builder").isEmpty)
    }

    func testMissingProjectIs400() async throws {
        let (status, body) = try await harness.get("/v1/memory/proposals")

        XCTAssertEqual(status, 400)
        XCTAssertEqual(body["error"] as? String, "Missing ?project=")
    }

    func testUnknownProjectIs409() async throws {
        try registerProject(named: "alpha")

        let (status, body) = try await harness.get("/v1/memory/proposals?project=beta")

        XCTAssertEqual(status, 409)
        XCTAssertEqual(body["error"] as? String, "Project not open in Kiteloop: beta")
    }

    func testRequiresBearerToken() async throws {
        let orchestrator = try registerProject(named: "alpha")
        _ = try await orchestrator.memoryManager.proposeUpdate(agentID: "builder", content: "Secret fact.")

        let (status, body) = try await harness.get("/v1/memory/proposals?project=alpha", bearer: nil)

        XCTAssertEqual(status, 401)
        XCTAssertEqual(body["error"] as? String, "Missing or invalid bearer token")
        XCTAssertNil(body["proposals"], "an unauthenticated caller learns nothing about pending proposals")
    }

    // MARK: - Helpers

    /// Builds a real `ProjectSession` over a throwaway directory, backed by a
    /// real `MemoryManager` so proposals filed through it are exactly what
    /// `pendingProposals()` returns.
    @discardableResult
    private func registerProject(named name: String) throws -> Orchestrator {
        let root = tempDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rootURL = URL(fileURLWithPath: root.path(percentEncoded: false), isDirectory: false)
        let project = KiteloopProject(rootURL: rootURL)
        try project.ensureDirectoryExists()

        try "# \(name) Backlog\n\n## Now\n\n"
            .write(to: root.appending(path: "BACKLOG.md"), atomically: true, encoding: .utf8)

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
            context: makeContext()
        )
        registry.register(session: session, autopilot: BacklogAutopilot())
        return orchestrator
    }

    /// All stores are pointed at the temp directory so the tests never read or
    /// write the developer's real global config.
    private func makeContext() -> ProjectSessionContext {
        ProjectSessionContext(
            runtimeFactory: { MockAgentRuntime() },
            agentCatalogStore: AgentCatalogStore(storageURL: tempDir.appendingPathComponent("catalog.json")),
            packageResolver: nil,
            globalConfigStore: GlobalConfigStore(storageURL: tempDir.appendingPathComponent("global.json")),
            orgManifestLoader: OrgManifestLoader(),
            repoCloneService: RepoCloneService()
        )
    }

    /// The agent's memory index as it sits on disk — the file that rides into the
    /// system prompt. Read straight off the platter rather than through
    /// `MemoryManager`, since what the endpoint has to prove is that the write
    /// landed, not that this process believes it did.
    private func indexFacts(project: String, agentID: String) -> [AgentMemoryIndex.Fact] {
        let root = tempDir.appendingPathComponent(project, isDirectory: true)
        let url = KiteloopProject(rootURL: URL(fileURLWithPath: root.path(percentEncoded: false), isDirectory: false))
            .agentDir(for: agentID).appending(path: "memory.md")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return AgentMemoryIndex.parse(text)
    }

    private func indexHeadlines(project: String, agentID: String) -> [String] {
        indexFacts(project: project, agentID: agentID).map(\.headline)
    }

    private func indexTopics(project: String, agentID: String) -> [String] {
        indexFacts(project: project, agentID: agentID).map(\.topic)
    }
}
