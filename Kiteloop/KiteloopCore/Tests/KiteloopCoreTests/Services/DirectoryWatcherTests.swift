import XCTest
@testable import KiteloopCore

final class DirectoryWatcherTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "directory-watcher-test")
    }

    /// The watched path is handed to `open(2)` as a file-system path, not as
    /// the URL's percent-encoded form: a directory with a space in its name is
    /// `Projects/my app`, and `Projects/my%20app` is a directory that does not
    /// exist. A watcher that encodes the path opens nothing and goes silent —
    /// `init` has no way to report a directory it could not open.
    func testWatchesADirectoryWhoseNameNeedsPercentEncoding() async throws {
        let directory = tempDir.appending(path: "my app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        XCTAssertTrue(directory.path(percentEncoded: true).contains("%20"),
                      "the fixture must be a path whose encoded form differs")

        let sawChange = XCTestExpectation(description: "onChange for a file added to the directory")
        let recorder = ChangeRecorder(first: sawChange)
        let watcher = DirectoryWatcher(directories: [directory], debounceInterval: 0.05) { recorder.record() }

        try "x".write(to: directory.appending(path: "file.txt"), atomically: false, encoding: .utf8)

        await fulfillment(of: [sawChange], timeout: 3.0)
        withExtendedLifetime(watcher) {}
    }

    /// Descriptor 0 is a valid descriptor. With stdin closed it is the lowest
    /// free number, so `open(2)` hands it to the first directory — and a
    /// watcher that reads 0 as "could not open" skips that directory, leaks
    /// the descriptor, and reports nothing from it.
    func testADirectoryOpenedOnDescriptorZeroIsStillWatched() async throws {
        let sawChange = XCTestExpectation(description: "onChange from a directory opened on descriptor 0")
        let recorder = ChangeRecorder(first: sawChange)

        try await withDescriptorZeroFree {
            var watcher: DirectoryWatcher? = DirectoryWatcher(
                directories: [tempDir], debounceInterval: 0.05
            ) { recorder.record() }

            try "x".write(to: tempDir.appending(path: "file.txt"), atomically: false, encoding: .utf8)

            await fulfillment(of: [sawChange], timeout: 3.0)
            withExtendedLifetime(watcher) {}
            // deinit closes the descriptors it opened, which is what lets stdin go back.
            watcher = nil
        }
    }

    // MARK: - Descriptor ownership

    /// `deinit` used to close every fd in `descriptors` right after cancelling
    /// the sources, racing `dispatch_source_cancel`'s asynchronous completion:
    /// an event handler could still be reading the descriptor after its number
    /// was freed and handed to something else. The cancel handler is now the
    /// only closer, so a close is only ever observed once cancellation has
    /// actually run.
    func testDeinitClosesEachDescriptorExactlyOnceFromTheCancelHandler() async throws {
        let dirA = tempDir.appending(path: "a", directoryHint: .isDirectory)
        let dirB = tempDir.appending(path: "b", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: false)
        let closes = CloseRecorder()

        var watcher: DirectoryWatcher? = DirectoryWatcher(
            directories: [dirA, dirB],
            debounceInterval: 0.05,
            closeDescriptor: { closes.record($0) }
        ) {}

        watcher = nil
        try await eventually("both cancel handlers released their descriptor") { closes.count == 2 }
        XCTAssertEqual(closes.count, 2)
        XCTAssertEqual(Set(closes.descriptors).count, 2, "each descriptor closed exactly once")
    }

    /// A directory `open` refuses gets no descriptor and no source, so
    /// cancellation closes nothing for it — only the directory that did open.
    func testADirectoryThatFailedToOpenClosesNoDescriptor() async throws {
        let opened = tempDir.appending(path: "opened", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: opened, withIntermediateDirectories: false)
        let missing = tempDir.appending(path: "does-not-exist", directoryHint: .isDirectory)
        let closes = CloseRecorder()

        var watcher: DirectoryWatcher? = DirectoryWatcher(
            directories: [opened, missing],
            debounceInterval: 0.05,
            closeDescriptor: { closes.record($0) }
        ) {}

        watcher = nil
        try await eventually("the one opened descriptor was released") { closes.count == 1 }
        XCTAssertEqual(closes.count, 1)
    }
}

/// Thread-safe tally of the descriptors the watcher released. The closer runs
/// on the dispatch source's queue, and it really closes the fd so a test never
/// leaks one.
private final class CloseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _descriptors: [Int32] = []

    var descriptors: [Int32] { lock.withLock { _descriptors } }
    var count: Int { lock.withLock { _descriptors.count } }

    func record(_ fd: Int32) {
        lock.withLock { _descriptors.append(fd) }
        close(fd)
    }
}

/// Thread-safe tally for the watcher's `@Sendable` callback, which fires on a
/// global queue.
private final class ChangeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    private var firstFulfilled = false
    private let first: XCTestExpectation?

    init(first: XCTestExpectation? = nil) {
        self.first = first
    }

    var count: Int {
        lock.withLock { _count }
    }

    func record() {
        let fulfillFirst = lock.withLock { () -> Bool in
            _count += 1
            let isFirst = !firstFulfilled
            firstFulfilled = true
            return isFirst
        }
        if fulfillFirst { first?.fulfill() }
    }
}
