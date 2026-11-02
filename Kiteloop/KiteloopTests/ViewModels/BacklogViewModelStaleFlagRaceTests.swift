import XCTest
import KiteloopCore
@testable import Kiteloop

/// Two stale sweeps overlapping, which during a run is the normal case rather
/// than the rare one: `reload()` is what `BacklogFileWatcher` calls on every
/// write to the backlog, and a run writes it on every status change and every
/// appended note. Each reload used to start an unserialised sweep — one `git
/// log` per open item — and assign `staleFlags` whenever git happened to come
/// back, so the sweep that started first could finish last and overwrite the
/// newer reading with flags computed from a backlog that had already moved.
///
/// The git side is scripted (`ScriptedSubprocessRunner`) rather than run against
/// a real checkout: that is the only way to hold one sweep inside git while the
/// other finishes, which is exactly the ordering the drawer used to show the
/// wrong answer for.
@MainActor
final class BacklogViewModelStaleFlagRaceTests: XCTestCase {
    private var projectRoot: URL!

    /// The item the backlog carries on disk. Its `git log` is what says the
    /// sweep the project's own first reload starts has read the backlog it was
    /// given, so a case can state its own reading afterwards without racing it.
    private let seedPath = "backlog/seed-1.md"

    /// Well outside `StaleItemSweep.window`, and well inside it — the two
    /// answers the scripted `git log` gives.
    private let staleSeconds = Int(Date().addingTimeInterval(-90 * 24 * 60 * 60).timeIntervalSince1970)
    private let freshSeconds = Int(Date().timeIntervalSince1970)

    override func setUpWithError() throws {
        projectRoot = try makeTemporaryDirectory(prefix: "backlog-stale-race")
    }

    // MARK: - The race

    /// The measured defect: the older reading landing last. The first sweep is
    /// held inside git until the second has finished and assigned, and its
    /// result must then be dropped rather than applied.
    func testASupersededSweepDoesNotOverwriteTheNewerReading() async throws {
        let holdFirstSweep = DispatchSemaphore(value: 0)
        let runner = scriptedGit(holding: "backlog/old-1.md", on: holdFirstSweep)

        try await withScriptedSubprocesses(runner) {
            let vm = try await makeBranchBackedViewModel(runner)

            vm.backlogFile = groomed(["old-1"])
            let first = Task { await vm.refreshStaleFlags() }
            try await eventually("the first sweep is inside git") { sweepPaths(runner) == ["backlog/old-1.md"] }

            vm.backlogFile = groomed(["old-2"])
            await Task { await vm.refreshStaleFlags() }.value
            XCTAssertEqual(vm.staleFlags.map(\.itemID), ["old-2"], "the second sweep's reading is the one on show")

            holdFirstSweep.signal()
            await first.value
            XCTAssertEqual(vm.staleFlags.map(\.itemID), ["old-2"],
                           "the superseded sweep's reading was applied over the newer one")
        }
    }

    /// And it stops paying for a reading nobody will use: the items the
    /// superseded sweep had not yet reached are never asked about.
    func testASupersededSweepStopsSpawningGit() async throws {
        let holdFirstSweep = DispatchSemaphore(value: 0)
        let runner = scriptedGit(holding: "backlog/old-1.md", on: holdFirstSweep)

        try await withScriptedSubprocesses(runner) {
            let vm = try await makeBranchBackedViewModel(runner)

            vm.backlogFile = groomed(["old-1", "old-2", "old-3"])
            let first = Task { await vm.refreshStaleFlags() }
            try await eventually("the first sweep is inside git") { sweepPaths(runner) == ["backlog/old-1.md"] }

            vm.backlogFile = groomed(["old-4"])
            await Task { await vm.refreshStaleFlags() }.value

            holdFirstSweep.signal()
            await first.value

            XCTAssertEqual(sweepPaths(runner), ["backlog/old-1.md", "backlog/old-4.md"],
                           "the superseded sweep kept shelling out for items nobody was waiting on")
        }
    }

    // MARK: - What the ordering guard must not change

    /// One refresh with nothing racing it reads exactly what it read before:
    /// the old open item flagged, the fresh one not, the old finished one never
    /// judged.
    func testASingleRefreshFlagsTheSameItemsAsBefore() async throws {
        let runner = scriptedGit(holding: nil, on: nil)

        try await withScriptedSubprocesses(runner) {
            let vm = try await makeBranchBackedViewModel(runner)
            vm.backlogFile = BacklogParser.parse("""
            # Demo Backlog

            ## Epic: Now

            - [ ] old-1 | An old open item | ready | size: S → [detail](backlog/old-1.md)
            - [ ] fresh-1 | A recently touched item | ready | size: S → [detail](backlog/fresh-1.md)
            - [x] done-1 | An old finished item | done | size: S → [detail](backlog/done-1.md)

            """)

            await vm.refreshStaleFlags()

            XCTAssertEqual(vm.staleFlags.map(\.itemID), ["old-1"])
            XCTAssertEqual(vm.staleFlags.first?.status, .ready)
        }
    }

