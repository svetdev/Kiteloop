import XCTest
@testable import KiteloopCore

/// `SignalSources.gather` is the piece that had never existed: something that
/// actually runs the instruments and reads the ledger, and hands
/// `SignalDrafting` a real `[SignalFinding]`. Every child is scripted here —
/// nothing spawns a real `run-unit-suite.sh` or `report-hotspots.py`.
final class SignalSourcesTests: XCTestCase {

    /// `ExecutableSearchPath.loginShellPath` is captured once per process by
    /// spawning a login shell. Warm it here, outside any scripted runner, so
    /// that capture is never recorded as a third call by the tests below and
    /// the composed `PATH` is the real one whichever test runs first.
    override func setUp() {
        super.setUp()
        _ = ExecutableSearchPath.loginShellPath
    }

    private let flakeOutput = """
        run-unit-suite: flake ledger
          FooTests.testBar
            3 flips at abc123, def456 — 2026-08-01T00:00:00Z .. 2026-08-10T00:00:00Z
        """

    private let lastOutput = """
        run-unit-suite: last recorded run
          when    2026-09-10T07:57:43Z
          commit  445afbbd (clean tree)
          tally   ✘ 4194 tests, 1 failing (1 failure)
          failing FooTests.testRed
        """

    private let hotspotOutput = """
        1 function(s) measured, 1 touched in the last 90 day(s), top 1 by churn x complexity:
          Kiteloop/Foo.swift:12  hotspot 56 (churn 8 x cc 7)  func doThing()
        """

    private func approvalLine(project: String, item: String, kind: String, at: String,
                              approvedAt: String? = nil, toStatus: String? = nil) -> String {
        var fields = [
            "\"projectPath\":\"\(project)\"", "\"projectName\":\"repo\"",
            "\"itemID\":\"\(item)\"", "\"kind\":\"\(kind)\"", "\"at\":\"\(at)\""
        ]
        if let approvedAt { fields.append("\"approvedAt\":\"\(approvedAt)\"") }
        if let toStatus { fields.append("\"toStatus\":\"\(toStatus)\"") }
        return "{\(fields.joined(separator: ","))}"
    }

