import XCTest
import KiteloopCore
@testable import Kiteloop

/// `writeBack()` used to land `BACKLOG.md` through `String.write(atomically:)` —
/// a rename into place that never flushes the bytes it moves, so a panic between
/// the rename and an unforced flush can leave a zero-length or truncated file
/// behind. It now goes through `AtomicFileWriter`, the same durable writer every
/// other store in the app uses (and that `appendNote` already used for the item
/// detail file two hundred lines up in this same view model).
///
/// The durability guarantee itself — bytes on the platter before the rename —
/// isn't observable from a unit test; what these pin is the closest visible
/// proxy: no `.tmp-` sibling survives a successful write, and a write that
/// cannot land is reported through `errorMessage` rather than thrown past the
/// caller, leaving the previous contents of the file readable.
@MainActor
final class BacklogViewModelDurableWriteTests: XCTestCase {
    private var tempDir: URL!
    private var backlogURL: URL!

    private let sampleBacklog = """
    ---
    project: demo
    verify_default: swift build
    ---

    # Demo Backlog

    ## Epic: Now

    - [ ] task-1 | First task | ready
    """

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "backlog-durable-write")
        backlogURL = tempDir.appending(path: "BACKLOG.md")
    }

    override func tearDownWithError() throws {
        // A case that made the directory read-only has to hand it back, or the
        // tree it sits in cannot be removed.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                               ofItemAtPath: tempDir.path(percentEncoded: false))
    }

    func testWriteBackLandsTheStatusAndLeavesNoTempSibling() throws {
        let vm = try makeViewModel()

        vm.updateItemStatus(itemID: "task-1", newStatus: .active)

        let content = try String(contentsOf: backlogURL, encoding: .utf8)
        let file = BacklogParser.parse(content)
        XCTAssertEqual(file.sections.flatMap(\.items).first { $0.id == "task-1" }?.status, .active)

        let siblings = try FileManager.default.contentsOfDirectory(atPath: tempDir.path(percentEncoded: false))
        XCTAssertFalse(siblings.contains { $0.hasPrefix(".BACKLOG.md.tmp-") },
                       "a temp sibling survived the write: \(siblings)")
    }

    func testWriteBackFailureReportsThroughOperationMessageAndPreservesContents() throws {
        let vm = try makeViewModel()
        let before = try String(contentsOf: backlogURL, encoding: .utf8)
        XCTAssertNil(vm.operationMessage)
        // No write access to the containing directory: AtomicFileWriter cannot
        // create its temp sibling, so the write fails before anything is renamed.
        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                              ofItemAtPath: tempDir.path(percentEncoded: false))

        vm.updateItemStatus(itemID: "task-1", newStatus: .active)

        XCTAssertNotNil(vm.operationMessage,
                        "a write that cannot land must be reported, not thrown past the caller")
        XCTAssertNil(vm.errorMessage,
                     "a refused write is not a backlog that failed to load — the list stays on screen")
        XCTAssertNotNil(vm.backlogFile)

        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: tempDir.path(percentEncoded: false))
        XCTAssertEqual(try String(contentsOf: backlogURL, encoding: .utf8), before,
                       "the previous contents must survive a write that cannot land")
    }

    /// The banner is an answer to the last edit, not a permanent mark: the next
    /// edit that lands takes it back off the panel.
    func testAnEditThatLandsClearsTheRefusalFromTheOneBefore() throws {
        let vm = try makeViewModel()
        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                              ofItemAtPath: tempDir.path(percentEncoded: false))
        vm.updateItemStatus(itemID: "task-1", newStatus: .active)
        XCTAssertNotNil(vm.operationMessage)

        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: tempDir.path(percentEncoded: false))
        vm.updateItemStatus(itemID: "task-1", newStatus: .ready)

        XCTAssertNil(vm.operationMessage, "a write that landed must clear the refusal before it")
    }

    private func makeConfigStore() -> GlobalConfigStore {
        GlobalConfigStore(storageURL: tempDir.appending(path: "global-config.json"))
    }

    private func makeViewModel() throws -> BacklogViewModel {
        try sampleBacklog.write(to: backlogURL, atomically: true, encoding: .utf8)
        let vm = BacklogViewModel(globalConfigStore: makeConfigStore())
        vm.loadForProject(repoPath: tempDir.path(percentEncoded: false))
        XCTAssertEqual(vm.backlogURL?.lastPathComponent, "BACKLOG.md")
        return vm
    }
}
