import XCTest
import KiteloopCore
@testable import Kiteloop

/// `BacklogAutopilot.reviewerDiffFactsBlock` — the per-file facts block handed
/// to the reviewer's prompt, read from a run's working tree before anything is
/// committed (teardown is what commits). Git is scripted, so these assert the
/// facts built from its output without needing a repo; new-file line counts are
/// still read from real files on disk, the one part `git diff --numstat` can't
/// answer for an untracked path.
@MainActor
final class ReviewerDiffFactsBlockTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = try makeTemporaryDirectory(prefix: "reviewer-diff-facts")
    }

    /// An autopilot wired only enough for `projectRoot` to be set — the one
    /// thing `reviewerDiffFactsBlock` reads off it when handed no directory.
    private func makeAutopilot() -> BacklogAutopilot {
        let autopilot = BacklogAutopilot()
        autopilot.configure(
            orchestrator: Orchestrator(runtime: MockAgentRuntime()),
            backlogViewModel: BacklogViewModel(
                globalConfigStore: GlobalConfigStore(
                    storageURL: tempDir.appendingPathComponent("global-config.json")
                )
            ),
            projectPath: tempDir.path(percentEncoded: false)
        )
        return autopilot
    }

    private var root: String { tempDir.path(percentEncoded: false) }

    func testNoDirectoryAndNoProjectRootReadsNothing() async {
        let autopilot = BacklogAutopilot()
        let runner = ScriptedSubprocessRunner { _ in .init(output: "should never be read") }
        let block = await withScriptedSubprocesses(runner) {
            await autopilot.reviewerDiffFactsBlock(directory: nil)
        }
        XCTAssertNil(block)
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testNoDirectoryFallsBackToTheProjectRoot() async {
        let autopilot = makeAutopilot()
        let runner = ScriptedSubprocessRunner { call in
            if call.arguments.contains("--numstat") { return .init(status: 0, output: "10\t2\tFoo.swift") }
            return .init(status: 0, output: "")
        }
        _ = await withScriptedSubprocesses(runner) {
            await autopilot.reviewerDiffFactsBlock(directory: nil)
        }
        let numstatCall = try? XCTUnwrap(runner.calls.first { $0.arguments.contains("--numstat") })
        XCTAssertEqual(numstatCall?.arguments, ["-C", root, "diff", "--numstat", "HEAD"])
    }

    func testAnExplicitDirectoryIsReadInsteadOfTheProjectRoot() async {
        let autopilot = makeAutopilot()
        let worktree = tempDir.appending(path: "worktree")
        let runner = ScriptedSubprocessRunner { call in
            if call.arguments.contains("--numstat") { return .init(status: 0, output: "1\t0\tFoo.swift") }
            return .init(status: 0, output: "")
        }
        _ = await withScriptedSubprocesses(runner) {
            await autopilot.reviewerDiffFactsBlock(directory: worktree)
        }
        let numstatCall = try? XCTUnwrap(runner.calls.first { $0.arguments.contains("--numstat") })
        XCTAssertEqual(numstatCall?.arguments,
                       ["-C", worktree.path(percentEncoded: false), "diff", "--numstat", "HEAD"])
    }

    func testTrackedChangesBecomeAPerFileBlockWithTestAndChangelogFacts() async {
        let autopilot = makeAutopilot()
        let runner = ScriptedSubprocessRunner { call in
            if call.arguments.contains("--numstat") {
                return .init(status: 0, output: "317\t0\tKiteloop/Kiteloop/Services/BacklogAutopilot.swift\n"
                              + "565\t0\tKiteloop/Kiteloop/Services/NewReviewService.swift")
            }
            return .init(status: 0, output: "")
        }
        let block = await withScriptedSubprocesses(runner) {
            await autopilot.reviewerDiffFactsBlock(directory: nil)
        }
        XCTAssertEqual(block, """
            ## Changed files
            - Kiteloop/Kiteloop/Services/BacklogAutopilot.swift (+317/-0)
            - Kiteloop/Kiteloop/Services/NewReviewService.swift (+565/-0)

            Test files changed: no
            CHANGELOG.md changed: no
            Uncommitted at handoff: 2 file(s) — the worker did not commit; teardown will
            """)
    }

    func testANewUntrackedFileIsCountedByReadingItFromDisk() async throws {
        let autopilot = makeAutopilot()
        try "one\ntwo\nthree\n".write(to: tempDir.appending(path: "NewFile.swift"), atomically: true, encoding: .utf8)
        let runner = ScriptedSubprocessRunner { call in
            if call.arguments.contains("--numstat") { return .init(status: 0, output: "") }
            if call.arguments.contains("--porcelain") { return .init(status: 0, output: "?? NewFile.swift\n") }
            return .init(status: 0, output: "")
        }
        let block = await withScriptedSubprocesses(runner) {
            await autopilot.reviewerDiffFactsBlock(directory: nil)
        }
        // Three lines, counted the way `git diff --numstat` counts a new file.
        XCTAssertEqual(block, """
            ## Changed files
            - NewFile.swift (+3/-0)

            Test files changed: no
            CHANGELOG.md changed: no
            Uncommitted at handoff: 1 file(s) — the worker did not commit; teardown will
            """)
    }

    func testATestFileAmongTheTrackedChangesReportsYes() async {
        let autopilot = makeAutopilot()
        let runner = ScriptedSubprocessRunner { call in
            if call.arguments.contains("--numstat") {
                return .init(status: 0, output: "10\t1\tKiteloop/KiteloopTests/Services/FooTests.swift")
            }
            return .init(status: 0, output: "")
        }
        let block = await withScriptedSubprocesses(runner) {
            await autopilot.reviewerDiffFactsBlock(directory: nil)
        }
        XCTAssertTrue(block?.contains("Test files changed: yes") ?? false)
    }

    func testChangelogAmongTheTrackedChangesReportsYes() async {
        let autopilot = makeAutopilot()
        let runner = ScriptedSubprocessRunner { call in
            if call.arguments.contains("--numstat") { return .init(status: 0, output: "2\t0\tCHANGELOG.md") }
            return .init(status: 0, output: "")
        }
        let block = await withScriptedSubprocesses(runner) {
            await autopilot.reviewerDiffFactsBlock(directory: nil)
        }
        XCTAssertTrue(block?.contains("CHANGELOG.md changed: yes") ?? false)
    }

    func testGitFailingBothCallsReportsNoChangedFiles() async {
        let autopilot = makeAutopilot()
        let runner = ScriptedSubprocessRunner { _ in .init(status: 1, output: "") }
        let block = await withScriptedSubprocesses(runner) {
            await autopilot.reviewerDiffFactsBlock(directory: nil)
        }
        XCTAssertNil(block)
    }
}
