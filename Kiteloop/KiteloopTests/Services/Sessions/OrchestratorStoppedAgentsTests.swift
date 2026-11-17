import XCTest
import KiteloopCore
import KiteloopTestSupport
@testable import Kiteloop

/// An agent the person stopped: what is recorded, what forgets it, who is
/// refused, and what starts it again. The decision itself is
/// `StoppedAgentsTests` in the core; these are the orchestrator's paths to it.
@MainActor
final class OrchestratorStoppedAgentsTests: XCTestCase {

    private func makeOrchestrator(runtime: MockAgentRuntime = MockAgentRuntime()) -> Orchestrator {
        let orchestrator = Orchestrator(runtime: runtime)
        for name in ["Builder", "Critic"] {
            orchestrator.addAgent(Agent(id: name.lowercased(), name: name, model: "sonnet", systemPrompt: "",
                                        tools: [], denied: [], permissionMode: "default", state: .idle))
        }
        return orchestrator
    }

    func testThePersonsStopIsRecordedAndAStartForgetsIt() async throws {
        let root = try makeTemporaryDirectory(prefix: "stopped-agents")
        let orchestrator = makeOrchestrator()
        try await orchestrator.startAgent("builder", cwd: root)

        orchestrator.stopAgentForPerson("builder")

        XCTAssertFalse(orchestrator.hasSession(for: "builder"))
        XCTAssertTrue(orchestrator.isStoppedByPerson("builder"))

        try await orchestrator.startAgent("builder", cwd: root)

        XCTAssertFalse(orchestrator.isStoppedByPerson("builder"))
    }

    func testAStopTheAppMakesItselfIsNotThePersons() async throws {
        let root = try makeTemporaryDirectory(prefix: "stopped-agents")
        let orchestrator = makeOrchestrator()
        try await orchestrator.startAgent("builder", cwd: root)

        orchestrator.stopAgent("builder")

        XCTAssertFalse(orchestrator.isStoppedByPerson("builder"))
        XCTAssertNil(orchestrator.teammateRefusal(sendingTo: "builder"))
    }

    func testATeammateIsToldThePersonStoppedTheAgent() async throws {
        let root = try makeTemporaryDirectory(prefix: "stopped-agents")
        let orchestrator = makeOrchestrator()
        try await orchestrator.startAgent("critic", cwd: root)
        XCTAssertNil(orchestrator.teammateRefusal(sendingTo: "critic"), "a running agent is sent to")

        orchestrator.stopAgentForPerson("critic")

        let refusal = try XCTUnwrap(orchestrator.teammateRefusal(sendingTo: "critic"))
        XCTAssertTrue(refusal.hasPrefix("Critic was stopped by the person"), refusal)
        XCTAssertFalse(orchestrator.hasSession(for: "critic"), "asking starts nothing")
    }

    func testADebateWithAStoppedCriticSaysSoAndSendsNothing() async throws {
        let root = try makeTemporaryDirectory(prefix: "stopped-agents")
        let runtime = MockAgentRuntime()
        let orchestrator = makeOrchestrator(runtime: runtime)
        try await orchestrator.startAgent("builder", cwd: root)
        orchestrator.stopAgentForPerson("critic")

        let result = await DebateOrchestrator(orchestrator: orchestrator, projectURL: root)
            .run(contract: DebateContract(topic: "t", proposer: "Builder", critic: "Critic", maxRounds: 2,
                                          artifactFields: [], groundingCommand: nil))

        XCTAssertEqual(result.rounds, 0)
        XCTAssertEqual(result.terminated, .error)
        XCTAssertTrue(result.finalArtifact.hasPrefix("Critic was stopped by the person"), result.finalArtifact)
        XCTAssertTrue(runtime.sentMessages.isEmpty)
        XCTAssertFalse(orchestrator.hasSession(for: "critic"))
    }

    func testTheStopOutlivesARelaunch() async throws {
        let root = try makeTemporaryDirectory(prefix: "stopped-agents")
        let file = KiteloopProject(rootURL: root).stoppedAgentsURL
        let first = makeOrchestrator()
        XCTAssertNil(first.loadStoppedAgents(from: file))
        first.stopAgentForPerson("builder")

        let relaunched = makeOrchestrator()
        XCTAssertNil(relaunched.loadStoppedAgents(from: file))

        XCTAssertTrue(relaunched.isStoppedByPerson("builder"))
        XCTAssertFalse(relaunched.isStoppedByPerson("critic"))

        try await relaunched.startAgent("builder", cwd: root)
        let afterStart = makeOrchestrator()
        XCTAssertNil(afterStart.loadStoppedAgents(from: file))
        XCTAssertFalse(afterStart.isStoppedByPerson("builder"), "the start was written too")
    }

    func testARunStartsItsStoppedAgents() async throws {
        let root = try makeTemporaryDirectory(prefix: "stopped-agents")
        let orchestrator = makeOrchestrator()
        orchestrator.stopAgentForPerson("builder")

        let failure = await orchestrator.startSessionsIfMissing(for: ["builder", "critic"], cwd: root)

        XCTAssertNil(failure)
        XCTAssertTrue(orchestrator.hasSession(for: "builder"))
        XCTAssertTrue(orchestrator.hasSession(for: "critic"))
        XCTAssertFalse(orchestrator.isStoppedByPerson("builder"))
    }

    func testARunSaysWhichAgentCouldNotBeStarted() async throws {
        let root = try makeTemporaryDirectory(prefix: "stopped-agents")
        let runtime = MockAgentRuntime()
        runtime.startSessionError = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "no claude"])
        let orchestrator = makeOrchestrator(runtime: runtime)

        let failure = await orchestrator.startSessionsIfMissing(for: ["builder"], cwd: root)
        let stranger = await makeOrchestrator().startSessionsIfMissing(for: ["nobody"], cwd: root)

        XCTAssertEqual(failure, "Builder has no session and could not be started: no claude")
        XCTAssertEqual(stranger, "nobody has no session and is not an agent on this team")
    }

    func testAnEventOrWorkflowNodeReopensAStoppedAgentsChatAndIsDelivered() async throws {
        let orchestrator = makeOrchestrator()
        var reopened: [String] = []
        orchestrator.personStops.openChat = { reopened.append($0) }
        let delivered = expectation(forNotification: .agentTriggered, object: orchestrator)
        delivered.expectedFulfillmentCount = 1

        orchestrator.triggerAgent(agentID: "critic", message: "never started: dropped, as before")
        orchestrator.stopAgentForPerson("builder")
        orchestrator.triggerAgent(agentID: "builder", message: "go")

        await fulfillment(of: [delivered], timeout: 5)
        XCTAssertEqual(reopened, ["builder"])
    }
}
