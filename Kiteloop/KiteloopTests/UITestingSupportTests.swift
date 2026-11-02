import XCTest
import KiteloopCore
import KiteloopTestSupport
@testable import Kiteloop

/// Quick Start's project under an isolated home is the home's own folder: in the
/// shared temporary directory every QA run found the last run's chats.
final class UITestingSupportTests: XCTestCase {
    func testQuickStartOpensAFolderInsideAnIsolatedHome() throws {
        let home = try makeTemporaryDirectory(prefix: "quick-start-home")
        let folder = UITestingSupport.quickStartDirectory(
            environment: [KiteloopHome.variable: home.path(percentEncoded: false)])
        // Components, not URLs: a directory URL carries a trailing slash the expected one may not.
        XCTAssertEqual(folder.standardizedFileURL.pathComponents,
                       home.appending(path: "quick-start").standardizedFileURL.pathComponents)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)))
    }

    /// The storyboard gate scenario lays out, as Quick Start opens, two items at
    /// the approval gate and a storyboard kept for one of them — the QA flow's
    /// own process cannot write into the home.
    func testTheStoryboardGateScenarioKeepsAStoryboardForOneGatedItem() throws {
        let home = try makeTemporaryDirectory(prefix: "storyboard-gate-home")
        let folder = UITestingSupport.quickStartDirectory(environment: [
            KiteloopHome.variable: home.path(percentEncoded: false),
            "UI_TEST_SCENARIO": UITestingSupport.storyboardGateScenario,
        ])

        let backlog = try String(contentsOf: folder.appending(path: "BACKLOG.md"), encoding: .utf8)
        XCTAssertTrue(backlog.contains("- [ ] qa-demo | Demo QA change | awaiting-approval"))
        XCTAssertTrue(backlog.contains("- [ ] plain-item | Plain change | awaiting-approval"))
        let page = try XCTUnwrap(QAStoryboardPage.latest(home: home, itemID: "qa-demo")
            .flatMap(QAStoryboardPage.read))
        XCTAssertEqual(page.steps.map(\.caption), UITestingSupport.storyboardGateCaptions)
        XCTAssertEqual(page.steps.map(\.failed), [false, false, true])
        XCTAssertTrue(page.steps.allSatisfy { $0.picture != nil }, "every step should have its picture on disk")
        XCTAssertNil(QAStoryboardPage.latest(home: home, itemID: "plain-item"))
    }

    /// Without the scenario, Quick Start's folder stays empty.
    func testQuickStartSeedsNothingWithoutTheScenario() throws {
        let home = try makeTemporaryDirectory(prefix: "quick-start-home")
        let folder = UITestingSupport.quickStartDirectory(
            environment: [KiteloopHome.variable: home.path(percentEncoded: false)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appending(path: "BACKLOG.md").path(percentEncoded: false)))
        XCTAssertNil(QAStoryboardPage.latest(home: home, itemID: "qa-demo"))
    }

    /// Without one, Quick Start keeps opening the temporary directory as it did.
    func testWithoutAnIsolatedHomeQuickStartMakesNoFolderOfItsOwn() {
        XCTAssertNotEqual(UITestingSupport.quickStartDirectory(environment: [:]).lastPathComponent, "quick-start")
    }
}
