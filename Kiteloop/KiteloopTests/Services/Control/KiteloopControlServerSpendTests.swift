import KiteloopCore
import XCTest
@testable import Kiteloop

/// `GET /v1/spend`, in process: the ledger's rows over a window, grouped the
/// way the caller asks.
@MainActor
final class KiteloopControlServerSpendTests: XCTestCase {

    private var tempDir: URL!
    private var server: KiteloopControlServer!
    private var ledger: SpendLedger!
    private let token = "spend-token"

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "control-spend")
        ledger = SpendLedger(url: tempDir.appendingPathComponent("spend-ledger.jsonl"))
        server = KiteloopControlServer(registry: ControlSessionRegistry(), token: token)
        server.spendLedger = ledger
    }

    func testOneDayByProjectHasTheDocumentedShape() async throws {
        let now = Date()
        ledger.append(SpendRow(at: now, source: .chat, project: "/p/a", agent: "dev", model: "opus",
                               costUSD: 1.5, basis: .usd))
        ledger.append(SpendRow(at: now, source: .autopilot, project: "/p/b", costUSD: 2, basis: .usd))
        ledger.append(SpendRow(at: now, source: .routine, project: "/p/a", routine: "brief",
                               costUSD: 0.5, basis: .usd))
        ledger.append(SpendRow(at: now.addingTimeInterval(-3 * 86_400), source: .chat, project: "/p/a",
                               costUSD: 9, basis: .usd))

        let response = await get(["by": "project", "days": "1"])

        XCTAssertEqual(response.status, 200)
        let body = json(response)
        XCTAssertEqual(body["by"] as? String, "project")
        XCTAssertEqual(body["basis"] as? String, "usd")
        XCTAssertEqual(body["totalUSD"] as? Double, 4)
        XCTAssertNotNil(body["from"] as? String)
        XCTAssertNotNil(body["to"] as? String)
        let rows = try XCTUnwrap(body["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["key"] as? String }, ["/p/a", "/p/b"])
        XCTAssertEqual(rows.map { $0["costUSD"] as? Double }, [2, 2])
        XCTAssertEqual(rows.map { $0["count"] as? Int }, [2, 1])
    }

    func testAGroupingNobodyKnowsIs400() async {
        XCTAssertEqual(await get(["by": "bogus"]).status, 400)
        XCTAssertEqual(await get([:]).status, 400)
    }

    func testAServerWithNoLedgerAnswers503() async {
        server.spendLedger = nil
        XCTAssertEqual(await get(["by": "agent"]).status, 503)
    }

    func testDaysDefaultsToSevenAndIsClampedFromTodaysMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let midnight = calendar.startOfDay(for: now)
        func from(_ days: String?) -> Date {
            KiteloopControlServer.spendWindow(days: days, now: now, calendar: calendar).from
        }

        XCTAssertEqual(from("1"), midnight)
        XCTAssertEqual(from(nil), midnight.addingTimeInterval(-6 * 86_400))
        XCTAssertEqual(from("0"), midnight)
        XCTAssertEqual(from("500"), midnight.addingTimeInterval(-89 * 86_400))
        XCTAssertEqual(KiteloopControlServer.spendWindow(days: "3", now: now, calendar: calendar).to, now)
    }

    // MARK: - Helpers

    private func get(_ query: [String: String]) async -> HTTPServer.Response {
        await server.handle(HTTPServer.Request(method: "GET", path: "/v1/spend", query: query,
                                               headers: ["authorization": "Bearer \(token)"], body: Data()))
    }

    private func json(_ response: HTTPServer.Response) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
    }
}
