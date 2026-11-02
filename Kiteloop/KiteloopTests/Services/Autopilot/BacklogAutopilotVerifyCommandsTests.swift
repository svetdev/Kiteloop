import XCTest
import KiteloopCore
@testable import Kiteloop

/// `BacklogAutopilot.declaredVerifyCommands` — which commands a run is held to,
/// unioned from the item's detail file and its line, and
/// `BacklogAutopilot.verifySourceDisagreement` — whether those two sources say
/// different things. These sat in `VerifyCoverageTests` until that file moved
/// into the host-less package, where `BacklogAutopilot` is not visible; the
/// coverage judgement itself stays there.
@MainActor
final class BacklogAutopilotVerifyCommandsTests: XCTestCase {

    // MARK: - declaredVerifyCommands

    /// A command declared only on the backlog line used to be dropped whenever
    /// the frontmatter was non-empty — the frontmatter "won" outright. Now
    /// both are declared: neither source narrows what the other said.
    func testDeclaredVerifyCommandsUnionsBothSources() {
        let item = BacklogItem(id: "x", title: "x", verify: "npm test", status: .ready, type: .local)
        let detail = BacklogItemDetail(
            id: "x", title: "x", size: nil,
            verifyCommands: [.init(name: "api", cmd: "cargo check --workspace", expect: nil),
                             .init(name: "web", cmd: "npm --prefix apps/web test", expect: nil)],
            acceptanceCriteria: [], outOfScope: [], what: nil, approach: nil)
        XCTAssertEqual(BacklogAutopilot.declaredVerifyCommands(item: item, detail: detail),
                       ["cargo check --workspace", "npm --prefix apps/web test", "npm test"])
    }

    /// The line's command isn't duplicated when it's already among the
    /// groomed ones.
    func testDeclaredVerifyCommandsDoesNotDuplicateAMatchingLine() {
        let item = BacklogItem(id: "x", title: "x", verify: "cargo check --workspace",
                                status: .ready, type: .local)
        let detail = BacklogItemDetail(
            id: "x", title: "x", size: nil,
            verifyCommands: [.init(name: "api", cmd: "cargo check --workspace", expect: nil)],
            acceptanceCriteria: [], outOfScope: [], what: nil, approach: nil)
        XCTAssertEqual(BacklogAutopilot.declaredVerifyCommands(item: item, detail: detail),
                       ["cargo check --workspace"])
    }

    func testDeclaredVerifyCommandsFallsBackToTheItemLine() {
        let item = BacklogItem(id: "x", title: "x", verify: "npm test", status: .ready, type: .local)
        XCTAssertEqual(BacklogAutopilot.declaredVerifyCommands(item: item, detail: nil), ["npm test"])
        let bare = BacklogItem(id: "x", title: "x", verify: nil, status: .ready, type: .local)
        XCTAssertEqual(BacklogAutopilot.declaredVerifyCommands(item: bare, detail: nil), [])
    }

    /// Only a groomed list, no line — still every groomed command, nothing
    /// spuriously appended.
    func testDeclaredVerifyCommandsWithOnlyTheGroomedList() {
        let item = BacklogItem(id: "x", title: "x", verify: nil, status: .ready, type: .local)
        let detail = BacklogItemDetail(
            id: "x", title: "x", size: nil,
            verifyCommands: [.init(name: "api", cmd: "cargo check --workspace", expect: nil)],
            acceptanceCriteria: [], outOfScope: [], what: nil, approach: nil)
        XCTAssertEqual(BacklogAutopilot.declaredVerifyCommands(item: item, detail: detail),
                       ["cargo check --workspace"])
    }

    // MARK: - verifySourceDisagreement

    func testVerifySourceDisagreementFiresWhenNeitherContainsTheOther() throws {
        let item = BacklogItem(id: "x", title: "x", verify: "npm test", status: .ready, type: .local)
        let detail = BacklogItemDetail(
            id: "x", title: "x", size: nil,
            verifyCommands: [.init(name: "api", cmd: "cargo check --workspace", expect: nil)],
            acceptanceCriteria: [], outOfScope: [], what: nil, approach: nil)
        let disagreement = try XCTUnwrap(BacklogAutopilot.verifySourceDisagreement(item: item, detail: detail))
        XCTAssertTrue(disagreement.contains("npm test"), "must name the line's spelling")
        XCTAssertTrue(disagreement.contains("cargo check --workspace"), "must name the frontmatter's spelling")
    }

