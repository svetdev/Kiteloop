import XCTest
@testable import KiteloopCore

/// `ProcessTree.terminateAll` is what every teardown path that owns more than
/// one root process — right now just `ClaudeCodeCLIRuntime` — hands its
/// processes to, instead of signalling each root alone and leaving whatever it
/// forked running and reparented.
final class ProcessTreeTests: XCTestCase {

    /// Every child these tests spawn carries a `sleep 8102xx` or `sleep 8109xx`
    /// marker. A run under a mutant that disables the kill — mutate-core runs
    /// exactly those — leaves them alive for nine days, and the next unmutated
    /// run then finds "the forked child" still there and fails for the wrong
    /// reason. So the slate is wiped before each test, by marker, with a kill
    /// that does not lean on the code under test.
    override func setUpWithError() throws {
        for prefix in ["sleep 8102", "sleep 8109"] {
            let pkill = Process()
            pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            pkill.arguments = ["-9", "-f", prefix]
            pkill.standardOutput = FileHandle.nullDevice
            pkill.standardError = FileHandle.nullDevice
            try? pkill.run()
            pkill.waitUntilExit()
        }
    }

    // MARK: - A root and everything it forked

    /// A root spawned as `/bin/zsh -lc "sleep <n> & wait"` forks `sleep` as a
    /// child of the shell. `terminateAll` must collect that descendant before
    /// signalling the shell — `descendantPIDs(of:)` can only walk `pgrep -P`
    /// while the child is still reparented under a live shell — so the forked
    /// child is gone by the time the call returns.
    func testARootsForkedChildIsGoneWhenTheCallReturns() {
        let process = spawn(["-lc", "sleep 810201 & wait"])
        ProcessTree.terminateAll([process])
        XCTAssertFalse(isProcessRunning(matching: "sleep 810201"),
                        "the forked child must not survive the call returning")
    }

    /// A root that traps and ignores SIGTERM must still be gone when the call
    /// returns — the escalation to SIGKILL is what makes that true.
    func testARootThatIgnoresSIGTERMIsGoneWhenTheCallReturns() {
        let process = spawn(["-lc", "trap '' TERM; sleep 810202"])
        ProcessTree.terminateAll([process])
        XCTAssertFalse(isProcessRunning(matching: "sleep 810202"),
                        "a root ignoring SIGTERM must still be killed")
    }

    /// The sweep only reaches pids collected as descendants of the roots it
    /// was given — never anything merely matching the killed command's text.
    func testABystanderThatOnlySharesTheKilledCommandsTextSurvives() {
        let bystander = Process()
        bystander.executableURL = URL(fileURLWithPath: "/bin/sleep")
        bystander.arguments = ["810203"]
        try? bystander.run()
        defer {
            bystander.terminate()
            bystander.waitUntilExit()
        }

        let process = spawn(["-lc", "sleep 810203 & wait"])
        ProcessTree.terminateAll([process])

        XCTAssertTrue(bystander.isRunning,
                       "a process outside the roots handed to this call must not be touched")
    }

    // MARK: - Batching

    /// The grace period `terminateAll` sleeps out is 500ms, and it must sleep
    /// it exactly once however many roots and descendants it is handed. This
    /// bound sits between one grace period and two: the calls below measure
    /// 0.67s and 0.88s as written — the one sleep, plus a `pgrep` per node of
    /// the walk — against 1.20s and 1.36s for a sweep that pays a second one,
    /// the roots first and then their descendants. So that sweep fails here
    /// rather than passing under a loose bound.
    private let oneGracePeriod = 0.95

    /// Two roots handed to one call must both be swept, and the call pays the
    /// grace period once rather than once per root.
    @MainActor
    func testTwoRootsInOneCallAreBothSweptAndPayOneGracePeriod() async throws {
        let first = spawn(["-lc", Self.rootIgnoringTERMForking("810204")])
        let second = spawn(["-lc", Self.rootIgnoringTERMForking("810205")])
        try await forkedSleepsToStart(["sleep 810204", "sleep 810205"])

        let start = Date()
        ProcessTree.terminateAll([first, second])
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertFalse(isProcessRunning(matching: "sleep 810204"))
        XCTAssertFalse(isProcessRunning(matching: "sleep 810205"))
        XCTAssertLessThan(elapsed, oneGracePeriod, "two roots should not each pay their own grace period")
    }

    /// A single root that ignores SIGTERM and forks a child pays that same one
    /// grace period between them: the root and the descendants collected from
    /// it are signalled together, not one set after the other.
    @MainActor
    func testARootAndItsForkedChildPayOneGracePeriodBetweenThem() async throws {
        let process = spawn(["-lc", Self.rootIgnoringTERMForking("810206")])
        try await forkedSleepsToStart(["sleep 810206"])

        let start = Date()
        ProcessTree.terminateAll([process])
        let elapsed = Date().timeIntervalSince(start)

        // `pgrep -f` matches the root shell too: the marker is in its argv.
        XCTAssertFalse(isProcessRunning(matching: "sleep 810206"),
                        "neither the TERM-ignoring root nor the child it forked may survive")
        XCTAssertLessThan(elapsed, oneGracePeriod,
                          "a root and its descendants should not each pay their own grace period")
    }

    /// A shell that ignores SIGTERM and forks a child that ignores it too —
    /// the child `exec`s `sleep`, so the ignored disposition survives into a
    /// process whose command line is exactly `sleep <marker>`. Both halves
    /// have to outlive TERM for the timing to mean anything: `Process`
    /// launches its child in its own process group and `terminate()` reaches
    /// that group, so a child taking the default action would already be gone
    /// before the descendant sweep ran and a second grace period would cost
    /// nothing to measure.
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
        let process = spawn(["-c", "sleep 810901 & /bin/zsh -c 'sleep 810902 & wait' & wait"])
        defer { Self.reap(process, markers: ["sleep 810901", "sleep 810902"]) }

        let child = try await eventuallyValue("the forked sleep to start") {
            Self.pidOfExactCommand("sleep 810901")
        }
        let grandchild = try await eventuallyValue("the grandchild sleep to start") {
            Self.pidOfExactCommand("sleep 810902")
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
        let process = spawnSleep("810903")
        defer { Self.reap(process, markers: ["sleep 810903"]) }
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
        let process = spawn(["-c", "trap '' TERM; exec sleep 810904"])
        defer { Self.reap(process, markers: ["sleep 810904"]) }
        try await eventually("the shell to have exec'd into sleep") {
            Self.pidOfExactCommand("sleep 810904") == process.processIdentifier
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

    /// True while some process anywhere on the machine has `pattern` in its
    /// command line — used to check a forked child is actually gone, not just
    /// the shell that forked it.
    private func isProcessRunning(matching pattern: String) -> Bool {
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
