import XCTest
@testable import KiteloopCore

/// Covers the lifecycle of the per-session scratch files the CLI runtime leaves
/// in the temp directory. Two failure modes matter: a FIFO surviving the session
/// that made it (the app crashed, or a reader stayed parked on it), and the
/// launch-time sweep deleting a file that is still in use.
final class SessionTempFilesTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = try makeTemporaryDirectory(prefix: "kiteloop-test-tempfiles")
    }

    override func tearDownWithError() throws {
        directory = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func touch(_ name: String) -> String {
        let path = directory.appendingPathComponent(name).path(percentEncoded: false)
        FileManager.default.createFile(atPath: path, contents: Data())
        return path
    }

    private func makeFIFO(_ name: String) -> String {
        let path = directory.appendingPathComponent(name).path(percentEncoded: false)
        XCTAssertEqual(mkfifo(path, 0o600), 0, "could not create FIFO at \(path)")
        return path
    }

    @discardableResult
    private func touch(_ name: String, modified: Date) throws -> String {
        let path = touch(name)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path)
        return path
    }

    private func names() -> Set<String> {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)))
        return Set(contents ?? [])
    }

    // MARK: - Naming

    func testEveryKindGetsADistinctPathCarryingTheOwningPID() {
        let sessionID = UUID().uuidString
        var seen = Set<String>()

        for kind in SessionTempFiles.Kind.allCases {
            let name = SessionTempFiles.fileName(for: kind, sessionID: sessionID, pid: 4242)
            XCTAssertEqual(SessionTempFiles.owningPID(name), 4242, "\(kind) lost its pid")
            XCTAssertTrue(name.contains(sessionID), "\(kind) lost its session id")
            XCTAssertTrue(seen.insert(name).inserted, "\(kind) collides with another kind")
        }
    }

    /// The permission bridge is gone, so a session's scratch files are the tool
    /// bridge's and the global MCP config and nothing else: no FIFO, no MCP
    /// config and no bridge script is named for a permission server, and nothing
    /// can create one.
    func testNoPermissionArtifactIsNamed() {
        XCTAssertEqual(
            Set(SessionTempFiles.Kind.allCases.map(\.rawValue)),
            ["tools-res.pipe", "tools-req.pipe", "tools-mcp.json", "global-mcp.json"]
        )
        XCTAssertEqual(SessionTempFiles.sharedScriptNames, ["kiteloop-tool-bridge.js"])
    }

    /// Reaping identifies a file by its pid alone, so no kind's name may be a
    /// prefix of another's — that would let one session's file shadow another's.
    func testKindSuffixesDoNotPrefixEachOther() {
        let suffixes = SessionTempFiles.Kind.allCases.map(\.rawValue)
        for suffix in suffixes {
            for other in suffixes where other != suffix {
                XCTAssertFalse(other.hasSuffix(suffix), "\(other) is shadowed by \(suffix)")
            }
        }
    }

    func testPathIsPlacedInTheGivenDirectory() {
        let path = SessionTempFiles.path(for: .toolRequestPipe, sessionID: "s1", in: directory, pid: 7)
        XCTAssertEqual(
            URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL,
            directory.standardizedFileURL
        )
    }

    // MARK: - Orphan classification

    func testFilesOwnedByALiveProcessAreNotOrphans() {
        let name = SessionTempFiles.fileName(for: .toolResponsePipe, sessionID: "s1", pid: 100)
        XCTAssertFalse(SessionTempFiles.isOrphan(name, isAlive: { $0 == 100 }))
    }

    func testFilesOwnedByADeadProcessAreOrphans() {
        let name = SessionTempFiles.fileName(for: .toolResponsePipe, sessionID: "s1", pid: 100)
        XCTAssertTrue(SessionTempFiles.isOrphan(name, isAlive: { _ in false }))
    }

    /// The pre-pid naming scheme carries no owner, and only a build older than
    /// this one can have written it — so it is always wreckage.
    func testLegacyNamesAreOrphansRegardlessOfLiveness() {
        for name in [
            "kiteloop-perm-08083A1E-BDC9-49DE-A515-6FF2B11BFAE7.pipe",
            "kiteloop-mcp-08083A1E-BDC9-49DE-A515-6FF2B11BFAE7.json",
            "kiteloop-tools-08083A1E-BDC9-49DE-A515-6FF2B11BFAE7.pipe",
            "kiteloop-tools-req-08083A1E-BDC9-49DE-A515-6FF2B11BFAE7.pipe",
            "kiteloop-tools-mcp-08083A1E-BDC9-49DE-A515-6FF2B11BFAE7.json"
        ] {
            XCTAssertTrue(SessionTempFiles.isOrphan(name, isAlive: { _ in true }), "\(name) should be reaped")
        }
    }

    func testSharedAndUnrelatedFilesAreNeverOrphans() {
        for name in [
            "kiteloop-tool-bridge.js",
            "kiteloop-test-scratch-dir",
            "kiteloop-replay-capture.jsonl",
            "some-other-app.pipe"
        ] {
            XCTAssertFalse(SessionTempFiles.isOrphan(name, isAlive: { _ in false }), "\(name) should be left alone")
        }
    }

    // MARK: - Orphans from a previous boot

    /// The one that made a leak permanent: pids start again from low numbers
    /// after a restart, so a file left by a crash before the reboot very often
    /// names a pid something unrelated now holds — and `$TMPDIR` survives the
    /// reboot, so it read as live at every launch from then on. Nothing running
    /// now can have written a file that predates the boot.
    func testArtifactOlderThanTheBootIsAnOrphanEvenWhenItsPIDIsAlive() {
        let boot = Date()
        let name = SessionTempFiles.fileName(for: .toolRequestPipe, sessionID: "s1", pid: 100)

        XCTAssertTrue(SessionTempFiles.isOrphan(
            name,
            isAlive: { _ in true },
            modified: boot.addingTimeInterval(-60),
            bootedAt: boot
        ))
    }

    /// After the boot the pid means what it says again, in both directions.
    func testArtifactYoungerThanTheBootStillFollowsThePIDRule() {
        let boot = Date()
        let name = SessionTempFiles.fileName(for: .toolRequestPipe, sessionID: "s1", pid: 100)

        XCTAssertFalse(SessionTempFiles.isOrphan(
            name,
            isAlive: { _ in true },
            modified: boot.addingTimeInterval(60),
            bootedAt: boot
        ))
        XCTAssertTrue(SessionTempFiles.isOrphan(
            name,
            isAlive: { _ in false },
            modified: boot.addingTimeInterval(60),
            bootedAt: boot
        ))
    }

    /// The prefix guard and the shared-script list still decide first: age is
    /// only ever asked about something the sweep already owns.
    func testSharedAndUnrelatedFilesSurviveAnyAge() {
        let boot = Date()
        for name in [
            "kiteloop-tool-bridge.js",
            "some-other-app.pipe"
        ] {
            XCTAssertFalse(
                SessionTempFiles.isOrphan(
                    name,
                    isAlive: { _ in false },
                    modified: boot.addingTimeInterval(-86_400),
                    bootedAt: boot
                ),
                "\(name) should be left alone"
            )
        }
    }

    func testReapRemovesFilesFromBeforeTheBootAndKeepsTheRest() throws {
        let boot = Date()
        // Same live pid on both — only the dates separate them.
        let stale = SessionTempFiles.fileName(for: .toolRequestPipe, sessionID: "stale", pid: 100)
        let live = SessionTempFiles.fileName(for: .toolRequestPipe, sessionID: "live", pid: 100)
        let script = "kiteloop-tool-bridge.js"

        try touch(stale, modified: boot.addingTimeInterval(-3600))
        try touch(live, modified: boot.addingTimeInterval(3600))
        try touch(script, modified: boot.addingTimeInterval(-86_400))

        let reaped = SessionTempFiles.reapOrphans(in: directory, isAlive: { _ in true }, bootDate: { boot })

        XCTAssertEqual(reaped, 1)
        XCTAssertEqual(names(), [live, script])
    }

    /// The sweep must never delete something it cannot justify: with no boot
    /// date to compare against, it reaps exactly what it reaped before this rule
    /// existed.
    func testReapFallsBackToThePIDRuleWhenTheBootDateIsUnavailable() throws {
        let stale = SessionTempFiles.fileName(for: .toolRequestPipe, sessionID: "stale", pid: 100)
        let dead = SessionTempFiles.fileName(for: .toolRequestPipe, sessionID: "dead", pid: 200)

        // Old enough that the boot rule would have taken it, had there been one.
        try touch(stale, modified: Date(timeIntervalSince1970: 0))
        _ = touch(dead)

        let reaped = SessionTempFiles.reapOrphans(in: directory, isAlive: { $0 == 100 }, bootDate: { nil })

        XCTAssertEqual(reaped, 1)
        XCTAssertEqual(names(), [stale])
    }

    /// The boot time is one number for the machine, so a sweep over a temp
    /// directory with hundreds of entries must not ask the kernel for it once
    /// per file.
    func testReapReadsTheBootTimeOncePerSweep() throws {
        for index in 0..<5 {
            _ = touch(SessionTempFiles.fileName(for: .toolRequestPipe, sessionID: "s\(index)", pid: 200))
        }

        var reads = 0
        let boot = Date()
        SessionTempFiles.reapOrphans(in: directory, isAlive: { _ in false }, bootDate: {
            reads += 1
            return boot
        })

        XCTAssertEqual(reads, 1)
    }

    func testBootDateIsInThePastAndAfterTheEpoch() throws {
        let boot = try XCTUnwrap(SessionTempFiles.bootDate(), "kern.boottime should be readable")
        XCTAssertLessThan(boot, Date())
        XCTAssertGreaterThan(boot, Date(timeIntervalSince1970: 1_000_000_000))
    }

    // MARK: - Reaping

    func testReapRemovesDeadSessionFilesAndKeepsEverythingElse() throws {
        let live = SessionTempFiles.fileName(for: .toolRequestPipe, sessionID: "live", pid: 100)
        let dead = SessionTempFiles.fileName(for: .toolRequestPipe, sessionID: "dead", pid: 200)
        let deadConfig = SessionTempFiles.fileName(for: .toolMCPConfig, sessionID: "dead", pid: 200)
        let legacy = "kiteloop-perm-08083A1E-BDC9-49DE-A515-6FF2B11BFAE7.pipe"
        let script = "kiteloop-tool-bridge.js"

        for name in [live, dead, deadConfig, legacy, script] { _ = touch(name) }

        let reaped = SessionTempFiles.reapOrphans(in: directory, isAlive: { $0 == 100 })

        XCTAssertEqual(reaped, 3)
        XCTAssertEqual(names(), [live, script])
    }

    func testReapIsSafeOnAnEmptyOrMissingDirectory() {
        XCTAssertEqual(SessionTempFiles.reapOrphans(in: directory, isAlive: { _ in false }), 0)
        let missing = directory.appendingPathComponent("does-not-exist")
        XCTAssertEqual(SessionTempFiles.reapOrphans(in: missing, isAlive: { _ in false }), 0)
    }

    // MARK: - FIFO teardown

    func testRemoveFIFOUnlinksThePath() {
        let path = makeFIFO("kiteloop-\(getpid())-s1-tools-req.pipe")
        SessionTempFiles.removeFIFO(at: path, role: .kiteloopReads)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    /// The one that bites in production: a reader parked in a blocking `open(2)`
    /// on a FIFO is *not* released by `unlink`, so tearing the session down would
    /// strand that thread and its descriptor for the life of the app. Teardown
    /// has to open the write end first.
    func testRemoveFIFOReleasesAReaderParkedInOpen() {
        let path = makeFIFO("kiteloop-\(getpid())-s2-tools-req.pipe")
        let opened = expectation(description: "reader's open(2) returned")

        DispatchQueue.global(qos: .userInitiated).async {
            let fd = open(path, O_RDONLY)
            opened.fulfill()
            if fd >= 0 { close(fd) }
        }

        // Give the reader time to actually park inside open(2) rather than
        // racing us to it — otherwise the test could pass without proving
        // anything.
        Thread.sleep(forTimeInterval: 0.2)

        SessionTempFiles.removeFIFO(at: path, role: .kiteloopReads)

        wait(for: [opened], timeout: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    /// Same hazard in the other direction: Kiteloop writes tool results, so an
    /// open of the write end parks until the bridge opens the read end.
    func testRemoveFIFOReleasesAWriterParkedInOpen() {
        let path = makeFIFO("kiteloop-\(getpid())-s3-tools-res.pipe")
        let opened = expectation(description: "writer's open(2) returned")

        DispatchQueue.global(qos: .userInitiated).async {
            let handle = FileHandle(forWritingAtPath: path)
            opened.fulfill()
            handle?.closeFile()
        }

        Thread.sleep(forTimeInterval: 0.2)

        SessionTempFiles.removeFIFO(at: path, role: .kiteloopWrites)

        wait(for: [opened], timeout: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    /// Removal must not park in turn when there is nobody on the other end.
    func testRemoveFIFOReturnsPromptlyWithNoPeer() {
        let path = makeFIFO("kiteloop-\(getpid())-s4-tools-req.pipe")
        let start = Date()
        SessionTempFiles.removeFIFO(at: path, role: .kiteloopReads)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testProcessIsAliveRecognisesTheCurrentProcess() {
        XCTAssertTrue(SessionTempFiles.processIsAlive(getpid()))
        XCTAssertFalse(SessionTempFiles.processIsAlive(0))
        XCTAssertFalse(SessionTempFiles.processIsAlive(-1))
    }

    // MARK: - Paths are filesystem paths, not URLs

    /// The temp directory is handed to `open(2)` and `mkfifo(2)` as a path, and
    /// a user's can carry a space. Percent-encoding it names a directory that
    /// does not exist, so the FIFO would be created somewhere nothing else looks.
    func testPathKeepsASpaceInTheDirectoryLiteral() throws {
        let spaced = directory.appendingPathComponent("with space", isDirectory: true)
        try FileManager.default.createDirectory(at: spaced, withIntermediateDirectories: true)

        let path = SessionTempFiles.path(for: .toolRequestPipe, sessionID: "s1", in: spaced, pid: 7)

        XCTAssertTrue(
            path.hasSuffix("/with space/kiteloop-7-s1-tools-req.pipe"),
            "the path must keep the space literal, got \(path)"
        )
        XCTAssertFalse(path.contains("%"), "the path must not be percent-encoded, got \(path)")
    }

    /// The sweep lists and unlinks by path too: with the directory spelled as a
    /// URL it lists nothing and unlinks nothing, and the orphans it exists to
    /// reap stay for good.
    func testReapRemovesOrphansFromADirectoryWhoseNameHasASpace() throws {
        let spaced = directory.appendingPathComponent("with space", isDirectory: true)
        try FileManager.default.createDirectory(at: spaced, withIntermediateDirectories: true)
        let dead = SessionTempFiles.fileName(for: .toolRequestPipe, sessionID: "dead", pid: 200)
        let path = spaced.appendingPathComponent(dead).path(percentEncoded: false)
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data()))

        let reaped = SessionTempFiles.reapOrphans(in: spaced, isAlive: { _ in false })

        XCTAssertEqual(reaped, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "the orphan should have been unlinked")
    }

    // MARK: - The boot boundary

    /// A file stamped at the boot instant itself was not written *before* the
    /// boot, so the age rule has nothing to say and the pid rule decides — in
    /// both directions.
    func testArtifactModifiedAtTheBootInstantFollowsThePIDRule() {
        let boot = Date()
        let name = SessionTempFiles.fileName(for: .toolRequestPipe, sessionID: "s1", pid: 100)

        XCTAssertFalse(SessionTempFiles.isOrphan(name, isAlive: { _ in true }, modified: boot, bootedAt: boot))
        XCTAssertTrue(SessionTempFiles.isOrphan(name, isAlive: { _ in false }, modified: boot, bootedAt: boot))
    }

    // MARK: - Liveness from kill(2)

    /// `kill(pid, 0)` answers two different "no"s: ESRCH for a pid nothing
    /// holds, EPERM for one held by a process this user may not signal. Only the
    /// second means the process exists. `pid_t.max` is far past the kernel's
    /// pid ceiling, so nothing ever holds it; pid 1 is launchd, which is always
    /// running and, for an unprivileged user, always EPERM.
    func testProcessIsAliveDistinguishesAMissingPIDFromAForeignOne() {
        XCTAssertFalse(SessionTempFiles.processIsAlive(pid_t.max), "a pid nothing holds is not alive")
        XCTAssertTrue(SessionTempFiles.processIsAlive(1), "launchd is alive even though we may not signal it")
    }

    // MARK: - Descriptor 0

    /// Descriptor 0 is a valid descriptor. With stdin closed it is the lowest
    /// free number, so the momentary open in teardown lands on it — and it has
    /// to be closed like any other, or every session leaks one.
    func testRemoveFIFOClosesTheDescriptorItOpenedEvenWhenThatIsZero() throws {
        let path = makeFIFO("kiteloop-\(getpid())-s5-tools-res.pipe")
        var fifo = stat()
        XCTAssertEqual(stat(path, &fifo), 0)

        // Free descriptor 0 for the duration of the call; stdin is put back after.
        let savedStdin = dup(0)
        if savedStdin >= 0 { close(0) }
        defer {
            if savedStdin >= 0 {
                dup2(savedStdin, 0)
                close(savedStdin)
            }
        }

        SessionTempFiles.removeFIFO(at: path, role: .kiteloopWrites)

        var zero = stat()
        if fstat(0, &zero) == 0 {
            XCTAssertFalse(
                zero.st_dev == fifo.st_dev && zero.st_ino == fifo.st_ino,
                "teardown opened descriptor 0 on the FIFO and never closed it"
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
}
