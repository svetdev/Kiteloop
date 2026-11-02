import XCTest
@testable import KiteloopCore

/// The schema stamp is the one write in `SQLiteDatabase` whose failure cannot be
/// swallowed. `MetricIndex` writes it on open and reads it back on the next one,
/// and a file that was never stamped reads `0` — indistinguishable from a
/// database written by a schema this build doesn't know, which the index drops
/// and replays. So a lost stamp is not a lost write: it is a full rebuild on
/// every launch, for as long as the condition lasts, and nothing anywhere says
/// why. These tests are about the stamp round-tripping and about the failure
/// arriving as an error rather than as silence.
final class SQLiteDatabaseTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = try makeTemporaryDirectory(prefix: "sqlite-database")
    }

    private var databaseURL: URL { tempDir.appendingPathComponent("test.sqlite3") }

    // MARK: - Round trip

    /// The stamp is only worth writing if a later connection reads it back, since
    /// that read is the whole decision — same schema, or drop and replay.
    func testAStampedVersionSurvivesAReopen() throws {
        var database: SQLiteDatabase? = try SQLiteDatabase(url: databaseURL)
        try database?.setUserVersion(7)
        XCTAssertEqual(database?.userVersion, 7)
        database = nil

        let reopened = try SQLiteDatabase(url: databaseURL)

        XCTAssertEqual(reopened.userVersion, 7)
    }

    /// A file nobody has stamped reads `0` — the value that makes an unstamped
    /// database look stale, which is why the stamp failing has to be audible.
    func testAnUnstampedFileReadsZero() throws {
        let database = try SQLiteDatabase(url: databaseURL)

        XCTAssertEqual(database.userVersion, 0)
    }

    // MARK: - A stamp that cannot land

    /// Another connection holding the write lock is the shape of the real
    /// failures — a busy file, a full or read-only volume: the statement runs and
    /// cannot be applied. It must throw rather than return, or the caller carries
    /// on believing a version that isn't on disk.
    func testAStampThatCannotRunThrows() throws {
        let database = try SQLiteDatabase(url: databaseURL)
        try database.setUserVersion(7)
        let blocker = try SQLiteDatabase(url: databaseURL)
        try blocker.execute("BEGIN EXCLUSIVE")
        defer { try? blocker.execute("ROLLBACK") }

        XCTAssertThrowsError(try database.setUserVersion(9)) { error in
            guard let sqliteError = error as? SQLiteError,
                  case .step(let sql, _) = sqliteError else {
                return XCTFail("expected a SQLiteError.step, got \(error)")
            }
            XCTAssertTrue(sql.contains("user_version"), "the error should name the statement that failed, got \(sql)")
        }
        XCTAssertEqual(database.userVersion, 7, "the failed stamp must not have landed")
    }

    // MARK: - The file is where the URL says

    /// The URL is turned into a filesystem path for `sqlite3_open_v2`, and the
    /// directory it names can carry a space — `~/Library/Application Support`
    /// does. Percent-encoding it names a directory that does not exist, and the
    /// open fails before any schema is written.
    func testOpensAtAPathWhoseDirectoryHasASpace() throws {
        let spaced = tempDir.appendingPathComponent("Application Support", isDirectory: true)
        try FileManager.default.createDirectory(at: spaced, withIntermediateDirectories: true)
        let url = spaced.appendingPathComponent("metrics.sqlite3")

        let database = try SQLiteDatabase(url: url)
        try database.setUserVersion(3)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        XCTAssertEqual(try SQLiteDatabase(url: url).userVersion, 3)
    }

    // MARK: - run

    /// A statement that returns no rows finishes with `SQLITE_DONE`: that is
    /// success, and the row it wrote is there to read back.
    func testRunAppliesAParameterisedStatement() throws {
        let database = try SQLiteDatabase(url: databaseURL)
        try database.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")

        try database.run("INSERT INTO t (id, name) VALUES (?, ?)", [.int(1), .text("one")])

        XCTAssertEqual(try database.query("SELECT name FROM t WHERE id = ?", [.int(1)]) { $0.text(0) }, ["one"])
    }

    /// A statement that happens to yield a row — a `RETURNING` clause, a bare
    /// `PRAGMA` — is not a failure either; `run` discards the row.
    func testRunToleratesAStatementThatYieldsARow() throws {
        let database = try SQLiteDatabase(url: databaseURL)

        XCTAssertNoThrow(try database.run("SELECT 1"))
    }

    /// Every other status is a failure, and it must arrive as a thrown error
    /// naming the statement — a constraint the row violates being the common
    /// one — rather than as a row that silently did not land.
    func testRunReportsAStatementThatFails() throws {
        let database = try SQLiteDatabase(url: databaseURL)
        try database.execute("CREATE TABLE t (id INTEGER PRIMARY KEY)")
        try database.run("INSERT INTO t (id) VALUES (?)", [.int(1)])

        XCTAssertThrowsError(try database.run("INSERT INTO t (id) VALUES (?)", [.int(1)])) { error in
            guard let sqliteError = error as? SQLiteError,
                  case .step(let sql, _) = sqliteError else {
                return XCTFail("expected a SQLiteError.step, got \(error)")
            }
            XCTAssertTrue(sql.contains("INSERT"), "the error should name the statement that failed, got \(sql)")
        }
        XCTAssertEqual(try database.query("SELECT count(*) FROM t") { $0.int(0) }, [1])
    }

    // MARK: - NULL is not zero

    /// "Not recorded" and "zero" are different facts, and the optional accessors
    /// are how the first survives a round trip: a NULL reads as nil, a recorded
    /// zero reads as zero, a recorded value reads as itself.
    func testOptionalAccessorsDistinguishNullFromZero() throws {
        let database = try SQLiteDatabase(url: databaseURL)
        try database.execute("CREATE TABLE t (n INTEGER, d REAL, s TEXT)")
        try database.run("INSERT INTO t VALUES (?, ?, ?)", [.null, .null, .null])
        try database.run("INSERT INTO t VALUES (?, ?, ?)", [.int(0), .double(0), .text("")])
        try database.run("INSERT INTO t VALUES (?, ?, ?)", [.int(5), .double(2.5), .text("five")])

        XCTAssertEqual(try database.query("SELECT n FROM t ORDER BY rowid") { $0.isNull(0) }, [true, false, false])
        XCTAssertEqual(try database.query("SELECT n FROM t ORDER BY rowid") { $0.optInt(0) }, [nil, 0, 5])
        XCTAssertEqual(try database.query("SELECT d FROM t ORDER BY rowid") { $0.optDouble(0) }, [nil, 0, 2.5])
        XCTAssertEqual(try database.query("SELECT s FROM t ORDER BY rowid") { $0.optText(0) }, [nil, "", "five"])
    }

    /// A Bool is stored as 1 or 0 and must come back as the Bool it was — with
    /// "never recorded" still a nil rather than either.
    func testBoolSurvivesARoundTrip() throws {
        let database = try SQLiteDatabase(url: databaseURL)
        try database.execute("CREATE TABLE t (flag INTEGER)")
        for value in [true, false, nil] as [Bool?] {
            try database.run("INSERT INTO t VALUES (?)", [.of(value)])
        }

        XCTAssertEqual(try database.query("SELECT flag FROM t ORDER BY rowid") { $0.optBool(0) }, [true, false, nil])
    }
}
