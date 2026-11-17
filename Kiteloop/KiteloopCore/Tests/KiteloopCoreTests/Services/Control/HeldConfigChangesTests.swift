import XCTest
import KiteloopTestSupport
@testable import KiteloopCore

/// Held configuration changes: a caller suspended until a person answers, the
/// decision written before anything applies, an approved change applied
/// whether or not its caller is still there, and what became of each kept for
/// the credential that asked — and nobody else's — to read.
@MainActor
final class HeldConfigChangesTests: XCTestCase {

    private let asked = Date(timeIntervalSince1970: 1_700_000_000)
    private let answered = Date(timeIntervalSince1970: 1_700_000_600)
    private let saved = ConfigChangeOutcome.Applied(status: 200, body: Data(#"{"defaultModel":"opus"}"#.utf8))
    private let theOperator = ConfigChangeReader(isThePerson: false, key: "operator")
    private let thePerson = ConfigChangeReader(isThePerson: true, key: "control")
    private var held: HeldConfigChanges!
    private var logged: [ConfigChangeLog.Record] = []
    /// The ids of the changes that were carried out, in order.
    private var applied: [String] = []

    override func setUp() async throws {
        held = HeldConfigChanges()
        logged = []
        applied = []
    }

    private func change(_ id: String = "c1", asker: String? = nil) -> HeldConfigChange {
        HeldConfigChange(id: id, caller: "operator", asker: asker, route: "PUT /v1/settings",
                         summary: #"{"defaultModel":"opus"}"#, project: nil, askedAt: asked)
    }

    /// Files `change` and waits until it is on the list.
    private func file(_ change: HeldConfigChange) async throws -> Task<HeldConfigChanges.Outcome, Never> {
        let held = held!
        let saved = saved
        let caller = Task {
            await held.outcome(of: change) {
                self.applied.append(change.id)
                return saved
            }
        }
        try await eventually("the change to be waiting") { held.waiting.contains { $0.id == change.id } }
        return caller
    }

    private func answer(_ id: String, approve: Bool) -> HeldConfigChanges.Answer {
        held.answer(id, approve: approve, at: answered) { _, record in logged.append(record) }
    }

    private func state(_ id: String = "c1") -> ConfigChangeOutcome.State? {
        held.outcome(id, for: theOperator)?.state
    }

    // MARK: - A caller who waits

    func testACallerIsHeldUntilAPersonAnswers() async throws {
        let caller = try await file(change())

        // Nothing but an answer ends the wait.
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(held.waiting.map(\.id), ["c1"])
        XCTAssertTrue(logged.isEmpty)
        XCTAssertTrue(applied.isEmpty)
        XCTAssertEqual(state(), .waiting)

        XCTAssertEqual(answer("c1", approve: true), .approved)
        let outcome = await caller.value
        XCTAssertEqual(outcome, .approved(saved), "the caller is told what its call answered")
        XCTAssertEqual(applied, ["c1"])
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

    func testALineAboutAProjectNamesItsFolder() async throws {
        let project = HeldConfigChange.Project(id: "p1", name: "site", path: "/work/site")
        let about = HeldConfigChange(id: "c1", caller: "operator", route: "PUT /v1/autopilot", summary: "",
                                     project: project, askedAt: asked)
        let caller = try await file(about)

        _ = answer("c1", approve: false)
        _ = await caller.value

        XCTAssertEqual(logged.map(\.project), ["/work/site"])
    }

    /// The line is written before the change is carried out.
    func testTheDecisionIsLoggedBeforeTheChangeApplies() async throws {
        let caller = try await file(change())

        var appliedWhenLogged: [String]?
        _ = held.answer("c1", approve: true, at: answered) { _, _ in appliedWhenLogged = applied }
        _ = await caller.value

        XCTAssertEqual(appliedWhenLogged, [], "nothing had applied when the log was asked to write")
        XCTAssertEqual(applied, ["c1"])
    }

    func testADeclineResumesTheCallerDeclinedAndIsLogged() async throws {
        let caller = try await file(change())

        XCTAssertEqual(answer("c1", approve: false), .declined)
        let outcome = await caller.value

        XCTAssertEqual(outcome, .declined)
        XCTAssertEqual(logged.map(\.decision), [.denied])
        XCTAssertTrue(applied.isEmpty)
        XCTAssertTrue(held.waiting.isEmpty)
        XCTAssertEqual(state(), .declined)
    }

    /// An approval that cannot be written is refused, not applied unrecorded.
    func testAnApprovalThatCannotBeLoggedIsRefused() async throws {
        struct DiskFull: LocalizedError { var errorDescription: String? { "the disk is full" } }
        let caller = try await file(change())

        let answer = held.answer("c1", approve: true, at: answered) { _, _ in throw DiskFull() }
        let outcome = await caller.value

        XCTAssertEqual(answer, .unrecorded("the disk is full"))
        XCTAssertEqual(outcome, .unrecorded("the disk is full"))
        XCTAssertTrue(applied.isEmpty)
        XCTAssertTrue(held.waiting.isEmpty, "the card goes: a second approval must not apply it either")
        XCTAssertEqual(state(), .unrecorded("the disk is full"))
    }

    // MARK: - A caller who has gone

    /// A caller that hangs up leaves its card waiting, and nothing applies
    /// until a person answers it.
    func testACallerWhoLeavesKeepsItsCardWaiting() async throws {
        let caller = try await file(change())

        held.callerLeft("c1")
        let outcome = await caller.value

        XCTAssertEqual(outcome, .callerGone)
        XCTAssertEqual(held.waiting.map(\.id), ["c1"], "the card stays for the person to see")
        XCTAssertEqual(held.waiting.first?.callerGone, true)
        XCTAssertTrue(logged.isEmpty)
        XCTAssertTrue(applied.isEmpty)
        XCTAssertEqual(state(), .waiting, "the caller can come back and see it is still waiting")
    }

    /// Approved after its caller left, the change is logged, then applied —
    /// it is what the person saw and approved — and what it answered is kept.
    func testApprovingAfterTheCallerLeftAppliesTheChangeAndKeepsWhatItAnswered() async throws {
        let caller = try await file(change())
        held.callerLeft("c1")
        _ = await caller.value

        XCTAssertEqual(answer("c1", approve: true), .approved)
        XCTAssertEqual(logged.map(\.decision), [.approved])
        let held = held!
        try await eventually("the change to be applied") { held.outcome("c1", for: self.theOperator)?.state == .approved(self.saved) }

        XCTAssertEqual(applied, ["c1"])
        XCTAssertTrue(held.waiting.isEmpty)
    }

    func testDecliningAfterTheCallerLeftChangesNothingAndIsLoggedAsDenied() async throws {
        let caller = try await file(change())
        held.callerLeft("c1")
        _ = await caller.value

        XCTAssertEqual(answer("c1", approve: false), .declined)
        for _ in 0..<50 { await Task.yield() }

        XCTAssertTrue(applied.isEmpty)
        XCTAssertEqual(logged.map(\.decision), [.denied])
        XCTAssertEqual(state(), .declined)
    }

    /// An approval that cannot be logged applies nothing for a gone caller either.
    func testAnUnloggedApprovalAfterTheCallerLeftAppliesNothing() async throws {
        struct DiskFull: LocalizedError { var errorDescription: String? { "the disk is full" } }
        let caller = try await file(change())
        held.callerLeft("c1")
        _ = await caller.value

        let answer = held.answer("c1", approve: true, at: answered) { _, _ in throw DiskFull() }
        for _ in 0..<50 { await Task.yield() }

        XCTAssertEqual(answer, .unrecorded("the disk is full"))
        XCTAssertTrue(applied.isEmpty)
        XCTAssertEqual(state(), .unrecorded("the disk is full"))
    }

    // MARK: - Who may read what became of a change

    func testOnlyTheCredentialThatAskedOrThePersonReadsAnOutcome() async throws {
        let ci = ConfigChangeReader(isThePerson: false, key: "token:1")
        let other = ConfigChangeReader(isThePerson: false, key: "token:2")
        let mine = try await file(change("c1", asker: "token:1"))
        let theirs = try await file(change("c2", asker: "token:2"))

        XCTAssertEqual(held.outcomes(for: ci).map(\.change.id), ["c1"])
        XCTAssertEqual(held.outcomes(for: other).map(\.change.id), ["c2"])
        XCTAssertEqual(held.outcomes(for: thePerson).map(\.change.id), ["c1", "c2"])
        XCTAssertNil(held.outcome("c2", for: ci), "another credential's change reads as unknown")
        XCTAssertNil(held.outcome("c1", for: theOperator))

        _ = answer("c1", approve: true)
        _ = answer("c2", approve: false)
        _ = await mine.value
        _ = await theirs.value

        XCTAssertEqual(held.outcome("c1", for: ci)?.state, .approved(saved))
        XCTAssertNil(held.outcome("c1", for: other), "nor does it read what the change answered")
        XCTAssertEqual(held.outcome("c1", for: thePerson)?.state, .approved(saved))
        XCTAssertEqual(held.outcome("c2", for: other)?.state, .declined)
    }

    /// Two tokens that share a name are still two credentials.
    func testASharedNameIsNotASharedCredential() {
        let asked = HeldConfigChange(caller: "ci (configure)", asker: "token:1", route: "PUT /v1/settings",
                                     summary: "", project: nil, askedAt: asked)

        XCTAssertTrue(ConfigChangeReader(isThePerson: false, key: "token:1").mayRead(asked))
        XCTAssertFalse(ConfigChangeReader(isThePerson: false, key: "token:2").mayRead(asked))
        XCTAssertFalse(ConfigChangeReader(isThePerson: false, key: "ci (configure)").mayRead(asked))
        XCTAssertTrue(ConfigChangeReader(isThePerson: true, key: "control").mayRead(asked))
    }

    func testAnUnknownChangeReadsAsNothing() {
        XCTAssertNil(held.outcome("nope", for: thePerson))
        XCTAssertEqual(held.outcomes(for: thePerson), [])
    }

    /// Answered changes are kept up to the bound, the oldest dropped first.
    func testOnlyTheNewestAnsweredChangesAreKept() async throws {
        held = HeldConfigChanges(keeping: 2)
        for id in ["c1", "c2", "c3"] {
            let caller = try await file(change(id))
            _ = answer(id, approve: false)
            _ = await caller.value
        }

        XCTAssertEqual(held.outcomes(for: theOperator).map(\.change.id), ["c2", "c3"])
        XCTAssertNil(held.outcome("c1", for: theOperator))
    }

    func testTheBoundIsTheEventFeeds() async {
        let feed = await AppEventFeed().capacity

        XCTAssertEqual(held.kept, AppEventFeed.defaultCapacity)
        XCTAssertEqual(feed, AppEventFeed.defaultCapacity)
    }

    // MARK: - Quitting

    /// A quit with cards unanswered logs each as abandoned, applies nothing
    /// and lets a caller still connected go.
    func testCardsStillWaitingAtAQuitAreLoggedAsAbandoned() async throws {
        let stayed = try await file(change("c1"))
        let left = try await file(change("c2"))
        held.callerLeft("c2")
        _ = await left.value

        held.abandonWaiting(at: answered) { _, record in logged.append(record) }
        let outcome = await stayed.value

        XCTAssertEqual(outcome, .abandoned)
        XCTAssertEqual(logged.map(\.decision), [.abandoned, .abandoned])
        XCTAssertTrue(applied.isEmpty)
        XCTAssertTrue(held.waiting.isEmpty)
        XCTAssertEqual(answer("c2", approve: true), .unknown, "an abandoned card cannot be approved afterwards")
    }

    // MARK: - One answer each

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
        XCTAssertTrue(applied.isEmpty)
    }

    func testEachOfTwoChangesIsAnsweredOnItsOwn() async throws {
        let first = try await file(change("c1"))
        let second = try await file(change("c2"))

        XCTAssertEqual(answer("c2", approve: true), .approved)
        let secondOutcome = await second.value
        XCTAssertEqual(secondOutcome, .approved(saved))
        XCTAssertEqual(held.waiting.map(\.id), ["c1"])

        XCTAssertEqual(answer("c1", approve: false), .declined)
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .declined)
        XCTAssertEqual(applied, ["c2"])
    }

    // MARK: - The log file

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
        XCTAssertTrue(applied.isEmpty)
    }
}