    private func writeLedger(_ contents: String, to directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("task-approvals.jsonl")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// `--flakes` and `--last` are the same script under two flags, so the
    /// scripted runner tells them apart by the flag rather than by the
    /// executable, the way `gather` distinguishes them.
    private func runner(flakes: ScriptedSubprocessRunner.Answer,
                        hotspots: ScriptedSubprocessRunner.Answer,
                        last: ScriptedSubprocessRunner.Answer? = nil) -> ScriptedSubprocessRunner {
        let lastAnswer = last ?? .init(output: lastOutput)
        return ScriptedSubprocessRunner { call in
            if call.arguments.contains("--flakes") { return flakes }
            if call.arguments.contains("--last") { return lastAnswer }
            return hotspots
        }
    }

    func testEveryInstrumentContributesFindings() async throws {
        let dir = try makeTemporaryDirectory()
        let ledger = try writeLedger(
            approvalLine(project: "/repo", item: "old-item", kind: "reopened",
                        at: "2026-08-04T00:00:00Z", approvedAt: "2026-08-01T00:00:00Z", toStatus: "ready"),
            to: dir)

        let findings = await withScriptedSubprocesses(
            runner(flakes: .init(output: flakeOutput), hotspots: .init(output: hotspotOutput))
        ) {
            SignalSources.gather(repoRoot: dir, approvalsLedgerURL: ledger, projectPath: "/repo")
        }

        let instruments = Set(findings.map(\.instrument))
        XCTAssertEqual(instruments, [.flake, .redSuite, .hotspot, .escapedDefect])
        XCTAssertEqual(findings.count, 4)
        XCTAssertEqual(findings.first { $0.instrument == .redSuite }?.key, "FooTests.testRed")
    }

    func testNonZeroExitCostsOnlyThatInstrument() async throws {
        let dir = try makeTemporaryDirectory()
        let ledger = try writeLedger("", to: dir)

        let findings = await withScriptedSubprocesses(
            runner(flakes: .init(status: 1, output: flakeOutput), hotspots: .init(output: hotspotOutput))
        ) {
            SignalSources.gather(repoRoot: dir, approvalsLedgerURL: ledger, projectPath: "/repo")
        }

        XCTAssertEqual(findings.map(\.instrument), [.redSuite, .hotspot])
    }

    func testTimeoutCostsOnlyThatInstrument() async throws {
        let dir = try makeTemporaryDirectory()
        let ledger = try writeLedger("", to: dir)

        let findings = await withScriptedSubprocesses(
            runner(flakes: .init(output: flakeOutput), hotspots: .init(timedOut: true))
        ) {
            SignalSources.gather(repoRoot: dir, approvalsLedgerURL: ledger, projectPath: "/repo")
        }

        XCTAssertEqual(findings.map(\.instrument), [.flake, .redSuite])
    }

    func testMissingLedgerYieldsNoEscapedDefectFindingsAndDoesNotThrow() async throws {
        let dir = try makeTemporaryDirectory()
        let missingLedger = dir.appendingPathComponent("does-not-exist.jsonl")

        let findings = await withScriptedSubprocesses(
            runner(flakes: .init(output: flakeOutput), hotspots: .init(output: hotspotOutput))
        ) {
            SignalSources.gather(repoRoot: dir, approvalsLedgerURL: missingLedger, projectPath: "/repo")
        }

        XCTAssertFalse(findings.contains { $0.instrument == .escapedDefect })
        XCTAssertEqual(findings.count, 3)
    }

    /// The kill `AtomicFileWriter.append` is written to survive, read back by
    /// the pass: the ledger's last line is cut part-way through a multi-byte
    /// character. Reading the whole file as one string threw on that byte, so
    /// the pass logged the ledger unreadable and filed no escaped defect at
    /// all — every complete approval before the cut lost to it.
    func testATruncatedLedgerStillYieldsWhatItsCompleteLinesCarry() async throws {
        let dir = try makeTemporaryDirectory()
        var bytes = Data(approvalLine(project: "/repo", item: "old-item", kind: "reopened",
                                      at: "2026-08-04T00:00:00Z", approvedAt: "2026-08-01T00:00:00Z",
                                      toStatus: "ready").utf8)
        bytes.append(UInt8(ascii: "\n"))
        bytes.append(contentsOf: Data(#"{"projectPath":"/repo","itemID":"cut","kind":"reopened — "#.utf8).dropLast(2))
        XCTAssertNil(String(data: bytes, encoding: .utf8), "the ledger is genuinely not valid UTF-8")
        let ledger = dir.appendingPathComponent("task-approvals.jsonl")
        try bytes.write(to: ledger)

        let findings = await withScriptedSubprocesses(
            runner(flakes: .init(output: flakeOutput), hotspots: .init(output: hotspotOutput))
        ) {
            SignalSources.gather(repoRoot: dir, approvalsLedgerURL: ledger, projectPath: "/repo")
        }

        XCTAssertEqual(findings.filter { $0.instrument == .escapedDefect }.map(\.key), ["old-item"])
        XCTAssertEqual(findings.count, 4)
    }

    /// A ledger that is not there is not a read failure: a project the app has
    /// approved nothing in has escaped nothing. Empty bytes, and `gather` logs
    /// nothing — `nil` is what makes it log.
    func testAnAbsentLedgerReadsAsEmptyRatherThanAsAFailure() throws {
        let dir = try makeTemporaryDirectory()
        XCTAssertEqual(SignalSources.approvalsLedgerBytes(at: dir.appendingPathComponent("does-not-exist.jsonl")),
                       Data())
    }

    /// A ledger that is there and will not open still is one, so `gather`
    /// still says so.
    func testALedgerThatExistsAndCannotBeOpenedReadsAsAFailure() throws {
        try XCTSkipIf(getuid() == 0, "root opens a mode-000 file regardless")
        let dir = try makeTemporaryDirectory()
        let ledger = dir.appendingPathComponent("task-approvals.jsonl")
        try Data("{}\n".utf8).write(to: ledger)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: ledger.path)

        XCTAssertNil(SignalSources.approvalsLedgerBytes(at: ledger))
    }

    func testLedgerForAnotherProjectYieldsNoEscapedDefectFindings() async throws {
        let dir = try makeTemporaryDirectory()
        let ledger = try writeLedger(
            approvalLine(project: "/other", item: "old-item", kind: "reopened",
                        at: "2026-08-10T00:00:00Z", approvedAt: "2026-08-01T00:00:00Z"),
            to: dir)

        let findings = await withScriptedSubprocesses(
            runner(flakes: .init(output: flakeOutput), hotspots: .init(output: hotspotOutput))
        ) {
            SignalSources.gather(repoRoot: dir, approvalsLedgerURL: ledger, projectPath: "/repo")
        }

        XCTAssertFalse(findings.contains { $0.instrument == .escapedDefect })
    }

    func testEveryChildIsSpawnedWithADeadline() async throws {
        let dir = try makeTemporaryDirectory()
        let ledger = try writeLedger("", to: dir)
        let scripted = runner(flakes: .init(output: flakeOutput), hotspots: .init(output: hotspotOutput))

        _ = await withScriptedSubprocesses(scripted) {
            SignalSources.gather(repoRoot: dir, approvalsLedgerURL: ledger, projectPath: "/repo")
        }

        XCTAssertEqual(scripted.calls.count, 3)
        for call in scripted.calls {
            XCTAssertNotNil(call.timeout)
            XCTAssertEqual(call.directory, dir)
        }
        XCTAssertTrue(scripted.calls.contains { $0.arguments == ["--flakes"] })
        XCTAssertTrue(scripted.calls.contains { $0.arguments == ["--last"] })
        XCTAssertTrue(scripted.calls.contains { $0.executable.hasSuffix("report-hotspots.py") })
    }

    /// The bug this pins: the children were spawned with no `environment`, so
    /// they inherited a Finder-launched Kiteloop's `PATH` — no Homebrew on it,
    /// `report-hotspots.py` exiting 2 on its SwiftLint lookup, and an empty
    /// hotspot list indistinguishable from a repository with no hotspots.
    func testEveryChildIsSpawnedWithTheAppsSearchPath() async throws {
        let dir = try makeTemporaryDirectory()
        let ledger = try writeLedger("", to: dir)
        let scripted = runner(flakes: .init(output: flakeOutput), hotspots: .init(output: hotspotOutput))

        _ = await withScriptedSubprocesses(scripted) {
            SignalSources.gather(repoRoot: dir, approvalsLedgerURL: ledger, projectPath: "/repo")
        }

        let expected = ExecutableSearchPath.resolved(projectRoot: nil).joined
        XCTAssertEqual(scripted.calls.count, 3)
        for call in scripted.calls {
            let environment = try XCTUnwrap(call.environment, "\(call.executable) was spawned with no environment")
            XCTAssertEqual(environment[ExecutableSearchPath.pathVariable], expected)
        }
        // Whatever the app's own `PATH` is, what the children get reaches
        // Homebrew — where SwiftLint is installed.
        XCTAssertTrue(expected.contains("/opt/homebrew/bin"))
    }

    /// The fourth source is as independent as the other three: a `--last` that
    /// refuses costs its own findings and nothing else's.
    func testALastThatExitsNonZeroCostsOnlyItsOwnFindings() async throws {
        let dir = try makeTemporaryDirectory()
        let ledger = try writeLedger(
            approvalLine(project: "/repo", item: "old-item", kind: "reopened",
                        at: "2026-08-04T00:00:00Z", approvedAt: "2026-08-01T00:00:00Z", toStatus: "ready"),
            to: dir)

        let findings = await withScriptedSubprocesses(
            runner(flakes: .init(output: flakeOutput), hotspots: .init(output: hotspotOutput),
                   last: .init(status: 1, output: lastOutput))
        ) {
            SignalSources.gather(repoRoot: dir, approvalsLedgerURL: ledger, projectPath: "/repo")
        }

        XCTAssertEqual(findings.map(\.instrument), [.flake, .hotspot, .escapedDefect])
    }

    func testALastThatTimesOutCostsOnlyItsOwnFindings() async throws {
        let dir = try makeTemporaryDirectory()
        let ledger = try writeLedger("", to: dir)

        let findings = await withScriptedSubprocesses(
            runner(flakes: .init(output: flakeOutput), hotspots: .init(output: hotspotOutput),
                   last: .init(timedOut: true))
        ) {
            SignalSources.gather(repoRoot: dir, approvalsLedgerURL: ledger, projectPath: "/repo")
        }

        XCTAssertEqual(findings.map(\.instrument), [.flake, .hotspot])
    }
}
