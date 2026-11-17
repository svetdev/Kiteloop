import XCTest
@testable import KiteloopCore

/// `ProcessTree.terminateAll` is what every teardown path that owns more than
/// one root process — right now just `ClaudeCodeCLIRuntime` — hands its
/// processes to, instead of signalling each root alone and leaving whatever it
/// forked running and reparented.
final class ProcessTreeTests: XCTestCase {

    /// Every child these tests spawn sleeps for a number no other test run on
    /// the machine uses: `81`, this test process's pid, then the case's own two
    /// digits. Several runs share a machine — a suite beside an item's
    /// `verify:`, one worktree beside another — and a marker they all spelled
    /// the same let one run's wipe kill another's children mid-test, and let
    /// one run's "is it gone" find another's child still alive.
    private static let runPrefix = String(format: "81%05d", getpid())

    private static func marker(_ testCase: Int) -> String {
        runPrefix + String(format: "%02d", testCase)
    }

    /// A run under a mutant that disables the kill — mutate-core runs exactly
    /// those — would leave these children alive for years, and a later process
    /// handed the same pid would find "the forked child" already there. So the
    /// slate is wiped around each test, by this run's prefix alone, with a kill
    /// that does not lean on the code under test.
    override func setUpWithError() throws { Self.wipeThisRunsChildren() }
    override func tearDownWithError() throws { Self.wipeThisRunsChildren() }

    private static func wipeThisRunsChildren() {
        commandOutput("/usr/bin/pkill", ["-9", "-f", "sleep \(runPrefix)"])
    }

    // MARK: - A root and everything it forked

    /// A root spawned as `/bin/zsh -lc "sleep <n> & wait"` forks `sleep` as a
    /// child of the shell. `terminateAll` must collect that descendant before
    /// signalling the shell — `descendantPIDs(of:)` can only walk `pgrep -P`
    /// while the child is still reparented under a live shell — so the forked
    /// child has been signalled by the time the call returns.
    @MainActor
    func testARootsForkedChildIsGoneWhenTheCallReturns() async throws {
        let process = spawn(["-lc", "sleep \(Self.marker(1)) & wait"])
        try await forkedSleepsToStart(["sleep \(Self.marker(1))"])
        ProcessTree.terminateAll([process])
        try await eventually("the forked child to be gone") {
            !Self.isProcessRunning(matching: "sleep \(Self.marker(1))")
        }
    }

    /// A root that traps and ignores SIGTERM must still be gone when the call
    /// returns — the escalation to SIGKILL is what makes that true.
    ///
    /// Both tests here wait for the shell to have started its `sleep` first: a
    /// child born after the `pgrep -P` walk is not a descendant, so a call that
    /// lands in that window orphans it. And both wait for the processes to be
    /// gone rather than looking once: SIGKILL has been sent when the call
    /// returns, and the kernel ends the process when it is next scheduled.
    @MainActor
    func testARootThatIgnoresSIGTERMIsGoneWhenTheCallReturns() async throws {
        let process = spawn(["-lc", "trap '' TERM; sleep \(Self.marker(2))"])
        try await forkedSleepsToStart(["sleep \(Self.marker(2))"])
        ProcessTree.terminateAll([process])
        try await eventually("the root ignoring SIGTERM, and its sleep, to be gone") {
            !Self.isProcessRunning(matching: "sleep \(Self.marker(2))")
        }
    }

    /// The sweep only reaches pids collected as descendants of the roots it
    /// was given — never anything merely matching the killed command's text.
    func testABystanderThatOnlySharesTheKilledCommandsTextSurvives() {
        let bystander = Process()
        bystander.executableURL = URL(fileURLWithPath: "/bin/sleep")
        bystander.arguments = [Self.marker(3)]
        try? bystander.run()
        defer {
            bystander.terminate()
            bystander.waitUntilExit()
        }

        let process = spawn(["-lc", "sleep \(Self.marker(3)) & wait"])
        ProcessTree.terminateAll([process])

        XCTAssertTrue(bystander.isRunning,
                       "a process outside the roots handed to this call must not be touched")
    }

