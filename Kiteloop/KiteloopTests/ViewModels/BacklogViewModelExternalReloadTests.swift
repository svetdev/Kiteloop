import XCTest
import KiteloopCore
@testable import Kiteloop

/// Edits made to the backlog from *outside* the app have to reach the running
/// app. Everything that reads the backlog — the panel, `GET /v1/backlog`, and
/// the Definition-of-Ready gate autopilot runs at pickup — goes through the
/// view model's in-memory `backlogFile`, so a stale one is not a display bug: it
/// is seven groomed items failing the gate with "no groomed detail file" while
/// the queue reports itself empty, which is what happened on 2026-08-08.
///
/// These tests drive real writes against a real watcher rather than calling
/// `reload()` directly — calling it directly was always going to pass, and never
/// did tell us anything about whether the edit arrives.
@MainActor
final class BacklogViewModelExternalReloadTests: XCTestCase {
    private var tempDir: URL!
    private var backlogURL: URL!

    /// The watcher's default debounce is 1s; give a change comfortably longer
    /// than that before calling it lost.
    private let settleTimeout: TimeInterval = 5

    private let sampleBacklog = """
    ---
    project: demo
    verify_default: swift build
    ---

    # Demo Backlog

    ## Epic: Now

    - [ ] task-1 | First task | ready | size: S
    """

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "backlog-external-reload")
        backlogURL = tempDir.appending(path: "BACKLOG.md")
    }

    // MARK: - The edit arrives

    /// The measured failure: a marker written into the backlog file by another
    /// process, still absent from the app's view of it seconds later.
    func testExternalEditAppearsWithoutReopeningTheProject() async throws {
        let vm = try makeViewModel()
        XCTAssertEqual(ids(vm), ["task-1"])

        try replaceExternally(sampleBacklog + "\n- [ ] task-2 | Added from outside | ready | size: S\n")

        try await waitUntil("task-2 is visible") { self.ids(vm).contains("task-2") }
        XCTAssertEqual(self.item(vm, "task-2")?.title, "Added from outside")
    }

    /// An in-place rewrite (truncate + write, no rename) is the other half of how
    /// external writers behave.
    func testExternalInPlaceRewriteAppears() async throws {
        let vm = try makeViewModel()

        try (sampleBacklog + "\n- [ ] task-2 | Written in place | ready | size: S\n")
            .write(to: backlogURL, atomically: false, encoding: .utf8)

        try await waitUntil("task-2 is visible") { self.ids(vm).contains("task-2") }
    }

    /// Two replacements in a row: the second one is the one that used to be lost,
    /// because the first orphaned the watcher's file descriptor.
    func testSecondExternalReplacementIsStillSeen() async throws {
        let vm = try makeViewModel()

        try replaceExternally(sampleBacklog + "\n- [ ] task-2 | First replacement | ready | size: S\n")
        try await waitUntil("task-2 is visible") { self.ids(vm).contains("task-2") }

        try replaceExternally(sampleBacklog + "\n- [ ] task-3 | Second replacement | ready | size: S\n")
        try await waitUntil("task-3 is visible") { self.ids(vm).contains("task-3") }
    }

    // MARK: - What the edit was for

    /// The consequence that cost a queue: an item groomed entirely outside the
    /// app — detail file written, `→ [detail](…)` link added to its line — has to
    /// pass the Definition-of-Ready gate on the running app, not only after a
    /// restart.
    func testExternallyGroomedItemPassesDefinitionOfReady() async throws {
        let vm = try makeViewModel()
        XCTAssertFalse(
            DefinitionOfReady.evaluate(item: try XCTUnwrap(item(vm, "task-1")),
                                       detail: vm.loadDetail(for: try XCTUnwrap(item(vm, "task-1")))).isReady,
            "Precondition: ungroomed to start with"
        )

        try writeDetail(for: "task-1")
        try replaceExternally("""
        ---
        project: demo
        verify_default: swift build
        ---

        # Demo Backlog

        ## Epic: Now

        - [ ] task-1 | First task | ready | size: S → [detail](backlog/task-1.md)

        """)

        try await waitUntil("the detail link is visible") {
            self.item(vm, "task-1")?.detailPath != nil
        }
        let groomed = try XCTUnwrap(item(vm, "task-1"))
        let verdict = DefinitionOfReady.evaluate(item: groomed, detail: vm.loadDetail(for: groomed))
        XCTAssertTrue(verdict.isReady, "still not ready: \(verdict.summary)")
    }

    // MARK: - Re-opening the project

    /// `POST /v1/projects/open` on an already-open project runs `refresh()`. It
    /// used to return success while changing nothing, which is the trap that hid
    /// the stale backlog: the caller was told it worked.
    func testRefreshPicksUpAnExternalEdit() throws {
        let vm = try makeViewModel()

        try replaceExternally(sampleBacklog + "\n- [ ] task-2 | Added from outside | ready | size: S\n")
        vm.refresh()

        XCTAssertTrue(ids(vm).contains("task-2"))
    }

    /// `refresh()` re-arms the watcher rather than leaving a project reading a
    /// dead one — a driver that re-opens a project is entitled to a session that
    /// keeps seeing edits afterwards.
    func testRefreshLeavesTheProjectStillWatching() async throws {
        let vm = try makeViewModel()

        vm.refresh()
        try replaceExternally(sampleBacklog + "\n- [ ] task-2 | After the refresh | ready | size: S\n")

        try await waitUntil("task-2 is visible after refresh") { self.ids(vm).contains("task-2") }
    }

    // MARK: - The app's own writes

    /// The reload reads the file the app just wrote, so a status set in Kiteloop
    /// has to survive it. A reload that clobbered in-app state would trade one
    /// invisible edit for another.
    func testStatusWrittenByTheAppSurvivesTheReloadItTriggers() async throws {
        let vm = try makeViewModel()

        vm.updateItemStatus(itemID: "task-1", newStatus: .active)
        // The app writes atomically, so its own write also wakes the watcher;
        // wait past the debounce and confirm the reload agreed with it.
        try await Task.sleep(for: .seconds(2))

        XCTAssertEqual(item(vm, "task-1")?.status, .active)
        let onDisk = BacklogParser.parse(try String(contentsOf: backlogURL, encoding: .utf8))
        XCTAssertEqual(onDisk.sections.flatMap(\.items).first { $0.id == "task-1" }?.status, .active)
    }

    /// The reverse direction of the same rule: an external status change wins,
    /// because the file is the source of truth once the app isn't mid-write.
    func testExternalStatusChangeReplacesTheInMemoryOne() async throws {
        let vm = try makeViewModel()
        vm.updateItemStatus(itemID: "task-1", newStatus: .active)
        XCTAssertEqual(item(vm, "task-1")?.status, .active)

        try replaceExternally("""
        ---
        project: demo
        verify_default: swift build
        ---

        # Demo Backlog

        ## Epic: Now

        - [ ] task-1 | First task | blocked | size: S

        """)

        try await waitUntil("the external status arrives") { self.item(vm, "task-1")?.status == .blocked }
    }

    // MARK: - Helpers

    private func makeViewModel() throws -> BacklogViewModel {
        try sampleBacklog.write(to: backlogURL, atomically: true, encoding: .utf8)
        let vm = BacklogViewModel(
            globalConfigStore: GlobalConfigStore(storageURL: tempDir.appending(path: "global-config.json"))
        )
        vm.loadForProject(repoPath: tempDir.path(percentEncoded: false))
        XCTAssertEqual(vm.backlogURL?.lastPathComponent, "BACKLOG.md")
        return vm
    }

    /// Rewrites the backlog from *another process* the way an editor or an agent
    /// does — content into a temp file, then `mv` over the original. The rename
    /// unlinks the inode the watcher holds open, which is the case the in-memory
    /// backlog used to survive unchanged.
    private func replaceExternally(_ contents: String) throws {
        let staging = tempDir.appending(path: "staging-\(UUID().uuidString)")
        try contents.write(to: staging, atomically: false, encoding: .utf8)
        let mv = Process()
        mv.executableURL = URL(fileURLWithPath: "/bin/mv")
        mv.arguments = [staging.path(percentEncoded: false), backlogURL.path(percentEncoded: false)]
        try mv.run()
        mv.waitUntilExit()
        XCTAssertEqual(mv.terminationStatus, 0, "external replace failed")
    }

    /// A groomed `backlog/<id>.md`: What, How and Validation, as the gate wants.
    private func writeDetail(for id: String) throws {
        let dir = tempDir.appending(path: "backlog")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        ---
        id: \(id)
        title: First task
        size: S
        verify:
          - name: build
            cmd: "swift build"
        ---

        ## What

        The outcome this item delivers.

        ## How

        Touch these files, follow this pattern.

        ## Validation

        - [ ] The observable behaviour that proves it works

        ## Out of Scope

        - Anything else
        """.write(to: dir.appending(path: "\(id).md"), atomically: true, encoding: .utf8)
    }

    private func ids(_ vm: BacklogViewModel) -> [String] {
        vm.backlogFile?.sections.flatMap(\.items).map(\.id) ?? []
    }

    private func item(_ vm: BacklogViewModel, _ id: String) -> BacklogItem? {
        vm.backlogFile?.sections.flatMap(\.items).first { $0.id == id }
    }

    /// Polls on the main actor, which is also where the watcher's reload lands —
    /// sleeping here is what lets it run.
    private func waitUntil(
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor @Sendable () -> Bool
    ) async throws {
        try await eventually(timeout: .seconds(settleTimeout), what, file: file, line: line) { await condition() }
    }
}

/// The shared backlog branch — `kiteloop/backlog`, the gh-pages pattern from
/// `docs/backlog-branch.md` — exercised against real git repos in a temp dir.
/// In this file rather than its own because it is the other answer to the same
/// question the tests above cover: where the backlog lives and how changes to
/// it reach the app.
final class BacklogBranchTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "backlog-branch")
    }

    @discardableResult
    private func sh(_ args: [String], cwd: URL) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = cwd
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// A repo with one commit on main, and a bare sibling wired as `origin` —
    /// the smallest thing that behaves like a team's remote.
    private func makeRepoWithRemote(named name: String) throws -> (repo: URL, bare: URL) {
        let repo = tempDir.appending(path: name, directoryHint: .isDirectory)
        let bare = tempDir.appending(path: "\(name)-remote.git", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        sh(["init", "-q", "-b", "main"], cwd: repo)
        sh(["config", "user.email", "test@kiteloop.test"], cwd: repo)
        sh(["config", "user.name", "Kiteloop Tests"], cwd: repo)
        sh(["commit", "--allow-empty", "-q", "-m", "init"], cwd: repo)
        sh(["init", "-q", "--bare", bare.path(percentEncoded: false)], cwd: tempDir)
        sh(["remote", "add", "origin", bare.path(percentEncoded: false)], cwd: repo)
        sh(["push", "-q", "origin", "main"], cwd: repo)
        return (repo, bare)
    }

    func testCreateSharedMakesAnOrphanBranchWithoutTouchingTheTree() throws {
        let (repo, bare) = try makeRepoWithRemote(named: "alpha")

        let url = BacklogBranch.createShared(projectRoot: repo, projectName: "alpha")

        let fileURL = try XCTUnwrap(url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))
        // Orphan: exactly one commit, no parent shared with main.
        let count = sh(["rev-list", "--count", BacklogBranch.branchName], cwd: repo)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(count, "1")
        // The project's own working tree is untouched — nothing tracked
        // changed, and the checkout hides inside .kiteloop/.
        let status = sh(["status", "--porcelain"], cwd: repo)
        XCTAssertFalse(status.contains("BACKLOG"), "the backlog must not appear in the main tree: \(status)")
        // And the push reached the remote.
        let remoteHas = sh(["show-ref", "--verify", "refs/heads/\(BacklogBranch.branchName)"], cwd: bare)
        XCTAssertFalse(remoteHas.isEmpty, "createShared should push the branch to origin")
    }

    func testAdoptMaterializesTheBranchOnAFreshClone() throws {
        let (repo, bare) = try makeRepoWithRemote(named: "beta")
        _ = try XCTUnwrap(BacklogBranch.createShared(projectRoot: repo, projectName: "beta"))
        _ = bare

        // The teammate's machine: a fresh clone, which knows the branch only
        // as a remote-tracking ref.
        let clone = tempDir.appending(path: "beta-clone", directoryHint: .isDirectory)
        sh(["clone", "-q", tempDir.appending(path: "beta-remote.git").path(percentEncoded: false),
            clone.path(percentEncoded: false)], cwd: tempDir)
        sh(["config", "user.email", "test@kiteloop.test"], cwd: clone)
        sh(["config", "user.name", "Kiteloop Tests"], cwd: clone)

        XCTAssertEqual(BacklogBranch.availability(projectRoot: clone), .adoptable)
        let adopted = BacklogBranch.adopt(projectRoot: clone)
        let fileURL = try XCTUnwrap(adopted)
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("# beta Backlog"))
        XCTAssertEqual(BacklogBranch.availability(projectRoot: clone), .checkedOut)
    }

    func testCommitChangesAndSyncReachTheRemote() throws {
        let (repo, bare) = try makeRepoWithRemote(named: "gamma")
        let fileURL = try XCTUnwrap(BacklogBranch.createShared(projectRoot: repo, projectName: "gamma"))

        try "# gamma Backlog\n\n## Epic: Inbox\n- [ ] one | First item | ready\n"
            .write(to: fileURL, atomically: true, encoding: .utf8)
        BacklogBranch.commitChanges(projectRoot: repo, message: "kiteloop: backlog update")
        // The commit always lands; the push inside commitChanges is
        // rate-limited and createShared just pushed, so sync is the reliable
        // path to the remote.
        BacklogBranch.sync(projectRoot: repo)

        let remoteTip = sh(["rev-list", "--count", BacklogBranch.branchName], cwd: bare)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(remoteTip, "2", "the second commit should have been pushed")
    }
}

/// Creating the shared branch from the empty state. `createShared` ends in a
/// `git push` that may take up to its two-minute deadline, so the view model
/// must await it off the main actor — a held main actor is a window that does
/// not redraw and a control server that does not answer. The git side is
/// scripted, which is what lets a case park the push until it says so.
@MainActor
final class BacklogViewModelCreateBranchTests: XCTestCase {
    private var projectRoot: URL!

    /// Outside `StaleItemSweep.window` — what the scripted `git log` answers, so
    /// a sweep over a branch-backed backlog flags every item it is asked about.
    private let staleSeconds = Int(Date().addingTimeInterval(-90 * 24 * 60 * 60).timeIntervalSince1970)

    override func setUpWithError() throws {
        projectRoot = try makeTemporaryDirectory(prefix: "backlog-create-branch")
    }

    /// The push is held inside git; main-actor work scheduled meanwhile still
    /// runs, and the end state lands once the test lets the push return.
    func testThePushDoesNotHoldTheMainActor() async throws {
        let releasePush = DispatchSemaphore(value: 0)
        let runner = scriptedGit(worktreeStatus: 0, holdingPushOn: releasePush)
        // A main actor held for the push could never reach the signal below;
        // this lets the push go regardless, so that regression fails the
        // assertions instead of hanging the case.
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { releasePush.signal() }

        try await withScriptedSubprocesses(runner) {
            let vm = makeEmptyProjectViewModel()
            let creating = Task { await vm.createBranchBacklog() }
            try await eventually("the push is inside git") { pushCalls(runner).count == 1 }

            let ranOnMain = await Task { @MainActor in true }.value
            XCTAssertTrue(ranOnMain, "main-actor work did not run while the push was held")
            XCTAssertNil(vm.backlogURL, "the backlog was adopted before the push returned")
            XCTAssertTrue(vm.noBacklogFound)

            releasePush.signal()
            await creating.value

            XCTAssertEqual(vm.backlogURL, BacklogBranch.backlogFileURL(projectRoot: projectRoot))
            XCTAssertFalse(vm.noBacklogFound)
            XCTAssertNil(vm.errorMessage)
            await assertBranchBacked(vm, runner, true)
        }
    }

    /// The command set is the one `createShared` always ran, push included —
    /// only where it is awaited from moved.
    func testCreateRunsTheSameGitCommandsIncludingThePush() async throws {
        let runner = scriptedGit(worktreeStatus: 0, holdingPushOn: nil)

        try await withScriptedSubprocesses(runner) {
            let vm = makeEmptyProjectViewModel()
            let before = runner.calls.count
            await vm.createBranchBacklog()

            // The stale sweep the adopting reload starts reads `git log`; that
            // traffic is not `createShared`'s.
            let created = runner.calls.dropFirst(before).map(\.arguments).filter { $0.first != "log" }
            XCTAssertEqual(created, [
                ["worktree", "add", "--orphan", "-b", BacklogBranch.branchName,
                 BacklogBranch.checkoutURL(projectRoot: projectRoot).path(percentEncoded: false)],
                ["add", "-A"],
                ["commit", "-m", "kiteloop: shared backlog"],
                ["push", "-u", "origin", BacklogBranch.branchName],
            ])
        }
    }

    /// A branch git refuses to create names the failure and adopts nothing.
    func testAFailedCreateSetsTheErrorAndStaysUnbacked() async throws {
        let runner = scriptedGit(worktreeStatus: 128, holdingPushOn: nil)

        try await withScriptedSubprocesses(runner) {
            let vm = makeEmptyProjectViewModel()
            await vm.createBranchBacklog()

            XCTAssertEqual(vm.errorMessage, "Couldn't create the shared backlog branch — see the log")
            XCTAssertNil(vm.backlogURL)
            XCTAssertTrue(vm.noBacklogFound)
            XCTAssertTrue(pushCalls(runner).isEmpty)
            await assertBranchBacked(vm, runner, false)
        }
    }

    // MARK: - Helpers

    /// `show-ref` finds no branch, so the project opens empty; `worktree add`
    /// answers `worktreeStatus`, making the checkout directory as the real
    /// command would when it succeeds; `push` parks on `gate`; `log` answers
    /// stale.
    private func scriptedGit(worktreeStatus: Int32, holdingPushOn gate: DispatchSemaphore?) -> ScriptedSubprocessRunner {
        let checkout = BacklogBranch.checkoutURL(projectRoot: projectRoot)
        let stale = staleSeconds
        return ScriptedSubprocessRunner { call in
            switch call.arguments.first {
            case "show-ref":
                return .init(status: 1)
            case "worktree":
                if worktreeStatus == 0 {
                    try? FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
                }
                return .init(status: worktreeStatus)
            case "push":
                gate?.wait()
                return .init()
            case "log":
                return .init(output: "\(stale)\n")
            default:
                return .init()
            }
        }
    }

    private func pushCalls(_ runner: ScriptedSubprocessRunner) -> [ScriptedSubprocessRunner.Call] {
        runner.calls.filter { $0.arguments.first == "push" }
    }

    /// A project with no backlog anywhere — the empty state that offers the
    /// shared branch.
    private func makeEmptyProjectViewModel() -> BacklogViewModel {
        let vm = BacklogViewModel(
            globalConfigStore: GlobalConfigStore(storageURL: projectRoot.appending(path: "global-config.json"))
        )
        vm.loadForProject(repoPath: projectRoot.path(percentEncoded: false))
        XCTAssertTrue(vm.noBacklogFound, "precondition: the project opens with no backlog")
        return vm
    }

    /// Whether the view model holds the project root as branch-backed, read
    /// through the stale sweep — the reader of that root that answers from
    /// outside: it flags an old item only when there is a branch checkout to
    /// read the history of.
    private func assertBranchBacked(
        _ vm: BacklogViewModel,
        _ runner: ScriptedSubprocessRunner,
        _ expected: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        vm.backlogFile = BacklogParser.parse("""
        # Demo Backlog

        ## Epic: Now

        - [ ] old-1 | An old open item | ready | size: S → [detail](backlog/old-1.md)

        """)
        await vm.refreshStaleFlags()
        XCTAssertEqual(vm.staleFlags.map(\.itemID), expected ? ["old-1"] : [], file: file, line: line)
    }
}

/// A backlog or detail file holding a byte that is not UTF-8 — a character cut
/// off by a hand edit or a truncated sync. It used to fail the strict read, so
/// the whole project showed no items and a note could not be added.
@MainActor
final class BacklogViewModelBadByteTests: XCTestCase {
    private var tempDir: URL!
    private var backlogURL: URL!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "backlog-bad-byte")
        backlogURL = tempDir.appending(path: "BACKLOG.md")
    }

    func testABadByteBetweenItemsStillListsBoth() throws {
        let vm = try makeViewModel(backlog: Data("""
        # Demo Backlog

        ## Epic: Now

        - [ ] task-1 | First task | ready | size: S

        """.utf8) + Data([0xFF]) + Data("""

        - [ ] task-2 | Second task | ready | size: S

        """.utf8))

        vm.reload()

        XCTAssertEqual(vm.backlogFile?.sections.flatMap(\.items).map(\.id), ["task-1", "task-2"])
        XCTAssertNil(vm.errorMessage)
    }

    func testAMissingBacklogIsStillReportedAsUnreadable() throws {
        let vm = try makeViewModel(backlog: Data("# Demo Backlog\n".utf8))
        try FileManager.default.removeItem(at: backlogURL)

        vm.reload()

        XCTAssertEqual(vm.errorMessage, "Cannot read backlog file")
    }

    func testANoteIsAddedToADetailFileWithABadByte() throws {
        let detailDir = tempDir.appending(path: "backlog")
        try FileManager.default.createDirectory(at: detailDir, withIntermediateDirectories: true)
        let detailURL = detailDir.appending(path: "task-1.md")
        try (Data("## What\n\nBefore the byte ".utf8) + Data([0xFF]) + Data(" after the byte.\n".utf8))
            .write(to: detailURL)
        let vm = try makeViewModel(backlog: Data("""
        # Demo Backlog

        ## Epic: Now

        - [ ] task-1 | First task | ready | size: S → [detail](backlog/task-1.md)

        """.utf8))

        XCTAssertTrue(vm.appendNote(itemID: "task-1", "the new note"))

        let written = try String(contentsOf: detailURL, encoding: .utf8)
        XCTAssertTrue(written.contains("the new note"))
        XCTAssertTrue(written.contains("Before the byte "))
        XCTAssertTrue(written.contains(" after the byte."))
    }

    private func makeViewModel(backlog: Data) throws -> BacklogViewModel {
        try backlog.write(to: backlogURL)
        let vm = BacklogViewModel(
            globalConfigStore: GlobalConfigStore(storageURL: tempDir.appending(path: "global-config.json"))
        )
        vm.loadForProject(repoPath: tempDir.path(percentEncoded: false))
        XCTAssertEqual(vm.backlogURL?.lastPathComponent, "BACKLOG.md")
        return vm
    }
}
