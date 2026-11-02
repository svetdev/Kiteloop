import XCTest
@testable import KiteloopCore

/// The control API's access log: one line per request naming what was asked,
/// by which credential and how it went — never the query string — rotated
/// once it fills.
final class ControlAccessLogTests: XCTestCase {

    private var url: URL!

    override func setUpWithError() throws {
        url = try makeTemporaryDirectory(prefix: "control-access-log").appending(path: "logs/control-access.log")
    }

    func testARequestWritesOneLineWithItsMethodPathCredentialAndStatus() async throws {
        let log = ControlAccessLog(url: url)
        await log.record(at: Date(timeIntervalSince1970: 0), method: "POST", path: "/v1/agents/message",
                         credential: "Work iPhone", status: 200, milliseconds: 12)

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text, "1970-01-01T00:00:00Z\tPOST\t/v1/agents/message\tWork iPhone\t200\t12ms\n")
    }

    func testTheQueryStringIsLeftOut() {
        let line = ControlAccessLog.line(at: .now, method: "GET", path: "/v1/workspace/file?project=a&path=.env",
                                         credential: "control", status: 403, milliseconds: 1)
        XCTAssertTrue(line.contains("\t/v1/workspace/file\t"))
        XCTAssertFalse(line.contains("path=.env"))
    }

    func testLinesAppend() async throws {
        let log = ControlAccessLog(url: url)
        await log.record(at: .now, method: "GET", path: "/health", credential: "none", status: 200, milliseconds: 1)
        await log.record(at: .now, method: "GET", path: "/v1/projects", credential: "control", status: 200, milliseconds: 2)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8).split(separator: "\n").count, 2)
    }

    func testAFullLogIsRotatedKeepingOneOlderFile() async throws {
        let log = ControlAccessLog(url: url, cap: 100)
        for _ in 0..<5 {
            await log.record(at: .now, method: "GET", path: "/v1/projects", credential: "control", status: 200, milliseconds: 2)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("1").path(percentEncoded: false)))
        let current = try String(contentsOf: url, encoding: .utf8)
        XCTAssertLessThan(current.utf8.count, 200, "the current file restarted after the rotation")
    }

    func testTheLogIsPrivate() async throws {
        await ControlAccessLog(url: url).record(at: .now, method: "GET", path: "/health", credential: "none",
                                                status: 200, milliseconds: 1)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }
}
