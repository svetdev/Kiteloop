import XCTest
@testable import Kiteloop

/// Collapsed epics are remembered per project, and follow an epic through a
/// rename only once the rename has been applied.
final class CollapsedEpicsStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: CollapsedEpicsStore!

    override func setUp() {
        super.setUp()
        // A suite of this test's own, so nothing leaks into the app's defaults.
        suiteName = "CollapsedEpicsStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = CollapsedEpicsStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        store = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testSavedSetLoadsBackForTheSameProjectOnly() {
        store.save(["Autopilot", "Portfolio"], projectPath: "/projects/a")

        XCTAssertEqual(store.load(projectPath: "/projects/a"), ["Autopilot", "Portfolio"])
        XCTAssertEqual(store.load(projectPath: "/projects/b"), [])
    }

    func testAppliedRenameMovesTheEntryToTheNewName() {
        store.save(["Old", "Other"], projectPath: "/p")

        let carried = store.carryRename(.applied, from: "Old", to: "New", projectPath: "/p")

        XCTAssertEqual(carried, ["New", "Other"])
        XCTAssertEqual(store.load(projectPath: "/p"), ["New", "Other"])
    }

    func testAppliedRenameOfAnEpicNotCollapsedLeavesTheSetUnchanged() {
        store.save(["Other"], projectPath: "/p")

        store.carryRename(.applied, from: "Old", to: "New", projectPath: "/p")

        XCTAssertEqual(store.load(projectPath: "/p"), ["Other"])
    }

    func testRefusedRenameLeavesTheSavedSetUnchanged() {
        store.save(["Old"], projectPath: "/p")

        let carried = store.carryRename(.nameTaken, from: "Old", to: "New", projectPath: "/p")

        XCTAssertEqual(carried, ["Old"])
        XCTAssertEqual(store.load(projectPath: "/p"), ["Old"])
    }

    func testTheStandardDefaultsAreLeftUntouched() {
        store.save(["Old"], projectPath: "/p")

        XCTAssertNil(UserDefaults.standard.object(forKey: CollapsedEpicsStore.key(projectPath: "/p")))
    }
}