    // MARK: - Batching

    /// `terminateAll` must wait out the grace period exactly once however many
    /// roots and descendants it is handed, so these tests hand it the grace
    /// period and count the calls. A sweep that pays a second one — the roots
    /// first and then their descendants — counts two. Timing the call instead
    /// measured the `pgrep` per node of the walk as well, which on a busy
    /// machine alone runs past any bound set between one period and two.
    private final class GracePeriods {
        private(set) var waited = 0
        func wait() { waited += 1 }
    }

    /// Two roots handed to one call must both be swept, and the call pays the
    /// grace period once rather than once per root.
    @MainActor
    func testTwoRootsInOneCallAreBothSweptAndPayOneGracePeriod() async throws {
        let first = spawn(["-lc", Self.rootIgnoringTERMForking(Self.marker(4))])
        let second = spawn(["-lc", Self.rootIgnoringTERMForking(Self.marker(5))])
        try await forkedSleepsToStart(["sleep \(Self.marker(4))", "sleep \(Self.marker(5))"])

        let gracePeriods = GracePeriods()
        ProcessTree.terminateAll([first, second], gracePeriod: gracePeriods.wait)

        XCTAssertEqual(gracePeriods.waited, 1, "two roots should not each pay their own grace period")
        try await eventually("both roots and their forked sleeps to be gone") {
            !Self.isProcessRunning(matching: "sleep \(Self.marker(4))")
                && !Self.isProcessRunning(matching: "sleep \(Self.marker(5))")
        }
    }

    /// A single root that ignores SIGTERM and forks a child pays that same one
    /// grace period between them: the root and the descendants collected from
    /// it are signalled together, not one set after the other.
    @MainActor
    func testARootAndItsForkedChildPayOneGracePeriodBetweenThem() async throws {
        let process = spawn(["-lc", Self.rootIgnoringTERMForking(Self.marker(6))])
        try await forkedSleepsToStart(["sleep \(Self.marker(6))"])

        let gracePeriods = GracePeriods()
        ProcessTree.terminateAll([process], gracePeriod: gracePeriods.wait)

        XCTAssertEqual(gracePeriods.waited, 1,
                       "a root and its descendants should not each pay their own grace period")
        // `pgrep -f` matches the root shell too: the marker is in its argv.
        try await eventually("the TERM-ignoring root and the child it forked to be gone") {
            !Self.isProcessRunning(matching: "sleep \(Self.marker(6))")
        }
    }

    /// A shell that ignores SIGTERM and forks a child that ignores it too —
    /// the child `exec`s `sleep`, so the ignored disposition survives into a
    /// process whose command line is exactly `sleep <marker>`. Both halves
    /// have to outlive TERM for the KILL that follows the grace period to be
    /// what ends them, root and descendant alike.
    private static func rootIgnoringTERMForking(_ marker: String) -> String {
        "trap '' TERM; { trap '' TERM; exec sleep \(marker); } & wait"
    }

    /// Waits until every shell spawned above has actually forked its `sleep`.
    /// A `-lc` shell takes a moment to get there, and `descendantPIDs(of:)`
    /// walks `pgrep -P`: a child not yet born is not a descendant, so a call
    /// made too early sweeps roots alone and measures nothing about batching
    /// them with what they forked.
    @MainActor
    private func forkedSleepsToStart(_ commandLines: [String]) async throws {
        try await eventually("the forked sleeps to start") {
            commandLines.allSatisfy { Self.pidOfExactCommand($0) != nil }
        }
    }

    // MARK: - Collecting descendants

