import XCTest
import KiteloopCore
@testable import Kiteloop

/// The autopilot's verify command carries the worktree's build output: the
/// one case of `WorktreeBuildOutputTests` that reaches `BacklogAutopilot`, kept
/// app-hosted beside the package's own because the autopilot is the app's.
final class WorktreeBuildOutputAutopilotTests: XCTestCase {
    private let worktree = URL(fileURLWithPath: "/tmp/proj/.kiteloop/worktrees/some-item")

    private var derivedData: String {
        "/tmp/proj/.kiteloop/worktrees/some-item/.kiteloop/DerivedData"
    }

    @MainActor
    func testSalvageVerifyCommandRedirectsOnAnIsolatedRun() {
        let item = BacklogItem(id: "some-item", title: "Some item",
                               verify: "xcodebuild build", status: .active, type: .local)
        XCTAssertEqual(
            BacklogAutopilot.salvageVerifyCommand(item: item, detail: nil, worktree: worktree),
            "xcodebuild -derivedDataPath '\(derivedData)' build"
        )
        XCTAssertEqual(
            BacklogAutopilot.salvageVerifyCommand(item: item, detail: nil),
            "xcodebuild build"
        )
    }
}