    /// The line widened to a superset of the frontmatter's command is
    /// agreement, not a disagreement — the frontmatter's text is still there.
    func testVerifySourceDisagreementIsSilentWhenTheLineContainsTheGroomedCommand() {
        let item = BacklogItem(id: "x", title: "x", verify: "cargo check --workspace && npm test",
                                status: .ready, type: .local)
        let detail = BacklogItemDetail(
            id: "x", title: "x", size: nil,
            verifyCommands: [.init(name: "api", cmd: "cargo check --workspace", expect: nil)],
            acceptanceCriteria: [], outOfScope: [], what: nil, approach: nil)
        XCTAssertNil(BacklogAutopilot.verifySourceDisagreement(item: item, detail: detail))
    }

    /// A command written across two lines and the same command on one line
    /// compare equal, whitespace-normalized.
    func testVerifySourceDisagreementNormalizesWhitespace() {
        let item = BacklogItem(id: "x", title: "x", verify: "cargo   check\n--workspace",
                                status: .ready, type: .local)
        let detail = BacklogItemDetail(
            id: "x", title: "x", size: nil,
            verifyCommands: [.init(name: "api", cmd: "cargo check --workspace", expect: nil)],
            acceptanceCriteria: [], outOfScope: [], what: nil, approach: nil)
        XCTAssertNil(BacklogAutopilot.verifySourceDisagreement(item: item, detail: detail))
    }

    func testVerifySourceDisagreementIsSilentWithOnlyOneSource() {
        let lineOnly = BacklogItem(id: "x", title: "x", verify: "npm test", status: .ready, type: .local)
        XCTAssertNil(BacklogAutopilot.verifySourceDisagreement(item: lineOnly, detail: nil))

        let groomedOnly = BacklogItem(id: "x", title: "x", verify: nil, status: .ready, type: .local)
        let detail = BacklogItemDetail(
            id: "x", title: "x", size: nil,
            verifyCommands: [.init(name: "api", cmd: "cargo check --workspace", expect: nil)],
            acceptanceCriteria: [], outOfScope: [], what: nil, approach: nil)
        XCTAssertNil(BacklogAutopilot.verifySourceDisagreement(item: groomedOnly, detail: detail))
    }

    // MARK: - buildInitialState's verifyCommands prompt block

    /// The worker used to be briefed only on the groomed detail's commands
    /// whenever the detail file was non-empty — the line's own `verify:` was
    /// silently dropped from the prompt. It has to appear too, or the worker
    /// runs against a narrower bar than the coverage gate holds it to.
    func testBuildInitialStateVerifyCommandsIncludesTheLineAlongsideTheGroomedList() {
        let item = BacklogItem(id: "x", title: "x", verify: "npm test", status: .ready, type: .local)
        let detail = BacklogItemDetail(
            id: "x", title: "x", size: nil,
            verifyCommands: [.init(name: "api", cmd: "cargo check --workspace", expect: nil)],
            acceptanceCriteria: [], outOfScope: [], what: nil, approach: nil)
        let state = BacklogAutopilot.buildInitialState(item: item, detail: detail, worktree: nil)
        guard case let .string(verifyCommands)? = state["verifyCommands"] else {
            return XCTFail("expected a string verifyCommands entry")
        }
        XCTAssertTrue(verifyCommands.contains("cargo check --workspace"))
        XCTAssertTrue(verifyCommands.contains("npm test"))
    }

    /// A detail file that exists but declares no groomed commands still hands
    /// the worker the item line's `verify:` — a present-but-empty frontmatter
    /// list must not read as "nothing to run".
    func testBuildInitialStateVerifyCommandsFallsBackToTheLineWithAnEmptyGroomedList() {
        let item = BacklogItem(id: "x", title: "x", verify: "npm test", status: .ready, type: .local)
        let detail = BacklogItemDetail(
            id: "x", title: "x", size: nil,
            verifyCommands: [],
            acceptanceCriteria: [], outOfScope: [], what: nil, approach: nil)
        let state = BacklogAutopilot.buildInitialState(item: item, detail: detail, worktree: nil)
        guard case let .string(verifyCommands)? = state["verifyCommands"] else {
            return XCTFail("expected a string verifyCommands entry")
        }
        XCTAssertTrue(verifyCommands.contains("npm test"))
    }
}