    /// `descendantPIDs(of:)` is the walk `terminateAll` relies on: a child the
    /// root forked and a grandchild that child forked are both listed, the
    /// nearer generation first, while the root is still running.
    @MainActor
    func testDescendantPIDsListsAForkedChildAndItsGrandchild() async throws {
        let process = spawn(["-c", "sleep \(Self.marker(11)) & /bin/zsh -c 'sleep \(Self.marker(12)) & wait' & wait"])
        defer { Self.reap(process, markers: ["sleep \(Self.marker(11))", "sleep \(Self.marker(12))"]) }

        let child = try await eventuallyValue("the forked sleep to start") {
            Self.pidOfExactCommand("sleep \(Self.marker(11))")
        }
        let grandchild = try await eventuallyValue("the grandchild sleep to start") {
            Self.pidOfExactCommand("sleep \(Self.marker(12))")
        }

        let descendants = ProcessTree.descendantPIDs(of: process.processIdentifier)
        XCTAssertTrue(descendants.contains(child), "the forked child must be collected")
        XCTAssertTrue(descendants.contains(grandchild), "the walk must continue past the first generation")
        XCTAssertFalse(descendants.contains(process.processIdentifier), "the root is not its own descendant")
        if let childAt = descendants.firstIndex(of: child), let grandchildAt = descendants.firstIndex(of: grandchild) {
            XCTAssertLessThan(childAt, grandchildAt, "breadth-first: the nearer generation comes first")
        }
    }

    // MARK: - Sweeping collected pids

    /// A live pid handed to `killDescendants` is gone afterwards.
    @MainActor
    func testKillDescendantsEndsAPidItIsHanded() async throws {
        let process = spawnSleep(Self.marker(13))
        defer { Self.reap(process, markers: ["sleep \(Self.marker(13))"]) }
        XCTAssertTrue(process.isRunning)

        ProcessTree.killDescendants([process.processIdentifier])

        try await eventually("the sleep to be gone") { !process.isRunning }
    }

    /// A pid that ignores SIGTERM is gone too: whatever is still alive after
    /// the grace period is KILLed.
    @MainActor
    func testKillDescendantsEscalatesToSIGKILLForAPidThatIgnoresSIGTERM() async throws {
        // `exec` keeps the pid: once the shell has replaced itself with sleep,
        // that one process carries the ignored TERM.
        let process = spawn(["-c", "trap '' TERM; exec sleep \(Self.marker(14))"])
        defer { Self.reap(process, markers: ["sleep \(Self.marker(14))"]) }
        try await eventually("the shell to have exec'd into sleep") {
            Self.pidOfExactCommand("sleep \(Self.marker(14))") == process.processIdentifier
        }

        ProcessTree.killDescendants([process.processIdentifier])

        try await eventually("the TERM-ignoring sleep to be gone") { !process.isRunning }
    }

    // MARK: - Helpers

    private func spawn(_ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        return process
    }

    /// True while some process has `pattern` — one of this run's own markers —
    /// in its command line — used to check a forked child is actually gone, not just
    /// the shell that forked it.
    private static func isProcessRunning(matching pattern: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", pattern]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func spawnSleep(_ marker: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = [marker]
        try? process.run()
        return process
    }

    /// The pid whose command line is exactly `commandLine` — `pgrep -x -f`,
    /// so a shell whose script merely mentions the sleep does not match.
    private static func pidOfExactCommand(_ commandLine: String) -> pid_t? {
        commandOutput("/usr/bin/pgrep", ["-x", "-f", commandLine])
            .split(separator: "\n")
            .compactMap { pid_t($0) }
            .first
    }

    /// Cleanup that leans on nothing under test: the root is KILLed directly,
    /// and every process whose command line is one of `markers` is KILLed by
    /// that exact line, so a walk or a sweep that missed one leaks nothing.
    private static func reap(_ process: Process, markers: [String]) {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        for marker in markers { commandOutput("/usr/bin/pkill", ["-9", "-x", "-f", marker]) }
        process.waitUntilExit()
    }

    @discardableResult
    private static func commandOutput(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
