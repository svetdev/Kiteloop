import XCTest
@testable import KiteloopCore

final class BacklogFileWatcherTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "backlog-watcher-test")
    }

    /// An atomic write (write-to-temp + rename) swaps the file's inode, orphaning
    /// the watcher's fd. The watcher must re-open the path so a *later* edit still
    /// fires onChange — otherwise it goes deaf after the first editor save.
    func testWatcherSurvivesAtomicWriteAndStillFiresForLaterEdit() async throws {
        let fileURL = tempDir.appending(path: "BACKLOG.md")
        try "# Backlog\n".write(to: fileURL, atomically: false, encoding: .utf8)

        let sawAtomicWrite = XCTestExpectation(description: "onChange for the atomic write")
        let sawLaterEdit = XCTestExpectation(description: "onChange for the edit after re-arming")
        let recorder = ChangeRecorder(first: sawAtomicWrite, afterArming: sawLaterEdit)

        let watcher = BacklogFileWatcher(debounceInterval: 0.05) { recorder.record() }
        watcher.watch(url: fileURL)
        defer { watcher.stop() }

        // `atomically: true` writes a temp file and renames it over the original,
        // which unlinks the inode the watcher holds open.
        try "# Backlog\n- [ ] one\n".write(to: fileURL, atomically: true, encoding: .utf8)
        await fulfillment(of: [sawAtomicWrite], timeout: 3.0)

        // The rename handler re-opens the path 100ms later; let that land (and let
        // any in-flight debounce from the atomic write drain) before arming.
        try await Task.sleep(for: .milliseconds(300))
        recorder.arm()

        try "# Backlog\n- [ ] one\n- [ ] two\n".write(to: fileURL, atomically: false, encoding: .utf8)

        await fulfillment(of: [sawLaterEdit], timeout: 3.0)
    }

    // MARK: - Helpers

    /// Rewrites the file from *another process*, the way the coordinator agent or
    /// an editor does: content into a temp file, then `mv` over the original. The
    /// rename is what unlinks the inode the watcher holds open.
    private func replaceExternally(_ url: URL, with contents: String) throws {
        let staging = tempDir.appending(path: "staging-\(UUID().uuidString)")
        try contents.write(to: staging, atomically: false, encoding: .utf8)
        let mv = Process()
        mv.executableURL = URL(fileURLWithPath: "/bin/mv")
        mv.arguments = [staging.path(percentEncoded: false), url.path(percentEncoded: false)]
        try mv.run()
        mv.waitUntilExit()
        XCTAssertEqual(mv.terminationStatus, 0, "external replace failed")
    }

    /// The regression this class exists for. An atomic replace *did* fire the
    /// dispatch source — and the re-arm that followed went through `stop()`,
    /// which cancelled the debounced reload before it ran. The watcher looked
    /// alive, and an edit made outside the app was never seen until a restart.
    func testExternalAtomicReplaceReportsTheChange() async throws {
        let fileURL = tempDir.appending(path: "BACKLOG.md")
        try "# Backlog\n".write(to: fileURL, atomically: false, encoding: .utf8)

        let sawReplace = XCTestExpectation(description: "onChange for an atomic replace")
        let recorder = ChangeRecorder(first: sawReplace)
        let watcher = BacklogFileWatcher(debounceInterval: 0.05) { recorder.record() }
        watcher.watch(url: fileURL)
        defer { watcher.stop() }

        // Another process, replacing the file the way an editor does — the
        // in-process equivalent of the coordinator grooming the backlog.
        try replaceExternally(fileURL, with: "# Backlog\n- [ ] one | Groomed elsewhere\n")

        await fulfillment(of: [sawReplace], timeout: 3.0)
    }

    /// Deleting the file orphans the fd *and* leaves nothing to re-open, so the
    /// file source alone goes deaf for good. The directory source is what sees
    /// the rewrite land.
    func testFileDeletedThenRecreatedIsStillSeen() async throws {
        let fileURL = tempDir.appending(path: "BACKLOG.md")
        try "# Backlog\n".write(to: fileURL, atomically: false, encoding: .utf8)

        let sawRecreate = XCTestExpectation(description: "onChange after the file came back")
        let recorder = ChangeRecorder(afterArming: sawRecreate)
        let watcher = BacklogFileWatcher(debounceInterval: 0.05) { recorder.record() }
        watcher.watch(url: fileURL)
        defer { watcher.stop() }

        try FileManager.default.removeItem(at: fileURL)
        try await Task.sleep(for: .milliseconds(300))
        recorder.arm()
        try "# Backlog\n- [ ] one | Rewritten from scratch\n".write(to: fileURL, atomically: false, encoding: .utf8)

        await fulfillment(of: [sawRecreate], timeout: 3.0)
    }

    /// Watching the directory means every sibling file's churn arrives too — a
    /// build artifact, a `.DS_Store`, a git index. Only the backlog file counts.
    func testSiblingFileChurnDoesNotReportAChange() async throws {
        let fileURL = tempDir.appending(path: "BACKLOG.md")
        try "# Backlog\n".write(to: fileURL, atomically: false, encoding: .utf8)

        let recorder = ChangeRecorder()
        let watcher = BacklogFileWatcher(debounceInterval: 0.05) { recorder.record() }
        watcher.watch(url: fileURL)
        defer { watcher.stop() }

        for i in 0..<3 {
            let sibling = tempDir.appending(path: "artifact-\(i).txt")
            try "noise".write(to: sibling, atomically: true, encoding: .utf8)
            try FileManager.default.removeItem(at: sibling)
        }
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(recorder.count, 0)
    }

    func testStopPreventsCallbacks() async throws {
        let fileURL = tempDir.appending(path: "BACKLOG.md")
        try "# Backlog\n".write(to: fileURL, atomically: false, encoding: .utf8)

        let recorder = ChangeRecorder()
        let watcher = BacklogFileWatcher(debounceInterval: 0.05) { recorder.record() }
        watcher.watch(url: fileURL)
        watcher.stop()

        try "# Backlog\n- [ ] after stop\n".write(to: fileURL, atomically: false, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(recorder.count, 0)
    }

    // MARK: - Paths are file-system paths, not URL strings

    /// A project directory with a space in its name is `Projects/my app`, and
    /// `Projects/my%20app` is a directory that does not exist. The file source
    /// is what sees an in-place write — the directory source sees only entries
    /// coming and going — so a watcher that hands `open(2)` the encoded form
    /// arms no file source and never sees an ordinary save.
    func testInPlaceWriteIsSeenInADirectoryWhoseNameNeedsPercentEncoding() async throws {
        let directory = tempDir.appending(path: "my app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let fileURL = directory.appending(path: "BACKLOG.md")
        XCTAssertTrue(fileURL.path(percentEncoded: true).contains("%20"),
                      "the fixture must be a path whose encoded form differs")
        try "# Backlog\n".write(to: fileURL, atomically: false, encoding: .utf8)

        let sawEdit = XCTestExpectation(description: "onChange for an in-place write")
        let recorder = ChangeRecorder(first: sawEdit)
        let watcher = BacklogFileWatcher(debounceInterval: 0.05) { recorder.record() }
        watcher.watch(url: fileURL)
        defer { watcher.stop() }

        try "# Backlog\n- [ ] one\n".write(to: fileURL, atomically: false, encoding: .utf8)

        await fulfillment(of: [sawEdit], timeout: 3.0)
    }

    /// The same directory, and the case only the directory source can see: the
    /// file is deleted and comes back. That source opens the directory by path
    /// and tells the rewrite from sibling churn by `stat`-ing the file by path
    /// — an encoded form in either place, and the rewrite is never reported.
    func testRecreatedFileIsSeenInADirectoryWhoseNameNeedsPercentEncoding() async throws {
        let directory = tempDir.appending(path: "my app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let fileURL = directory.appending(path: "BACKLOG.md")
        XCTAssertTrue(fileURL.path(percentEncoded: true).contains("%20"),
                      "the fixture must be a path whose encoded form differs")
        try "# Backlog\n".write(to: fileURL, atomically: false, encoding: .utf8)

        let sawRecreate = XCTestExpectation(description: "onChange after the file came back")
        let recorder = ChangeRecorder(afterArming: sawRecreate)
        let watcher = BacklogFileWatcher(debounceInterval: 0.05) { recorder.record() }
        watcher.watch(url: fileURL)
        defer { watcher.stop() }

        try FileManager.default.removeItem(at: fileURL)
        try await Task.sleep(for: .milliseconds(300))
        recorder.arm()
        try "# Backlog\n- [ ] one | Rewritten from scratch\n".write(to: fileURL, atomically: false, encoding: .utf8)

        await fulfillment(of: [sawRecreate], timeout: 3.0)
    }

    // MARK: - A file the watcher cannot open

    /// `O_EVTONLY` still needs permission, so a backlog file with no mode bits
    /// arms no file source — the directory source is all there is. It tells a
    /// real change from sibling churn by the file's identity, and identity is
    /// what `stat(2)` answers: a watcher that reads `stat`'s success as failure
    /// sees no identity for any file that exists, so a readable file replacing
    /// the unopenable one looks like nothing happened. It must be reported,
    /// and the file source rebound to the new inode so the next edit is too.
    func testReplacingAFileTheWatcherCannotOpenIsStillReported() async throws {
        try XCTSkipIf(geteuid() == 0, "root opens a mode-000 file, so nothing here is exercised")
        let fileURL = tempDir.appending(path: "BACKLOG.md")
        try "# Backlog\n".write(to: fileURL, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: fileURL.path(percentEncoded: false))
        XCTAssertEqual(open(fileURL.path(percentEncoded: false), O_EVTONLY), -1,
                       "the fixture must be a file stat(2) sees and open(2) refuses")

        let sawReplace = XCTestExpectation(description: "onChange for the replacement")
        let sawLaterEdit = XCTestExpectation(description: "onChange for the edit after rebinding")
        let recorder = ChangeRecorder(first: sawReplace, afterArming: sawLaterEdit)
        let watcher = BacklogFileWatcher(debounceInterval: 0.05) { recorder.record() }
        watcher.watch(url: fileURL)
        defer { watcher.stop() }

        try replaceExternally(fileURL, with: "# Backlog\n- [ ] one | Readable again\n")
        await fulfillment(of: [sawReplace], timeout: 3.0)

        try await Task.sleep(for: .milliseconds(300))
        recorder.arm()
        try "# Backlog\n- [ ] one\n- [ ] two\n".write(to: fileURL, atomically: false, encoding: .utf8)

        await fulfillment(of: [sawLaterEdit], timeout: 3.0)
    }

    // MARK: - Descriptor 0

    /// Descriptor 0 is a valid descriptor. With stdin closed it is the lowest
    /// free number, so `open(2)` hands it to the file — and a watcher that
    /// reads 0 as "not available yet" arms no file source, leaks the
    /// descriptor, and never sees an in-place write.
    func testFileOpenedOnDescriptorZeroIsStillWatched() async throws {
        let fileURL = tempDir.appending(path: "BACKLOG.md")
        try "# Backlog\n".write(to: fileURL, atomically: false, encoding: .utf8)

        let sawEdit = XCTestExpectation(description: "onChange from a file source on descriptor 0")
        let recorder = ChangeRecorder(first: sawEdit)
        let watcher = BacklogFileWatcher(debounceInterval: 0.05) { recorder.record() }

        try await withDescriptorZeroFree {
            watcher.watch(url: fileURL)
            try "# Backlog\n- [ ] one\n".write(to: fileURL, atomically: false, encoding: .utf8)
            await fulfillment(of: [sawEdit], timeout: 3.0)
            watcher.stop()
        }
    }

    /// The same number handed to the directory instead: the file is absent at
    /// `watch`, so its own open fails and the directory's is the one that
    /// lands on 0. The directory source is what sees the file appear, and a
    /// watcher that reads 0 as "cannot watch" has nothing armed at all.
    func testDirectoryOpenedOnDescriptorZeroIsStillWatched() async throws {
        let fileURL = tempDir.appending(path: "BACKLOG.md")

        let sawCreate = XCTestExpectation(description: "onChange from a directory source on descriptor 0")
        let recorder = ChangeRecorder(first: sawCreate)
        let watcher = BacklogFileWatcher(debounceInterval: 0.05) { recorder.record() }

        try await withDescriptorZeroFree {
            watcher.watch(url: fileURL)
            try "# Backlog\n- [ ] one\n".write(to: fileURL, atomically: false, encoding: .utf8)
            await fulfillment(of: [sawCreate], timeout: 3.0)
            watcher.stop()
        }
    }
}

/// Thread-safe tally for the watcher's `@Sendable` callback, which fires on a
/// background queue. `arm()` splits the run into "before" and "after" so a test
/// can wait for a change that happened only after re-arming.
private final class ChangeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    private var armed = false
    private var firstFulfilled = false
    private var afterArmingFulfilled = false
    private let first: XCTestExpectation?
    private let afterArming: XCTestExpectation?

    init(first: XCTestExpectation? = nil, afterArming: XCTestExpectation? = nil) {
        self.first = first
        self.afterArming = afterArming
    }

    var count: Int {
        lock.withLock { _count }
    }

    func arm() {
        lock.withLock { armed = true }
    }

    func record() {
        let (fulfillFirst, fulfillAfterArming) = lock.withLock { () -> (Bool, Bool) in
            _count += 1
            let isFirst = !firstFulfilled
            firstFulfilled = true
            let isAfterArming = armed && !afterArmingFulfilled
            if isAfterArming { afterArmingFulfilled = true }
            return (isFirst, isAfterArming)
        }
        if fulfillFirst { first?.fulfill() }
        if fulfillAfterArming { afterArming?.fulfill() }
    }
}
