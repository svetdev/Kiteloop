import XCTest
import KiteloopTestSupport
@testable import KiteloopCore

/// Held configuration changes: a caller suspended until a person answers, the
/// decision written before the caller hears it, and nothing applied for a
/// caller who has gone or an approval that could not be recorded.
@MainActor
final class HeldConfigChangesTests: XCTestCase {

    private let asked = Date(timeIntervalSince1970: 1_700_000_000)
    private let answered = Date(timeIntervalSince1970: 1_700_000_600)
    private var held: HeldConfigChanges!
    private var logged: [ConfigChangeLog.Record] = []

    override func setUp() async throws {
        held = HeldConfigChanges()
        logged = []
    }

    private func change(_ id: String = "c1") -> HeldConfigChange {
        HeldConfigChange(id: id, caller: "operator", route: "PUT /v1/settings",
                         summary: #"{"defaultModel":"opus"}"#, project: nil, askedAt: asked)
    }

    /// Files `change` and waits until it is on the list.
    private func file(_ change: HeldConfigChange) async throws -> Task<HeldConfigChanges.Outcome, Never> {
        let held = held!
        let caller = Task { await held.outcome(of: change) }
        try await eventually("the change to be waiting") { held.waiting.contains { $0.id == change.id } }
        return caller
    }

    private func answer(_ id: String, approve: Bool) -> HeldConfigChanges.Answer {
        held.answer(id, approve: approve, at: answered) { _, record in logged.append(record) }
    }

    func testACallerIsHeldUntilAPersonAnswers() async throws {
        let caller = try await file(change())

        // Nothing but an answer ends the wait.
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(held.waiting.map(\.id), ["c1"])
        XCTAssertTrue(logged.isEmpty)

        XCTAssertEqual(answer("c1", approve: true), .approved)
        let outcome = await caller.value
        XCTAssertEqual(outcome, .approved)
        XCTAssertTrue(held.waiting.isEmpty)
    }

    func testAnApprovalIsLoggedWithCallerRouteSummaryDecisionAndTime() async throws {
        let caller = try await file(change())

        _ = answer("c1", approve: true)
        _ = await caller.value

        XCTAssertEqual(logged, [ConfigChangeLog.Record(
            requestedBy: "operator", kind: "api", tool: "PUT /v1/settings", before: "",
            after: #"{"defaultModel":"opus"}"#, decision: .approved, at: answered)])
    }

    /// The line is written before the caller is let go: at the moment the
    /// log is asked to write, the caller has not been resumed.
    func testTheDecisionIsLoggedBeforeTheCallerIsResumed() async throws {
        let resumed = Flag()
        let held = held!
        let caller = Task { () -> HeldConfigChanges.Outcome in
            let outcome = await held.outcome(of: self.change())
            resumed.raise()
            return outcome
        }
        try await eventually("the change to be waiting") { !held.waiting.isEmpty }

        var resumedWhenLogged: Bool?
        _ = held.answer("c1", approve: true, at: answered) { _, _ in resumedWhenLogged = resumed.isRaised }
        _ = await caller.value

        XCTAssertEqual(resumedWhenLogged, false)
    }

    func testADeclineResumesTheCallerDeclinedAndIsLogged() async throws {
        let caller = try await file(change())

        XCTAssertEqual(answer("c1", approve: false), .declined)
        let outcome = await caller.value

        XCTAssertEqual(outcome, .declined)
        XCTAssertEqual(logged.map(\.decision), [.denied])
        XCTAssertTrue(held.waiting.isEmpty)
    }

    /// An approval that cannot be written is refused, not applied unrecorded.
    func testAnApprovalThatCannotBeLoggedIsRefused() async throws {
        struct DiskFull: LocalizedError { var errorDescription: String? { "the disk is full" } }
        let caller = try await file(change())

        let answer = held.answer("c1", approve: true, at: answered) { _, _ in throw DiskFull() }
        let outcome = await caller.value

        XCTAssertEqual(answer, .unrecorded("the disk is full"))
        XCTAssertEqual(outcome, .unrecorded("the disk is full"))
        XCTAssertTrue(held.waiting.isEmpty, "the card goes: a second approval must not apply it either")
    }

    /// A caller that hangs up leaves its card, and the card applies nothing.
    func testACallerWhoLeavesKeepsItsCardWhichThenAppliesNothing() async throws {
        let caller = try await file(change())

        held.callerLeft("c1")
        let outcome = await caller.value

        XCTAssertEqual(outcome, .callerGone)
        XCTAssertEqual(held.waiting.map(\.id), ["c1"], "the card stays for the person to see")
        XCTAssertEqual(held.waiting.first?.callerGone, true)
        XCTAssertTrue(logged.isEmpty)

        XCTAssertEqual(answer("c1", approve: true), .abandoned)
        XCTAssertEqual(logged.map(\.decision), [.abandoned])
        XCTAssertTrue(held.waiting.isEmpty)
    }

    func testAnsweringAnUnknownChangeChangesNothing() async throws {
        let caller = try await file(change())

        XCTAssertEqual(answer("nope", approve: true), .unknown)
        XCTAssertEqual(held.waiting.map(\.id), ["c1"])
        XCTAssertTrue(logged.isEmpty)

        _ = answer("c1", approve: false)
        _ = await caller.value
    }

    /// A change can be answered once: the second answer finds nothing.
    func testAChangeIsAnsweredOnce() async throws {
        let caller = try await file(change())

        XCTAssertEqual(answer("c1", approve: false), .declined)
        XCTAssertEqual(answer("c1", approve: true), .unknown)
        let outcome = await caller.value

        XCTAssertEqual(outcome, .declined)
        XCTAssertEqual(logged.count, 1)
    }

    func testEachOfTwoChangesIsAnsweredOnItsOwn() async throws {
        let first = try await file(change("c1"))
        let second = try await file(change("c2"))

        XCTAssertEqual(answer("c2", approve: true), .approved)
        let secondOutcome = await second.value
        XCTAssertEqual(secondOutcome, .approved)
        XCTAssertEqual(held.waiting.map(\.id), ["c1"])

        XCTAssertEqual(answer("c1", approve: false), .declined)
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .declined)
    }

    /// The same line reaches a real log file, and reads back.
    func testTheRecordRoundTripsThroughTheLogFile() async throws {
        let directory = try makeTemporaryDirectory(prefix: "held-config-changes")
        let url = ConfigChangeLog.url(appDirectory: directory)
        let caller = try await file(change())

        let answer = held.answer("c1", approve: true, at: answered) { _, record in
            try ConfigChangeLog.append(record, to: url)
        }
        _ = await caller.value

        XCTAssertEqual(answer, .approved)
        XCTAssertEqual(ConfigChangeLog.read(from: url).map(\.decision), [.approved])
        XCTAssertEqual(ConfigChangeLog.read(from: url).first?.tool, "PUT /v1/settings")
    }

    /// A log that cannot be written — its directory is a file — refuses the approval.
    func testAnUnwritableLogFileRefusesTheApproval() async throws {
        let directory = try makeTemporaryDirectory(prefix: "held-config-changes")
        let blocker = directory.appending(path: "not-a-directory")
        try Data("x".utf8).write(to: blocker)
        let url = ConfigChangeLog.url(appDirectory: blocker)
        let caller = try await file(change())

        let answer = held.answer("c1", approve: true, at: answered) { _, record in
            try ConfigChangeLog.append(record, to: url)
        }
        let outcome = await caller.value

        guard case .unrecorded = answer, case .unrecorded = outcome else {
            return XCTFail("expected the approval to be refused, got \(answer) / \(outcome)")
        }
    }
}

/// A flag one task raises and another reads.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    var isRaised: Bool {
        lock.lock(); defer { lock.unlock() }
        return raised
    }

    func raise() {
        lock.lock(); defer { lock.unlock() }
        raised = true
    }
}