    /// A project with no branch-backed backlog has no history to read: the
    /// cache is cleared and no git runs at all, exactly as before.
    func testAProjectWithNoBranchBackedBacklogClearsTheFlagsAndStartsNoSweep() async throws {
        let runner = scriptedGit(holding: nil, on: nil)

        try await withScriptedSubprocesses(runner) {
            let vm = try await makeBranchBackedViewModel(runner)
            vm.backlogFile = groomed(["old-1"])
            await vm.refreshStaleFlags()
            XCTAssertEqual(vm.staleFlags.map(\.itemID), ["old-1"], "precondition: something to clear")

            let asked = sweepPaths(runner)
            let plainProject = try makeTemporaryDirectory(prefix: "backlog-stale-plain")
            try writeSeedBacklog(at: plainProject.appending(path: "BACKLOG.md"))
            vm.loadForProject(repoPath: plainProject.path(percentEncoded: false))

            await vm.refreshStaleFlags()

            XCTAssertTrue(vm.staleFlags.isEmpty)
            XCTAssertEqual(sweepPaths(runner), asked, "a backlog with no branch behind it started a sweep")
        }
    }

    // MARK: - Helpers

    /// A `git log` answering with a timestamp outside the staleness window for
    /// every item but the freshly touched ones, and parking inside the call for
    /// `holding` until `gate` is signalled — the app's own sweep held mid-read,
    /// without a repository.
    private func scriptedGit(holding: String?, on gate: DispatchSemaphore?) -> ScriptedSubprocessRunner {
        let stale = staleSeconds, fresh = freshSeconds, seed = seedPath
        return ScriptedSubprocessRunner { call in
            guard call.arguments.first == "log" else { return .init(status: 1) }
            let path = call.arguments.last ?? ""
            if let holding, let gate, path == holding { gate.wait() }
            let touched = (path == seed || path == "backlog/fresh-1.md") ? fresh : stale
            return .init(output: "\(touched)\n")
        }
    }

    /// The paths the scripted git was asked about, in order, past the reading
    /// the project's own first reload took — `BacklogBranch`'s fetch and merge
    /// traffic from opening the project is not this sweep's, and is left out.
    private func sweepPaths(_ runner: ScriptedSubprocessRunner) -> [String] {
        let logged = runner.calls.filter { $0.arguments.first == "log" }.map { $0.arguments.last ?? "" }
        return Array(logged.drop { $0 == seedPath })
    }

    /// A view model reading a backlog on the shared branch — the only shape
    /// that sweeps at all, since the sweep reads `.kiteloop/backlog-tree`'s own
    /// git history. Returns once the reload that opening the project performs
    /// has taken its own reading, so a case's refreshes are the only ones left
    /// in flight.
    private func makeBranchBackedViewModel(_ runner: ScriptedSubprocessRunner) async throws -> BacklogViewModel {
        let checkout = BacklogBranch.checkoutURL(projectRoot: projectRoot)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try writeSeedBacklog(at: checkout.appending(path: "BACKLOG.md"))
        let vm = BacklogViewModel(
            globalConfigStore: GlobalConfigStore(storageURL: projectRoot.appending(path: "global-config.json"))
        )
        vm.loadForProject(repoPath: projectRoot.path(percentEncoded: false))
        try await eventually("the project's own first sweep has read git") {
            runner.calls.contains { $0.arguments.last == seedPath }
        }
        return vm
    }

    private func writeSeedBacklog(at url: URL) throws {
        try """
        # Demo Backlog

        ## Epic: Now

        - [ ] seed-1 | The item the project opens on | ready | size: S → [detail](\(seedPath))

        """.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A backlog of open, groomed items — one detail file each, so each one is
    /// a `git log` the sweep has to make.
    private func groomed(_ ids: [String]) -> BacklogFile {
        let lines = ids.map { "- [ ] \($0) | Open item \($0) | ready | size: S → [detail](backlog/\($0).md)" }
        return BacklogParser.parse("""
        # Demo Backlog

        ## Epic: Now

        \(lines.joined(separator: "\n"))

        """)
    }
}
