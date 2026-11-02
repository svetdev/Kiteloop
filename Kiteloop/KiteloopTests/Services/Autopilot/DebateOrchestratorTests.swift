import XCTest
@testable import Kiteloop

/// A debate's round count is agent-supplied and unchecked: `DebateContract.maxRounds`
/// flows straight from a tool call's JSON. `1...maxRounds` traps on zero or negative,
/// so every read of the round count must go through the clamped accessor instead.
///
/// Its grounding command comes from the same place and is just as unchecked, so
/// it runs on a deadline: a command that never exits ends at the deadline, with
/// its descendants, and the debate carries on to the critic saying so.
final class DebateOrchestratorTests: XCTestCase {

    // MARK: - Clamping via the memberwise init

    func testZeroRoundsClampsToOne() {
        let contract = DebateContract(topic: "t", proposer: "p", critic: "c", maxRounds: 0)
        XCTAssertEqual(contract.clampedMaxRounds, 1)
    }

    func testNegativeRoundsClampsToOne() {
        let contract = DebateContract(topic: "t", proposer: "p", critic: "c", maxRounds: -5)
        XCTAssertEqual(contract.clampedMaxRounds, 1)
    }

    func testRoundsWithinRangeAreUnchanged() {
        let contract = DebateContract(topic: "t", proposer: "p", critic: "c", maxRounds: 3)
        XCTAssertEqual(contract.clampedMaxRounds, 3)
    }

    func testRoundsAboveCeilingClampToTheCeiling() {
        let contract = DebateContract(topic: "t", proposer: "p", critic: "c", maxRounds: 1_000_000)
        XCTAssertEqual(contract.clampedMaxRounds, DebateContract.roundRange.upperBound)
    }

    // MARK: - Clamping survives Codable decoding

    func testDecodedContractWithZeroRoundsClampsToOne() throws {
        let json = #"{"topic":"t","proposer":"p","critic":"c","maxRounds":0,"artifactFields":[]}"#
        let contract = try JSONDecoder().decode(DebateContract.self, from: Data(json.utf8))
        XCTAssertEqual(contract.clampedMaxRounds, 1)
    }

    func testDecodedContractWithNegativeRoundsClampsToOne() throws {
        let json = #"{"topic":"t","proposer":"p","critic":"c","maxRounds":-7,"artifactFields":[]}"#
        let contract = try JSONDecoder().decode(DebateContract.self, from: Data(json.utf8))
        XCTAssertEqual(contract.clampedMaxRounds, 1)
    }

    func testDecodedContractAboveCeilingClampsToTheCeiling() throws {
        let json = #"{"topic":"t","proposer":"p","critic":"c","maxRounds":999,"artifactFields":[]}"#
        let contract = try JSONDecoder().decode(DebateContract.self, from: Data(json.utf8))
        XCTAssertEqual(contract.clampedMaxRounds, DebateContract.roundRange.upperBound)
    }

    // MARK: - Constructing a zero/negative-round contract never traps

    func testConstructingAZeroRoundContractDoesNotTrap() {
        _ = DebateContract(topic: "t", proposer: "p", critic: "c", maxRounds: 0)
    }

    func testConstructingANegativeRoundContractDoesNotTrap() {
        _ = DebateContract(topic: "t", proposer: "p", critic: "c", maxRounds: -3)
    }

    // MARK: - run(contract:) reports the clamped round count, not the requested one

    @MainActor
    func testRunWithZeroRequestedRoundsReportsOneClampedRound() async throws {
        let mock = MockAgentRuntime()
        mock.events = [
            .assistantText("no verdict keyword here"),
            .result(.init(
                text: "no verdict keyword here", costUSD: 0.001, durationMs: 10,
                inputTokens: 5, outputTokens: 4,
                cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                sessionID: "s-debate", permissionDenials: []
            ))
        ]

        let orchestrator = Orchestrator(runtime: mock)
        let proposer = makeAgent(id: "proposer", name: "Proposer")
        let critic = makeAgent(id: "critic", name: "Critic")
        orchestrator.addAgent(proposer)
        orchestrator.addAgent(critic)

        let tempDir = try makeTemporaryDirectory(prefix: "debate-orchestrator")

        try await orchestrator.startAgent("proposer", cwd: tempDir)
        try await orchestrator.startAgent("critic", cwd: tempDir)

        let debate = DebateOrchestrator(orchestrator: orchestrator, projectURL: tempDir)
        let contract = DebateContract(topic: "t", proposer: "Proposer", critic: "Critic", maxRounds: 0)

        let result = await debate.run(contract: contract)

        XCTAssertEqual(result.terminated, .roundLimit)
        XCTAssertEqual(result.rounds, 1, "should report the clamped round count, not the requested 0")
    }

