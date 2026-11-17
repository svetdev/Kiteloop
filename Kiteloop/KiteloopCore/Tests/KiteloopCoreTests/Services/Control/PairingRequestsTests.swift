import XCTest
import KiteloopTestSupport
@testable import KiteloopCore

/// A pairing code a device sent pairs nothing until the person allows it: the
/// caller is suspended until they answer, the sheet closes or the caller
/// leaves, and a code two devices sent pairs neither.
@MainActor
final class PairingRequestsTests: XCTestCase {

    private var requests: PairingRequests!

    override func setUp() async throws {
        requests = PairingRequests()
    }

    /// Files a request for `code` and waits until it is the one waiting.
    private func file(_ code: String = "code", name: String = "Work iPhone")
        async throws -> (request: PairingRequest, caller: Task<PairingRequests.Outcome, Never>) {
        let requests = requests!
        let request = PairingRequest(code: code, name: name)
        let caller = Task { await requests.outcome(of: request) }
        try await eventually("the request to be waiting") { requests.waiting[code]?.id == request.id }
        return (request, caller)
    }

    func testACallerWithTheCodeIsHeldUntilThePersonAnswers() async throws {
        let (request, caller) = try await file()

        // Nothing but an answer ends the wait.
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(requests.waiting["code"], request)

        XCTAssertTrue(requests.answer(code: "code", allow: true))
        let outcome = await caller.value
        XCTAssertEqual(outcome, .allowed)
        XCTAssertTrue(requests.waiting.isEmpty)
    }

    func testADeclineEndsTheRequestDeclined() async throws {
        let (_, caller) = try await file()

        XCTAssertTrue(requests.answer(code: "code", allow: false))

        let outcome = await caller.value
        XCTAssertEqual(outcome, .declined)
        XCTAssertTrue(requests.waiting.isEmpty)
    }

    func testClosingTheSheetEndsTheRequestWithdrawn() async throws {
        let (_, caller) = try await file()

        requests.withdraw(code: "code")

        let outcome = await caller.value
        XCTAssertEqual(outcome, .withdrawn)
        XCTAssertFalse(requests.answer(code: "code", allow: true), "nothing is left to allow")
    }

    func testACallerWhoHangsUpLeavesNothingToAllow() async throws {
        let (request, caller) = try await file()

        requests.callerLeft(request)

        let outcome = await caller.value
        XCTAssertEqual(outcome, .callerGone)
        XCTAssertFalse(requests.answer(code: "code", allow: true))
        XCTAssertFalse(requests.contested.contains("code"), "the code can still be scanned again")
    }

    func testASecondDeviceSendingTheSameCodeEndsBothAndPairsNeither() async throws {
        let (_, first) = try await file(name: "Someone quicker")

        let second = await requests.outcome(of: PairingRequest(code: "code", name: "Work iPhone"))

        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .contested)
        XCTAssertEqual(second, .contested)
        XCTAssertTrue(requests.waiting.isEmpty)
        XCTAssertTrue(requests.contested.contains("code"))
        XCTAssertFalse(requests.answer(code: "code", allow: true), "a contested code has nobody to allow")
    }

    func testAContestedCodeStaysContestedUntilItsSheetCloses() async throws {
        let (_, first) = try await file()
        _ = await requests.outcome(of: PairingRequest(code: "code", name: "Second"))
        _ = await first.value

        let third = await requests.outcome(of: PairingRequest(code: "code", name: "Third"))
        XCTAssertEqual(third, .contested)

        requests.withdraw(code: "code")
        XCTAssertFalse(requests.contested.contains("code"))
    }

    func testACallerLeavingLateDoesNotEndTheRequestThatFollowedIt() async throws {
        let (gone, firstCaller) = try await file()
        requests.callerLeft(gone)
        _ = await firstCaller.value
        let (_, secondCaller) = try await file(name: "Rescanned")

        requests.callerLeft(gone)

        XCTAssertEqual(requests.waiting["code"]?.name, "Rescanned")
        requests.answer(code: "code", allow: true)
        let outcome = await secondCaller.value
        XCTAssertEqual(outcome, .allowed)
    }

    func testRequestsOnDifferentCodesAreAnsweredApart() async throws {
        let (_, one) = try await file("one")
        let (_, two) = try await file("two")

        requests.answer(code: "two", allow: false)
        requests.answer(code: "one", allow: true)

        let oneOutcome = await one.value
        let twoOutcome = await two.value
        XCTAssertEqual(oneOutcome, .allowed)
        XCTAssertEqual(twoOutcome, .declined)
    }
}
