import KiteloopCore
import XCTest
@testable import Kiteloop

/// `GET /v1/spend`, in process: the ledger's rows over a window, grouped the
/// way the caller asks — and `GET /v1/spend/forecast`, what they say is coming.
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
        let unknown = await get(["by": "bogus"])
        let missing = await get([:])
        XCTAssertEqual(unknown.status, 400)
        XCTAssertEqual(missing.status, 400)
    }

    func testAServerWithNoLedgerAnswers503() async {
        server.spendLedger = nil
        let answer = await get(["by": "agent"])
        XCTAssertEqual(answer.status, 503)
    }

    func testDaysDefaultsToSevenAndIsClampedFromTodaysMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let midnight = calendar.startOfDay(for: now)
        func from(_ days: String?) -> Date {
            SpendEndpoints.window(days: days, now: now, calendar: calendar).from
        }

        XCTAssertEqual(from("1"), midnight)
        XCTAssertEqual(from(nil), midnight.addingTimeInterval(-6 * 86_400))
        XCTAssertEqual(from("0"), midnight)
        XCTAssertEqual(from("500"), midnight.addingTimeInterval(-89 * 86_400))
        XCTAssertEqual(SpendEndpoints.window(days: "3", now: now, calendar: calendar).to, now)
    }

    // MARK: - The headroom token-equivalent spend is drawn from

    private var readings: [AgentActivityEvent.RateLimitInfo] {
        [AgentActivityEvent.RateLimitInfo(status: "allowed", window: "seven_day", resetsAt: nil, utilization: 0.3),
         AgentActivityEvent.RateLimitInfo(status: "allowed_warning", window: "five_hour",
                                          resetsAt: Date(timeIntervalSince1970: 1_800_000_000), utilization: 0.8)]
    }

    func testTokenEquivalentSpendCarriesTheReadingClosestToItsLimit() async throws {
        ledger.append(SpendRow(at: Date(), source: .chat, project: "/p/a", costUSD: 1, basis: .tokenEquivalent))
        ledger.append(SpendRow(at: Date(), source: .autopilot, project: "/p/a", costUSD: 2, basis: .tokenEquivalent))

        let response = await SpendEndpoints(ledger: ledger, readings: readings).answer(["by": "project", "days": "1"])

        XCTAssertEqual(response.status, 200)
        let body = json(response)
        XCTAssertEqual(body["basis"] as? String, "token-equivalent")
        let rateLimit = try XCTUnwrap(body["rateLimit"] as? [String: Any])
        XCTAssertEqual(rateLimit["status"] as? String, "allowed_warning")
        XCTAssertEqual(rateLimit["window"] as? String, "five_hour")
        XCTAssertEqual(rateLimit["resetsAt"] as? String, "2027-01-15T08:00:00Z")
        XCTAssertEqual(rateLimit["utilization"] as? Double, 0.8)
    }

    func testMixedSpendCarriesTheReadingToo() async {
        ledger.append(SpendRow(at: Date(), source: .chat, project: "/p/a", costUSD: 1, basis: .tokenEquivalent))
        ledger.append(SpendRow(at: Date(), source: .chat, project: "/p/b", costUSD: 1, basis: .usd))

        let response = await SpendEndpoints(ledger: ledger, readings: readings).answer(["by": "project", "days": "1"])

        let body = json(response)
        XCTAssertEqual(body["basis"] as? String, "mixed")
        XCTAssertEqual((body["rateLimit"] as? [String: Any])?["status"] as? String, "allowed_warning")
    }

    func testBilledSpendHasNoRateLimitEvenWhenAgentsReportOne() async {
        ledger.append(SpendRow(at: Date(), source: .chat, project: "/p/a", costUSD: 1, basis: .usd))

        let response = await SpendEndpoints(ledger: ledger, readings: readings).answer(["by": "project", "days": "1"])

        XCTAssertEqual(response.status, 200)
        let body = json(response)
        XCTAssertEqual(body["basis"] as? String, "usd")
        XCTAssertTrue(body["rateLimit"] is NSNull)
    }

    func testTokenEquivalentSpendWithNoReadingIsNullAndStill200() async {
        ledger.append(SpendRow(at: Date(), source: .chat, project: "/p/a", costUSD: 1, basis: .tokenEquivalent))

        let direct = await SpendEndpoints(ledger: ledger).answer(["by": "project", "days": "1"])
        let routed = await get(["by": "project", "days": "1"])

        for response in [direct, routed] {
            XCTAssertEqual(response.status, 200)
            let body = json(response)
            XCTAssertEqual(body["basis"] as? String, "token-equivalent")
            XCTAssertTrue(body["rateLimit"] is NSNull)
        }
    }

    // MARK: - The forecast

    func testTheForecastHasTheDocumentedShape() async throws {
        let now = Date()
        for cost in [1.0, 2, 3, 4, 10] {
            ledger.append(SpendRow(at: now, source: .routine, project: "/p/a", routine: "brief",
                                   costUSD: cost, basis: .usd))
        }
        ledger.append(SpendRow(at: now, source: .routine, project: "/p/a", routine: "new", costUSD: 1, basis: .usd))
        ledger.append(SpendRow(at: now, source: .chat, project: "/p/b", costUSD: 2, basis: .tokenEquivalent))

        let response = await get([:], path: "/v1/spend/forecast")

        XCTAssertEqual(response.status, 200)
        let body = json(response)
        XCTAssertEqual((body["month"] as? String)?.count, 7)
        XCTAssertNotNil(body["asOf"] as? String)
        let projects = try XCTUnwrap(body["projects"] as? [[String: Any]])
        XCTAssertEqual(projects.map { $0["project"] as? String }, ["/p/a", "/p/b"])
        XCTAssertEqual(projects.map { $0["monthToDateUSD"] as? Double }, [21, 2])
        XCTAssertEqual(projects.map { $0["basis"] as? String }, ["usd", "token-equivalent"])
        let first = try XCTUnwrap(projects.first)
        let elapsed = try XCTUnwrap(first["daysElapsed"] as? Int)
        let inMonth = try XCTUnwrap(first["daysInMonth"] as? Int)
        let projected = try XCTUnwrap(first["projectedMonthEndUSD"] as? Double)
        XCTAssertEqual(projected, 21 / Double(elapsed) * Double(inMonth), accuracy: 0.0001)

        let routines = try XCTUnwrap(body["routines"] as? [[String: Any]])
        XCTAssertEqual(routines.map { $0["routine"] as? String }, ["brief", "new"])
        XCTAssertEqual(routines.map { $0["runs"] as? Int }, [5, 1])
        XCTAssertEqual(routines[0]["expectedUSD"] as? Double, 3)
        XCTAssertEqual(routines[0]["lowUSD"] as? Double, 1)
        XCTAssertEqual(routines[0]["highUSD"] as? Double, 10)
        for figure in ["expectedUSD", "lowUSD", "highUSD"] {
            XCTAssertTrue(routines[1][figure] is NSNull, "one run is too little history for \(figure)")
        }
    }

    func testTheForecastNarrowsItsProjectionsToOneProject() async throws {
        ledger.append(SpendRow(at: Date(), source: .chat, project: "/p/a", costUSD: 1, basis: .usd))
        ledger.append(SpendRow(at: Date(), source: .routine, project: "/p/b", routine: "brief",
                               costUSD: 2, basis: .usd))

        let response = await get(["project": "/p/a"], path: "/v1/spend/forecast")

        let body = json(response)
        let projects = try XCTUnwrap(body["projects"] as? [[String: Any]])
        XCTAssertEqual(projects.map { $0["project"] as? String }, ["/p/a"])
        XCTAssertEqual((body["routines"] as? [[String: Any]])?.count, 1, "the filter narrows projects only")
    }

    func testTheForecastOnAServerWithNoLedgerAnswers503() async {
        server.spendLedger = nil
        let answer = await get([:], path: "/v1/spend/forecast")
        XCTAssertEqual(answer.status, 503)
    }

    // MARK: - Helpers

    private func get(_ query: [String: String], path: String = "/v1/spend") async -> HTTPServer.Response {
        await server.handle(HTTPServer.Request(method: "GET", path: path, query: query,
                                               headers: ["authorization": "Bearer \(token)"], body: Data()))
    }

    private func json(_ response: HTTPServer.Response) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
    }
}
