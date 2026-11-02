import XCTest
import KiteloopCore
@testable import Kiteloop

/// The backlog list marks an item autopilot holds back on its `needs:` with
/// the readiness gate's own reasons — so the reasons asserted here are the
/// gate's words, read through the view model.
@MainActor
final class BacklogUnmetDependencyTests: XCTestCase {

    private var tempDir: URL!

    private let sampleBacklog = """
    ---
    project: demo
    verify_default: swift build
    ---

    # Demo Backlog

    ## Epic: Now

    - [x] task-1 | First task | done | size: S
    - [ ] task-2 | Second task | ready | size: S | needs:task-1
    - [ ] task-3 | Third task | active | size: S
    - [ ] task-4 | Fourth task | ready | size: S | needs:task-3
    - [ ] task-5 | Fifth task | ready | size: S | needs:ghost
    - [ ] task-6 | Sixth task | ready | size: S | needs:task-7
    - [ ] task-7 | Seventh task | ready | size: S | needs:task-6
    - [x] task-8 | Eighth task | done | size: S | needs:task-3
    - [ ] task-9 | Ninth task | ready | size: S
    """

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "backlog-unmet-dependencies")
    }

    func testANeedThatIsDoneHasNoReasons() async throws {
        let backlog = try await makeBacklog()
        XCTAssertEqual(backlog.unmetDependencies(for: item("task-2", in: backlog)), [])
    }

    func testAnItemWithNoNeedsHasNoReasons() async throws {
        let backlog = try await makeBacklog()
        XCTAssertEqual(backlog.unmetDependencies(for: item("task-9", in: backlog)), [])
    }

    func testANeedThatIsNotDoneIsOneReasonNamingIt() async throws {
        let backlog = try await makeBacklog()
        let reasons = backlog.unmetDependencies(for: item("task-4", in: backlog))

        XCTAssertEqual(reasons.count, 1)
        XCTAssertTrue(reasons[0].hasPrefix("needs task-3 — not done (active)"), reasons[0])
    }

    func testANeedTheBacklogLacksSaysSo() async throws {
        let backlog = try await makeBacklog()
        let task5 = item("task-5", in: backlog)
        let reasons = backlog.unmetDependencies(for: task5)

        XCTAssertEqual(reasons, DefinitionOfReady.Dependencies(file: backlog.backlogFile!).unmet(for: task5))
        XCTAssertEqual(reasons.count, 1)
        XCTAssertTrue(reasons[0].hasPrefix("needs ghost"), reasons[0])
    }

    func testTwoItemsThatNeedEachOtherGiveACycleReason() async throws {
        let backlog = try await makeBacklog()
        let reasons = backlog.unmetDependencies(for: item("task-6", in: backlog))

        XCTAssertEqual(reasons.count, 1)
        XCTAssertTrue(reasons[0].contains("dependency cycle"), reasons[0])
    }

    func testADoneItemWithAnUnmetNeedHasNoReasons() async throws {
        let backlog = try await makeBacklog()
        XCTAssertEqual(backlog.unmetDependencies(for: item("task-8", in: backlog)), [])
    }

    // MARK: - Helpers

    private func makeBacklog() async throws -> BacklogViewModel {
        try sampleBacklog.write(to: tempDir.appending(path: "BACKLOG.md"), atomically: true, encoding: .utf8)
        let backlog = BacklogViewModel(
            globalConfigStore: GlobalConfigStore(storageURL: tempDir.appending(path: "global-config.json"))
        )
        backlog.loadForProject(repoPath: tempDir.path(percentEncoded: false))
        try await eventually { backlog.item(withID: "task-9") != nil }
        return backlog
    }

    private func item(_ id: String, in backlog: BacklogViewModel) -> BacklogItem {
        backlog.item(withID: id)!
    }
}