    /// A subagent's forwarded prose is not the proposal: the artifact the
    /// debate ends on is the proposer's own words alone.
    @MainActor
    func testASubagentsTextIsLeftOutOfTheProposal() async throws {
        let mock = MockAgentRuntime()
        mock.events = [
            .assistantText("Subagent: I read the repo. ", parentToolUseID: "toolu_agent"),
            .assistantText("{\"plan\":\"ship it\"}"),
            .result(.init(
                text: "{\"plan\":\"ship it\"}", costUSD: 0.001, durationMs: 10,
                inputTokens: 5, outputTokens: 4,
                cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                sessionID: "s-debate", permissionDenials: []
            ))
        ]
        let orchestrator = Orchestrator(runtime: mock)
        orchestrator.addAgent(makeAgent(id: "proposer", name: "Proposer"))
        orchestrator.addAgent(makeAgent(id: "critic", name: "Critic"))
        let tempDir = try makeTemporaryDirectory(prefix: "debate-subagent-text")
        try await orchestrator.startAgent("proposer", cwd: tempDir)
        try await orchestrator.startAgent("critic", cwd: tempDir)

        let result = await DebateOrchestrator(orchestrator: orchestrator, projectURL: tempDir)
            .run(contract: DebateContract(topic: "t", proposer: "Proposer", critic: "Critic", maxRounds: 1))

        XCTAssertEqual(result.finalArtifact, "{\"plan\":\"ship it\"}")
    }

    // MARK: - The grounding command runs on a deadline

    /// The defect: `grounding_command` is agent-supplied and was run with no
    /// time limit, so one that tails a file or waits on a network never
    /// returned — and the round, the debate and the agent turn behind it waited
    /// on it for ever. Past the deadline the call must come back at about the
    /// deadline, not when the command would have finished.
    func testAGroundingCommandThatOutlivesItsDeadlineReturnsAtTheDeadline() async {
        let started = Date()
        let output = await DebateOrchestrator.runGroundingCommand("sleep 810501", timeout: 1)
        let elapsed = Date().timeIntervalSince(started)

        // The command would have slept for a week: anything near the deadline
        // proves the wait was bounded rather than the command having exited.
        XCTAssertLessThan(elapsed, 15)
        XCTAssertTrue(output.contains("timed out"), output)
    }

    /// The critic still gets its turn, and the text it is handed says why the
    /// grounding data is missing rather than being empty.
    func testATimedOutGroundingCommandSaysSoInTheTextTheCriticGets() async {
        let output = await DebateOrchestrator.runGroundingCommand("sleep 810502", timeout: 1)

        XCTAssertFalse(output.isEmpty, "the critic prompt would carry no grounding line at all")
        XCTAssertTrue(output.contains("Grounding command timed out after 1s"), output)
    }

    /// A command that printed its fill and *then* hung must still say it timed
    /// out: the notice leads, so the output cap cannot trim it away.
    func testTheTimeoutNoticeSurvivesTheOutputCap() async {
        let command = "printf 'a%.0s' {1..5000}; sleep 810503"
        let output = await DebateOrchestrator.runGroundingCommand(command, timeout: 2)

        XCTAssertTrue(output.hasPrefix("Grounding command timed out after 2s"), String(output.prefix(80)))
    }

    /// A command that reads stdin gets the null device — EOF at once — rather
    /// than sitting on the app's own stdin until the deadline kills it.
    func testAGroundingCommandThatReadsStandardInputGetsEOF() async {
        let started = Date()
        // `-ef` compares device and inode, so this says *which* file fd 0 is,
        // not merely that reading it ends at once.
        let command = "cat >/dev/null; if [ /dev/fd/0 -ef /dev/null ]; then printf nulldev; else printf other; fi"
        let output = await DebateOrchestrator.runGroundingCommand(command, timeout: 10)

        XCTAssertEqual(output, "nulldev")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5,
                          "the read must have ended at EOF, not at the 10s deadline")
    }

    /// The deadline changes nothing for a command that finishes inside it: its
    /// own output, stdout and stderr interleaved, exactly as before.
    func testAQuickGroundingCommandsOutputIsUnchanged() async {
        let output = await DebateOrchestrator.runGroundingCommand(
            "printf out; printf err >&2", timeout: 10)

        XCTAssertTrue(output.contains("out"), output)
        XCTAssertTrue(output.contains("err"), output)
        XCTAssertFalse(output.contains("timed out"), output)
    }

    /// And it is still capped, at the same 4000 characters, so a chatty
    /// grounding command cannot flood the critic prompt.
    func testAChattyGroundingCommandIsCappedAtTheExistingLimit() async {
        let output = await DebateOrchestrator.runGroundingCommand(
            "printf 'a%.0s' {1..5000}", timeout: 10)

        XCTAssertEqual(DebateOrchestrator.groundingOutputLimit, 4000)
        XCTAssertEqual(output.count, 4000)
    }

    /// Signalling the command alone leaves anything *it* forked running and
    /// reparented. Nothing of the tree may outlive the deadline.
    func testATimedOutGroundingCommandLeavesNothingOfItsTreeRunning() async {
        _ = await DebateOrchestrator.runGroundingCommand("sleep 810504 & wait", timeout: 1)

        XCTAssertFalse(isProcessRunning(matching: "sleep 810504"),
                       "the forked child must not survive the call returning")
    }

    private func isProcessRunning(matching pattern: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", pattern]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func makeAgent(id: String, name: String) -> Agent {
        Agent(
            id: id, name: name, model: "sonnet",
            systemPrompt: "You are \(name).",
            tools: [], denied: [],
            permissionMode: "default", state: .idle
        )
    }
}
