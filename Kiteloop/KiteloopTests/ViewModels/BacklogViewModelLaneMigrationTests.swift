import XCTest
import KiteloopCore
@testable import Kiteloop

/// The move off the `Now` epic, at the seam it happens: loading the file.
///
/// A project that wanted something run next put it in an epic called `Now`,
/// which spent the epic — the only record of which area an item is about — on
/// an ordering decision. The load marks those items `lane:now` and writes the
/// marks back, so the ordering survives into the field that carries it and the
/// epic is free to go back to being a map. The items stay where they are: what
/// area they belong to is written nowhere, so only a person can move them home.
@MainActor
final class BacklogViewModelLaneMigrationTests: XCTestCase {
    private var tempDir: URL!
    private var backlogURL: URL!

    // No `verify_default`: one written into the frontmatter is written onto
    // every item's line on the first write-back, which would put a `verify:`
    // into the lines these cases read.
    private let backlogWithANowEpic = """
    ---
    project: demo
    ---

    # Demo Backlog

    ## Epic: Now

    - [ ] task-1 | First task | size:M | ready
    - [ ] task-2 | Second task | ready

    ## Epic: Onboarding

    - [ ] task-3 | Third task | ready
    """

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "backlog-lane-migration")
        backlogURL = tempDir.appending(path: "BACKLOG.md")
    }

    /// Loading is what carries the marks across — and the file on disk carries
    /// them too, or the next load would have to do it all over again.
    func testLoadingAFileWithANowEpicMarksItsItemsAndWritesThemBack() throws {
        let vm = try makeViewModel()

        XCTAssertEqual(lanes(in: vm.backlogFile),
                       ["task-1": .now, "task-2": .now, "task-3": .later])

        let onDisk = try String(contentsOf: backlogURL, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("- [ ] task-1 | First task | size:M | lane:now | ready"),
                      "the mark should be written beside the size:\n\(onDisk)")
        XCTAssertTrue(onDisk.contains("- [ ] task-3 | Third task | ready"),
                      "an item outside the Now epic keeps its line:\n\(onDisk)")
        XCTAssertEqual(vm.backlogFile?.sections.map(\.name), ["Now", "Onboarding"],
                       "the epic keeps its items — moving them home is a person's edit")
    }

    /// Once. The second load finds every item already marked and writes
    /// nothing; a migration that fired again would rewrite the backlog on every
    /// read of it — and, through the watcher, on its own write.
    func testASecondLoadOfTheMigratedFileChangesNothing() throws {
        let vm = try makeViewModel()
        let afterMigration = try String(contentsOf: backlogURL, encoding: .utf8)

        vm.reload()

        XCTAssertEqual(try String(contentsOf: backlogURL, encoding: .utf8), afterMigration)
        XCTAssertEqual(lanes(in: vm.backlogFile),
                       ["task-1": .now, "task-2": .now, "task-3": .later])
    }

    /// A backlog that never had a `Now` epic is not rewritten at all.
    func testAFileWithNoNowEpicIsLeftByteForByteAsItWas() throws {
        let written = """
        ---
        project: demo
        ---

        # Demo Backlog

        ## Epic: Onboarding

        - [ ] task-3 | Third task | ready
        """
        try written.write(to: backlogURL, atomically: true, encoding: .utf8)

        let vm = BacklogViewModel(globalConfigStore:
            GlobalConfigStore(storageURL: tempDir.appending(path: "global-config.json")))
        vm.loadForProject(repoPath: tempDir.path(percentEncoded: false))

        XCTAssertEqual(try String(contentsOf: backlogURL, encoding: .utf8), written)
        XCTAssertEqual(lanes(in: vm.backlogFile), ["task-3": .later])
    }

    private func lanes(in file: BacklogFile?) -> [String: BacklogLane] {
        Dictionary(uniqueKeysWithValues: (file?.sections ?? []).flatMap(\.items).map { ($0.id, $0.lane) })
    }

    private func makeViewModel() throws -> BacklogViewModel {
        try backlogWithANowEpic.write(to: backlogURL, atomically: true, encoding: .utf8)
        let vm = BacklogViewModel(globalConfigStore:
            GlobalConfigStore(storageURL: tempDir.appending(path: "global-config.json")))
        vm.loadForProject(repoPath: tempDir.path(percentEncoded: false))
        XCTAssertEqual(vm.backlogURL?.lastPathComponent, "BACKLOG.md")
        return vm
    }
}
