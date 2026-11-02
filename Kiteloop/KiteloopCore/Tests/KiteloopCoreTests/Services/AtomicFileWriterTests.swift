import XCTest
@testable import KiteloopCore

/// The writer behind every settings save: whatever it leaves on disk is what the
/// next launch reads, so a partial write or a stray temp file is a lost or
/// corrupt configuration.
final class AtomicFileWriterTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = try makeTemporaryDirectory(prefix: "atomic-file-writer")
    }

    override func tearDownWithError() throws {
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Round-trip

    func testWritesContentToANewFile() throws {
        let url = tempDir.appendingPathComponent("config.json")

        try AtomicFileWriter.write(Data(#"{"a":1}"#.utf8), to: url)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), #"{"a":1}"#)
    }

    func testOverwritesAnExistingFileWholesale() throws {
        let url = tempDir.appendingPathComponent("config.json")
        try Data(String(repeating: "x", count: 4096).utf8).write(to: url)

        try AtomicFileWriter.write(Data("short".utf8), to: url)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "short")
    }

    /// The write loop has to survive short `write(2)` returns; a payload larger
    /// than a pipe/page buffer is where that shows up.
    func testWritesPayloadsLargerThanOneBuffer() throws {
        let url = tempDir.appendingPathComponent("big.json")
        let payload = Data((0..<(4 * 1024 * 1024)).map { UInt8($0 % 251) })

        try AtomicFileWriter.write(payload, to: url)

        XCTAssertEqual(try Data(contentsOf: url), payload)
    }

    func testWritesEmptyData() throws {
        let url = tempDir.appendingPathComponent("empty.json")
        try Data("previous".utf8).write(to: url)

        try AtomicFileWriter.write(Data(), to: url)

        XCTAssertEqual(try Data(contentsOf: url).count, 0)
    }

    func testCreatesMissingParentDirectories() throws {
        let url = tempDir.appendingPathComponent("nested/deeper/config.json")

        try AtomicFileWriter.write(Data("hi".utf8), to: url)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "hi")
    }

    // MARK: - Leftovers

    /// The temp sibling must be renamed away, not abandoned — `~/.kiteloop` is a
    /// directory users read, and a scan for config files must not find drafts.
    func testLeavesNoTempSiblingBehind() throws {
        let url = tempDir.appendingPathComponent("config.json")

        for i in 0..<5 {
            try AtomicFileWriter.write(Data("\(i)".utf8), to: url)
        }

        XCTAssertEqual(try directoryEntries(), ["config.json"])
    }

    func testCleansUpTheTempFileWhenTheRenameFails() throws {
        // A directory cannot be replaced by a rename of a regular file, so this
        // fails after the temp file has already been written and flushed.
        let url = tempDir.appendingPathComponent("occupied")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)

        XCTAssertThrowsError(try AtomicFileWriter.write(Data("hi".utf8), to: url))
        XCTAssertEqual(try directoryEntries(), ["occupied"])
    }

    /// A failed write must leave the previous contents intact rather than a
    /// half-replaced file.
    func testKeepsThePreviousContentsWhenTheWriteFails() throws {
        let url = tempDir.appendingPathComponent("config.json")
        try Data("good".utf8).write(to: url)
        // Read-only directory: the temp file cannot be created at all.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: tempDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempDir.path) }

        XCTAssertThrowsError(try AtomicFileWriter.write(Data("new".utf8), to: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "good")
    }

    // MARK: - Permissions

    func testPreservesThePermissionsOfTheFileItReplaces() throws {
        let url = tempDir.appendingPathComponent("config.json")
        try Data("old".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        try AtomicFileWriter.write(Data("new".utf8), to: url)

        XCTAssertEqual(try mode(of: url), 0o600)
    }

    func testUsesReadableDefaultPermissionsForANewFile() throws {
        let url = tempDir.appendingPathComponent("fresh.json")

        try AtomicFileWriter.write(Data("new".utf8), to: url)

        XCTAssertEqual(try mode(of: url), 0o644)
    }

    // MARK: - Append

    /// The repair, stated plainly: a file whose last byte is not a newline gets
    /// one before the appended bytes, so the two never share a line.
    func testAppendStartsANewLineWhenTheFileDoesNotEndInOne() throws {
        let url = tempDir.appendingPathComponent("log.jsonl")
        try Data("{\"a\":1}\n{\"b\":2".utf8).write(to: url)

        try AtomicFileWriter.append(Data("{\"c\":3}\n".utf8), to: url)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8),
                       "{\"a\":1}\n{\"b\":2\n{\"c\":3}\n")
    }

    /// And the ordinary case pays nothing for it: a file already terminated gains
    /// the line and no blank one in front of it.
    func testAppendAddsNoNewlineWhenTheFileAlreadyEndsInOne() throws {
        let url = tempDir.appendingPathComponent("log.jsonl")
        try Data("{\"a\":1}\n".utf8).write(to: url)

        try AtomicFileWriter.append(Data("{\"b\":2}\n".utf8), to: url)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{\"a\":1}\n{\"b\":2}\n")
    }

    func testAppendCreatesAMissingFileCarryingJustTheLine() throws {
        let url = tempDir.appendingPathComponent("fresh.jsonl")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        try AtomicFileWriter.append(Data("{\"a\":1}\n".utf8), to: url)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{\"a\":1}\n")
    }

    /// A ledger whose directory nobody has made yet is the ordinary case on a
    /// first launch, and the create branch used to throw the record away rather
    /// than write it — every caller reaches `append` as `try?`, so the throw was
    /// silent.
    func testAppendCreatesMissingParentDirectories() throws {
        let url = tempDir.appendingPathComponent("nested/deeper/log.jsonl")

        try AtomicFileWriter.append(Data("{\"a\":1}\n".utf8), to: url)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{\"a\":1}\n")
    }

    /// The first line goes down the same durable path as `write`, which lands the
    /// file by renaming a flushed temp sibling — so the sibling must be gone
    /// afterwards, exactly as `testLeavesNoTempSiblingBehind` demands of `write`.
    func testAppendLeavesNoTempSiblingWhenItCreatesTheFile() throws {
        let url = tempDir.appendingPathComponent("fresh.jsonl")

        try AtomicFileWriter.append(Data("{\"a\":1}\n".utf8), to: url)

        XCTAssertEqual(try directoryEntries(), ["fresh.jsonl"])
    }

    /// An empty file has no last byte to be wrong about, so nothing is prepended
    /// to the first line either.
    func testAppendAddsNoNewlineToAnEmptyFile() throws {
        let url = tempDir.appendingPathComponent("empty.jsonl")
        try Data().write(to: url)

        try AtomicFileWriter.append(Data("{\"a\":1}\n".utf8), to: url)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{\"a\":1}\n")
    }

    /// What the repair is for, at the level it costs someone a record: append onto
    /// a truncated tail and a loader sees two lines — the remnant, still verbatim
    /// and still unreadable, and a new one that decodes.
    func testAppendingOntoATruncatedRecordLeavesTwoSeparateLines() throws {
        let url = tempDir.appendingPathComponent("log.jsonl")
        let remnant = "{\"id\":\"cut\",\"cost\":0.4"
        try Data("{\"id\":\"first\"}\n\(remnant)".utf8).write(to: url)

        try AtomicFileWriter.append(Data("{\"id\":\"after\"}\n".utf8), to: url)

        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines, ["{\"id\":\"first\"}", remnant, "{\"id\":\"after\"}"])
        let decoded = lines.compactMap { try? JSONDecoder().decode([String: String].self, from: Data($0.utf8)) }
        XCTAssertEqual(decoded.compactMap { $0["id"] }, ["first", "after"],
                       "the new record decodes; only the remnant does not")
    }

    /// Repeated appends stay one line each — the check reads the file as it is
    /// now, not as the last call left it in memory.
    func testRepeatedAppendsEachAddExactlyOneLine() throws {
        let url = tempDir.appendingPathComponent("log.jsonl")

        for i in 0..<5 {
            try AtomicFileWriter.append(Data("line-\(i)\n".utf8), to: url)
        }

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init),
                       ["line-0", "line-1", "line-2", "line-3", "line-4"])
    }

    /// The append loop has to survive short `write(2)` returns the same way the
    /// whole-file one does — a trace ledger's line is not always small.
    func testAppendWritesPayloadsLargerThanOneBuffer() throws {
        let url = tempDir.appendingPathComponent("log.jsonl")
        try Data("{\"a\":1}\n".utf8).write(to: url)
        let payload = Data((0..<(4 * 1024 * 1024)).map { UInt8($0 % 251) })

        try AtomicFileWriter.append(payload, to: url)

        XCTAssertEqual(try Data(contentsOf: url), Data("{\"a\":1}\n".utf8) + payload)
    }

    /// Adding to a ledger must not relax the permissions it was created with.
    func testAppendKeepsThePermissionsOfTheFileItAddsTo() throws {
        let url = tempDir.appendingPathComponent("log.jsonl")
        try Data("{\"a\":1}\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        try AtomicFileWriter.append(Data("{\"b\":2}\n".utf8), to: url)

        XCTAssertEqual(try mode(of: url), 0o600)
    }

    func testAppendThrowsWhenTheTargetCannotBeOpened() throws {
        // A directory can be neither written as a new file nor opened for updating.
        let url = tempDir.appendingPathComponent("occupied")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)

        XCTAssertThrowsError(try AtomicFileWriter.append(Data("hi\n".utf8), to: url))
    }

    // MARK: - Reading lines back

    /// The read side of the same repair: a line whose bytes are not valid UTF-8
    /// costs only itself. The file used to be decoded as one whole string, so a
    /// single bad byte anywhere made the read fail and the ledger came back
    /// empty — every earlier record lost for the sake of one line.
    func testLoadLinesKeepsEveryOtherLineWhenOneIsNotValidUTF8() throws {
        let url = tempDir.appendingPathComponent("ledger.jsonl")
        var content = Data(#"{"id":"first"}"#.utf8) + Data("\n".utf8)
        content += Data([0xFF, 0xFE, 0xFF]) + Data("\n".utf8)
        content += Data(#"{"id":"third"}"#.utf8) + Data("\n".utf8)
        try content.write(to: url)

        let entries = AtomicFileWriter.loadLines(from: url, as: LedgerEntry.self)

        XCTAssertEqual(entries.map(\.id), ["first", "third"], "in file order, the bad line skipped")
    }

    /// The truncation `append` exists to survive, read back: a kill part-way
    /// through the em dash in a title leaves a final line that is not valid
    /// UTF-8, and every record written before it is still there.
    func testLoadLinesKeepsEarlierEntriesWhenTheLastLineIsCutMidCharacter() throws {
        let url = tempDir.appendingPathComponent("ledger.jsonl")
        let cut = Data(#"{"id":"cut — "#.utf8).dropLast(2)
        XCTAssertNil(String(data: cut, encoding: .utf8), "the em dash is genuinely cut in half")
        var content = Data(#"{"id":"first"}"#.utf8) + Data("\n".utf8)
        content += Data(#"{"id":"second"}"#.utf8) + Data("\n".utf8)
        content += cut
        try content.write(to: url)

        let entries = AtomicFileWriter.loadLines(from: url, as: LedgerEntry.self)

        XCTAssertEqual(entries.map(\.id), ["first", "second"])
    }

    /// The two shapes that are not corruption at all: a ledger nothing has
    /// written yet reads as empty, and a blank line — what the append repair
    /// leaves when it prepends a newline nobody needed — is dropped rather than
    /// failing the read.
    func testLoadLinesReadsAMissingFileAsEmptyAndDropsBlankLines() throws {
        let missing = tempDir.appendingPathComponent("never-written.jsonl")
        XCTAssertEqual(AtomicFileWriter.loadLines(from: missing, as: LedgerEntry.self).count, 0)

        let url = tempDir.appendingPathComponent("ledger.jsonl")
        try Data("\n{\"id\":\"first\"}\n\n\n{\"id\":\"second\"}\n\n".utf8).write(to: url)

        let entries = AtomicFileWriter.loadLines(from: url, as: LedgerEntry.self)

        XCTAssertEqual(entries.map(\.id), ["first", "second"])
    }

    // MARK: - The commit

    /// The commit both paths make, at the only point it is observable: a
    /// descriptor nothing can be flushed through must throw rather than return as
    /// though the bytes were on the platter — the whole reason `append` stopped
    /// using a `FileHandle`, which reported success having flushed nothing.
    func testCommitThrowsWhenTheDescriptorCannotBeFlushed() {
        XCTAssertThrowsError(try AtomicFileWriter.commit(-1)) { error in
            guard case AtomicFileWriter.WriteError.posix(let operation, let code) = error else {
                return XCTFail("expected a posix write error, got \(error)")
            }
            XCTAssertEqual(operation, "fsync")
            XCTAssertEqual(code, EBADF, "the errno at the failure, not whatever cleanup left behind")
        }
    }

    /// `/dev/null` takes writes and refuses `F_FULLFSYNC` with ENODEV, which is the
    /// answer a network mount gives too: the fallback to `fsync` has to carry the
    /// append rather than the unsupported call failing it.
    func testAppendFallsBackToFsyncWhereFullFsyncIsUnsupported() throws {
        try AtomicFileWriter.append(Data("{\"a\":1}\n".utf8), to: URL(fileURLWithPath: "/dev/null"))
    }


    // MARK: - Paths as the user wrote them

    /// A knowledge repo lives wherever the user put it, and "~/Documents/My
    /// Project/config.json" is an ordinary place. The path handed to `rename(2)`
    /// and `open(2)` has to be the one on disk, not the URL's percent-encoded
    /// spelling — `knowledge%20repo` is a directory that does not exist, and a
    /// save into it fails every time for a user whose folder has a space in it.
    func testWritesToAPathWithSpacesInIt() throws {
        let directory = tempDir.appendingPathComponent("knowledge repo")
        let url = directory.appendingPathComponent("team config.json")

        try AtomicFileWriter.write(Data("hi".utf8), to: url)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "hi")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)),
                       ["team config.json"], "the file lands under its own name, with no temp sibling")
    }

    /// The same for the ledger path: a file with a space in its name that is
    /// there must be appended to, not mistaken for one that is not and replaced
    /// wholesale — the first record of the day would otherwise erase the rest.
    func testAppendsToAnExistingFileWithASpaceInItsName() throws {
        let url = tempDir.appendingPathComponent("run log.jsonl")
        try Data("{\"a\":1}\n".utf8).write(to: url)

        try AtomicFileWriter.append(Data("{\"b\":2}\n".utf8), to: url)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{\"a\":1}\n{\"b\":2}\n")
    }

    // MARK: - Descriptor zero

    /// Descriptor 0 is a valid descriptor. With stdin closed it is the lowest
    /// free number, so `open(2)` hands it to the temp file, and again to the
    /// directory being flushed — and a check written `fd > 0` reads either as a
    /// failure: the save throws, or the directory descriptor is never closed.
    func testWriteAcceptsDescriptorZeroAndClosesItAgain() async throws {
        let url = tempDir.appendingPathComponent("config.json")

        try await withDescriptorZeroFree {
            try AtomicFileWriter.write(Data("hi".utf8), to: url)

            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "hi")
            XCTAssertEqual(fcntl(0, F_GETFD), -1,
                           "every descriptor the write opened is closed again, descriptor 0 included")
        }
    }

    /// And the append, which opens the ledger itself rather than a temp sibling.
    func testAppendAcceptsDescriptorZeroAndClosesItAgain() async throws {
        let url = tempDir.appendingPathComponent("log.jsonl")
        try Data("{\"a\":1}\n".utf8).write(to: url)

        try await withDescriptorZeroFree {
            try AtomicFileWriter.append(Data("{\"b\":2}\n".utf8), to: url)

            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{\"a\":1}\n{\"b\":2}\n")
            XCTAssertEqual(fcntl(0, F_GETFD), -1,
                           "the ledger descriptor is closed again, descriptor 0 included")
        }
    }

    // MARK: - A write the kernel refuses

    /// Only an interrupted `write(2)` is retried. One the kernel refuses for any
    /// other reason is reported, with that reason — retrying it would spin
    /// forever on the same answer, and a save that never returns is worse than
    /// one that fails.
    ///
    /// `RLIMIT_FSIZE` is the one refusal a test can arrange on demand: past the
    /// limit the kernel commits what fits and answers the rest with `EFBIG`, so
    /// this also drives the loop through a short write first. `SIGXFSZ` is
    /// ignored for the duration, since its default action is to kill the
    /// process. The write runs on its own thread so a retry loop costs this test
    /// its timeout rather than the run; lifting the limit afterwards is what
    /// lets such a loop finish.
    func testAWriteRefusedForAnyReasonButAnInterruptIsReportedNotRetried() throws {
        let url = tempDir.appendingPathComponent("config.json")
        try Data("good".utf8).write(to: url)

        var limit = rlimit()
        XCTAssertEqual(getrlimit(RLIMIT_FSIZE, &limit), 0)
        let previousLimit = limit
        let previousHandler = signal(SIGXFSZ, SIG_IGN)
        limit.rlim_cur = 16
        XCTAssertEqual(setrlimit(RLIMIT_FSIZE, &limit), 0)
        defer {
            var restored = previousLimit
            setrlimit(RLIMIT_FSIZE, &restored)
            signal(SIGXFSZ, previousHandler)
        }

        let outcome = WriteOutcome()
        let worker = Thread {
            outcome.record(Result { try AtomicFileWriter.write(Data(count: 4096), to: url) })
        }
        worker.start()

        guard outcome.finished.wait(timeout: .now() + 5) == .success else {
            return XCTFail("the refused write was retried instead of reported")
        }
        XCTAssertThrowsError(try outcome.result?.get()) { error in
            guard case AtomicFileWriter.WriteError.posix(let operation, let code) = error else {
                return XCTFail("expected a posix write error, got \(error)")
            }
            XCTAssertEqual(operation, "write")
            XCTAssertEqual(code, EFBIG, "the kernel's reason, not an interrupt's")
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "good",
                       "the refused replacement leaves the previous file alone")
        XCTAssertEqual(try directoryEntries(), ["config.json"], "and no temp sibling behind")
    }

    // MARK: - Helpers

    private func directoryEntries() throws -> [String] {
        try FileManager.default
            .contentsOfDirectory(atPath: tempDir.path(percentEncoded: false))
            .sorted()
    }

    private func mode(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return try XCTUnwrap(attributes[.posixPermissions] as? Int)
    }
}

/// One record in a JSONL ledger, as small as the ledgers' own lines: what
/// `loadLines` has to hand back is only that it decoded.
private struct LedgerEntry: Codable, Equatable {
    let id: String
}

/// What the write on the worker thread came back with, for the test that runs
/// one off the main thread. Locked: the thread writes it, the test reads it.
private final class WriteOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<Void, any Error>?
    let finished = DispatchSemaphore(value: 0)

    func record(_ result: Result<Void, any Error>) {
        lock.withLock { stored = result }
        finished.signal()
    }

    var result: Result<Void, any Error>? {
        lock.withLock { stored }
    }
}
