import XCTest
import KiteloopCore
@testable import Kiteloop

/// `POST /v1/backlog/approve` — the human gate, resolved without a run id. It is
/// the one control-API call that rewrites the user's BACKLOG.md, so these tests
/// go all the way through: real loopback socket, real `BacklogViewModel` over a
/// real file on disk, asserting the item's status actually flipped (and got
/// written back) rather than just that the response said so.
@MainActor
final class KiteloopControlServerBacklogApproveTests: XCTestCase {

    private var tempDir: URL!
    private var registry: ControlSessionRegistry!
    private var harness: ControlServerHarness!
    private let token = "control-approve-token-" + UUID().uuidString

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "control-approve")
        registry = ControlSessionRegistry()
        harness = try await ControlServerHarness.start(registry: registry, token: token)
    }

    override func tearDown() async throws {
        harness?.stop()
        harness = nil
        registry = nil
    }

    // MARK: - The notice is a view of the gate

    /// The acceptance criterion this endpoint owes: approving over the API
    /// resolves the item's approval notice, and the row says which surface did
    /// it. Before this only a click cleared one, so every headless approval left
    /// its summons standing — 227 of them in this repo alone by 2026-08-15.
    func testApprovingOverTheAPIResolvesTheItemsApprovalNotice() async throws {
        try registerProject(named: "alpha", items: [
            "- [ ] item-1 | Needs sign-off | awaiting-approval"
        ])
        try await postApprovalNotice(project: "alpha", itemID: "item-1")

        let (status, _) = try await harness.post("/v1/backlog/approve", [
            "project": "alpha", "item": "item-1", "approve": true
        ])
        XCTAssertEqual(status, 200)

        let store = try inbox(project: "alpha")
        try await eventually("the summons to resolve itself") {
            await store.actionablePendingCount() == 0
        }
        let resolved = await store.resolved()
        XCTAssertEqual(resolved.first?.resolution, "approved via API",
                       "the row has to say which surface closed the gate")
    }

    /// Rejecting closes the gate just as much: the item is back with a worker,
    /// so nobody is being summoned to it either.
    func testRejectingOverTheAPIResolvesTheItemsApprovalNotice() async throws {
        try registerProject(named: "alpha", items: [
            "- [ ] item-1 | Needs sign-off | awaiting-approval"
        ])
        try await postApprovalNotice(project: "alpha", itemID: "item-1")

        _ = try await harness.post("/v1/backlog/approve", [
            "project": "alpha", "item": "item-1", "approve": false, "reason": "AC 3 unimplemented"
        ])

        let store = try inbox(project: "alpha")
        try await eventually("the summons to resolve itself") {
            await store.actionablePendingCount() == 0
        }
        let resolved = await store.resolved()
        XCTAssertEqual(resolved.first?.resolution, "rejected")
    }

    /// A call the endpoint turns away leaves the gate exactly where it was, so
    /// the summons has to still be standing — this is the failure that would
    /// silently clear a row nobody has answered.
    func testARefusedApprovalLeavesTheSummonsStanding() async throws {
        try registerProject(named: "alpha", items: [
            "- [x] item-1 | Already done | done"
        ])
        try await postApprovalNotice(project: "alpha", itemID: "item-1")

        let (status, _) = try await harness.post("/v1/backlog/approve", [
            "project": "alpha", "item": "item-1", "approve": true
        ])
        XCTAssertEqual(status, 409)

        let store = try inbox(project: "alpha")
        let pending = await store.actionablePendingCount()
        XCTAssertEqual(pending, 1)
    }

    // MARK: - Approve

    /// The point of the endpoint: an item parked at the gate ends up Done, and
    /// the response reports the status the caller can expect to read back.
    func testApproveFlipsItemToDone() async throws {
        let backlog = try registerProject(named: "alpha", items: [
            "- [ ] item-1 | Needs sign-off | awaiting-approval"
        ])

        let (status, body) = try await harness.post("/v1/backlog/approve", [
            "project": "alpha", "item": "item-1", "approve": true
        ])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["item"] as? String, "item-1")
        XCTAssertEqual(body["resolved"] as? String, "approved")
        XCTAssertEqual(body["status"] as? String, "done")
        XCTAssertEqual(item("item-1", in: backlog)?.status, .done)
    }

    /// Approving stamps the completion date, so the item reads as finished today
    /// rather than as a Done item of unknown vintage.
    func testApproveStampsCompletionDate() async throws {
        let backlog = try registerProject(named: "alpha", items: [
            "- [ ] item-1 | Needs sign-off | awaiting-approval"
        ])

        _ = try await harness.post("/v1/backlog/approve", ["project": "alpha", "item": "item-1"])

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        XCTAssertEqual(item("item-1", in: backlog)?.completedDate, formatter.string(from: Date()))
    }

    /// BACKLOG.md is the source of truth — a status flip that only lived in
    /// memory would be lost the moment the file is re-read.
    func testApproveIsWrittenBackToBacklogFile() async throws {
        try registerProject(named: "alpha", items: [
            "- [ ] item-1 | Needs sign-off | awaiting-approval"
        ])

        _ = try await harness.post("/v1/backlog/approve", ["project": "alpha", "item": "item-1"])

        let onDisk = try backlogContents(project: "alpha")
        XCTAssertTrue(onDisk.contains("- [x] item-1"), "expected a checked item line, got:\n\(onDisk)")
        XCTAssertFalse(onDisk.contains("awaiting-approval"), "stale status left in file:\n\(onDisk)")
    }

    /// `approve` defaults to true: a driver that just wants to sign off can post
    /// the item alone.
    func testApproveDefaultsToTrueWhenOmitted() async throws {
        let backlog = try registerProject(named: "alpha", items: [
            "- [ ] item-1 | Needs sign-off | awaiting-approval"
        ])

        let (status, body) = try await harness.post("/v1/backlog/approve", ["project": "alpha", "item": "item-1"])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["resolved"] as? String, "approved")
        XCTAssertEqual(item("item-1", in: backlog)?.status, .done)
    }

    /// Only the addressed item moves; its neighbours at the same gate stay put.
    func testApproveLeavesOtherItemsAlone() async throws {
        let backlog = try registerProject(named: "alpha", items: [
            "- [ ] item-1 | Needs sign-off | awaiting-approval",
            "- [ ] item-2 | Also waiting | awaiting-approval"
        ])

        _ = try await harness.post("/v1/backlog/approve", ["project": "alpha", "item": "item-1"])

        XCTAssertEqual(item("item-1", in: backlog)?.status, .done)
        XCTAssertEqual(item("item-2", in: backlog)?.status, .awaitingApproval)
    }

    // MARK: - Reject

    /// Rejection is not a dead end: the item returns to Ready so the next run
    /// picks it up again.
    func testRejectReturnsItemToReady() async throws {
        let backlog = try registerProject(named: "alpha", items: [
            "- [ ] item-1 | Needs sign-off | awaiting-approval"
        ])

        let (status, body) = try await harness.post("/v1/backlog/approve", [
            "project": "alpha", "item": "item-1", "approve": false, "reason": "tests missing"
        ])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["resolved"] as? String, "rejected")
        XCTAssertEqual(body["status"] as? String, "ready")
        XCTAssertEqual(item("item-1", in: backlog)?.status, .ready)
        XCTAssertNil(item("item-1", in: backlog)?.completedDate)
    }

    /// The reason is the whole value of a rejection — it lands in the item's
    /// detail file, which the next worker run reads as context.
    func testRejectRecordsReasonInTheDetailFile() async throws {
        try registerProject(
            named: "alpha",
            items: ["- [ ] item-1 | Needs sign-off | awaiting-approval → [detail](backlog/item-1.md)"],
            details: ["backlog/item-1.md": "# item-1\n\n## What\n\nShip it.\n"]
        )

        _ = try await harness.post("/v1/backlog/approve", [
            "project": "alpha", "item": "item-1", "approve": false, "reason": "tests missing"
        ])

        let detail = try String(
            contentsOf: tempDir.appending(path: "alpha/backlog/item-1.md"),
            encoding: .utf8
        )
        XCTAssertTrue(detail.contains("rejected: tests missing"), "no feedback recorded:\n\(detail)")
    }

    /// `itemId`/`approved` are accepted alongside `item`/`approve` so a driver
    /// built against either spelling keeps working.
    func testAcceptsItemIdAndApprovedAliases() async throws {
        let backlog = try registerProject(named: "alpha", items: [
            "- [ ] item-1 | Needs sign-off | awaiting-approval"
        ])

        let (status, body) = try await harness.post("/v1/backlog/approve", [
            "project": "alpha", "itemId": "item-1", "approved": false
        ])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["resolved"] as? String, "rejected")
        XCTAssertEqual(item("item-1", in: backlog)?.status, .ready)
    }

    // MARK: - The verdict is a boolean

    /// The verdict is validated rather than coerced, and this is the field where
    /// that matters most: an omitted verdict means *approve*, so anything the
    /// server can't read as a boolean has to be a 400 rather than a fallthrough
    /// to the default. `{"approve": "no"}` would otherwise sign off on the work
    /// its sender meant to send back. `0` is refused for the same reason `1` is
    /// — JSON hands booleans and numbers back as the same `NSNumber`, so a
    /// caller serialising `false` as `0` is a caller whose next `1` would be
    /// read as a sign-off nobody gave.
    func testRejectsANonBooleanVerdict() async throws {
        let backlog = try registerProject(named: "alpha", items: [
            "- [ ] item-1 | Needs sign-off | awaiting-approval"
        ])

        for (key, raw) in [("approve", 1), ("approve", 0), ("approved", 1)] as [(String, Any)] {
            let (status, body) = try await harness.post("/v1/backlog/approve", [
                "project": "alpha", "item": "item-1", key: raw
            ])

            XCTAssertEqual(status, 400, "\(key)=\(raw)")
            XCTAssertEqual(body["error"] as? String, "\"\(key)\" must be true or false")
            XCTAssertEqual(item("item-1", in: backlog)?.status, .awaitingApproval,
                           "the item stayed at its gate")
        }

        let (stringStatus, stringBody) = try await harness.post("/v1/backlog/approve", [
            "project": "alpha", "item": "item-1", "approve": "no"
        ])
        XCTAssertEqual(stringStatus, 400)
        XCTAssertEqual(stringBody["error"] as? String, "\"approve\" must be true or false")
        XCTAssertEqual(item("item-1", in: backlog)?.status, .awaitingApproval,
                       "a verdict the server can't read must never mean yes")
    }

    // MARK: - Errors

    /// The gate is only meaningful from `awaiting-approval`; approving an item
    /// still in flight would silently skip the work it hasn't done yet.
    func testItemNotAwaitingApprovalIs409() async throws {
        let backlog = try registerProject(named: "alpha", items: [
            "- [ ] item-1 | Not there yet | active"
        ])

        let (status, body) = try await harness.post("/v1/backlog/approve", [
            "project": "alpha", "item": "item-1"
        ])

        XCTAssertEqual(status, 409)
        XCTAssertEqual(body["error"] as? String, "Item 'item-1' is not awaiting approval (status: active)")
        XCTAssertEqual(item("item-1", in: backlog)?.status, .active)
    }

    /// Re-posting an approval is not idempotent — the item is Done by then, so
    /// the second call is refused rather than re-stamping it.
    func testApprovingTwiceIs409() async throws {
        try registerProject(named: "alpha", items: [
            "- [ ] item-1 | Needs sign-off | awaiting-approval"
        ])

        _ = try await harness.post("/v1/backlog/approve", ["project": "alpha", "item": "item-1"])
        let (status, body) = try await harness.post("/v1/backlog/approve", ["project": "alpha", "item": "item-1"])

        XCTAssertEqual(status, 409)
        XCTAssertEqual(body["error"] as? String, "Item 'item-1' is not awaiting approval (status: done)")
    }

    func testUnknownItemIs404() async throws {
        try registerProject(named: "alpha", items: [
            "- [ ] item-1 | Needs sign-off | awaiting-approval"
        ])

        let (status, body) = try await harness.post("/v1/backlog/approve", [
            "project": "alpha", "item": "ghost"
        ])

        XCTAssertEqual(status, 404)
        XCTAssertEqual(body["error"] as? String, "No backlog item 'ghost' in this project")
    }

    func testMissingItemIs400() async throws {
        try registerProject(named: "alpha", items: [
            "- [ ] item-1 | Needs sign-off | awaiting-approval"
        ])

        let (status, body) = try await harness.post("/v1/backlog/approve", ["project": "alpha"])

        XCTAssertEqual(status, 400)
        XCTAssertEqual(body["error"] as? String, "Body must include \"project\" and \"item\"")
    }

    func testMissingProjectIs400() async throws {
        let (status, body) = try await harness.post("/v1/backlog/approve", ["item": "item-1"])

        XCTAssertEqual(status, 400)
        XCTAssertEqual(body["error"] as? String, "Body must include \"project\" and \"item\"")
    }

    func testUnknownProjectIs409() async throws {
        try registerProject(named: "alpha", items: [
            "- [ ] item-1 | Needs sign-off | awaiting-approval"
        ])

        let (status, body) = try await harness.post("/v1/backlog/approve", [
            "project": "beta", "item": "item-1"
        ])

        XCTAssertEqual(status, 409)
        XCTAssertEqual(body["error"] as? String, "Project not open in Kiteloop: beta")
    }

    /// An unauthenticated caller must not be able to sign work off — and the
    /// item must not move.
    func testRequiresBearerToken() async throws {
        let backlog = try registerProject(named: "alpha", items: [
            "- [ ] item-1 | Needs sign-off | awaiting-approval"
        ])

        let (status, body) = try await harness.post("/v1/backlog/approve", ["project": "alpha", "item": "item-1"], bearer: nil)

        XCTAssertEqual(status, 401)
        XCTAssertEqual(body["error"] as? String, "Missing or invalid bearer token")
        XCTAssertEqual(item("item-1", in: backlog)?.status, .awaitingApproval)
    }

    // MARK: - Readiness

    /// The reason the fields exist: an item triaged to `ready` but never groomed
    /// is indistinguishable from a runnable one by id/title/status, so a driver
    /// used to discover it by starting a run and reading back a generic 422.
    func testUngroomedReadyItemReportsWhyItWouldNotBePickedUp() async throws {
        try registerProject(named: "alpha", items: [
            "- [ ] item-1 | Never groomed | ready"
        ])

        let (status, body) = try await harness.get("/v1/backlog?project=alpha")

        XCTAssertEqual(status, 200)
        let entry = try XCTUnwrap(backlogJSON(body).first { $0["id"] as? String == "item-1" })
        XCTAssertEqual(entry["ready"] as? Bool, false)
        let reasons = try XCTUnwrap(entry["notReady"] as? [String])
        XCTAssertTrue(reasons.contains { $0.contains("no groomed detail file") }, "\(reasons)")
        XCTAssertTrue(reasons.contains { $0.contains("no verify:") }, "\(reasons)")
        XCTAssertTrue(reasons.contains { $0.contains("no size set") }, "\(reasons)")
    }

    /// The other half: a fully groomed item says so, and carries no reasons to
    /// act on.
    func testGroomedReadyItemReportsReadyWithNoReasons() async throws {
        try registerProject(
            named: "alpha",
            items: ["- [ ] item-1 | Fully groomed | ready | size: S → [detail](backlog/item-1.md)"],
            details: ["backlog/item-1.md": groomedDetail(id: "item-1")]
        )

        let (status, body) = try await harness.get("/v1/backlog?project=alpha")

        XCTAssertEqual(status, 200)
        let entry = try XCTUnwrap(backlogJSON(body).first { $0["id"] as? String == "item-1" })
        XCTAssertEqual(entry["ready"] as? Bool, true)
        XCTAssertNil(entry["notReady"], "a ready item has nothing to report")
    }

    /// Pickup readiness is a meaningless question for an item nothing will pick
    /// up, and `loadDetail` costs a file parse per item — so no other status
    /// carries a verdict at all.
    func testOnlyReadyItemsCarryAReadinessVerdict() async throws {
        try registerProject(named: "alpha", items: [
            "- [ ] item-1 | Never groomed | ready",
            "- [ ] item-2 | Still a draft | draft",
            "- [ ] item-3 | In flight | active",
            "- [x] item-4 | Finished | done",
            "- [ ] item-5 | Stuck | blocked"
        ])

        let (_, body) = try await harness.get("/v1/backlog?project=alpha")

        let items = backlogJSON(body)
        XCTAssertEqual(items.count, 5)
        for entry in items where entry["status"] as? String != "ready" {
            XCTAssertNil(entry["ready"], "verdict invented for \(entry["id"] ?? "?")")
            XCTAssertNil(entry["notReady"], "reasons invented for \(entry["id"] ?? "?")")
        }
        // The unchanged fields are still what they were.
        let done = try XCTUnwrap(items.first { $0["id"] as? String == "item-4" })
        XCTAssertEqual(done["title"] as? String, "Finished")
        XCTAssertEqual(done["epic"] as? String, "Now")
    }

    /// The phrasing belongs to `DefinitionOfReady`, not to the handler: a rule
    /// reworded there has to show up here without anyone editing the server.
    func testReasonsAreTheGatesOwnWords() async throws {
        let backlog = try registerProject(named: "alpha", items: [
            "- [ ] item-1 | Half groomed | ready | size: XL"
        ])

        let (_, body) = try await harness.get("/v1/backlog?project=alpha")

        let item = try XCTUnwrap(item("item-1", in: backlog))
        let verdict = DefinitionOfReady.evaluate(item: item, detail: backlog.loadDetail(for: item))
        XCTAssertFalse(verdict.isReady, "Precondition: an XL item with no detail is not ready")
        let entry = try XCTUnwrap(backlogJSON(body).first { $0["id"] as? String == "item-1" })
        XCTAssertEqual(entry["notReady"] as? [String], verdict.reasons)
    }

    // MARK: - Provenance

    /// Lineage reaches a headless driver, so children can be grouped under the
    /// item they came out of without re-reading BACKLOG.md.
    func testAnItemReportsWhereItCameFrom() async throws {
        try registerProject(named: "alpha", items: [
            "- [ ] parent | The big one | done",
            "- [ ] child | Split out of the big one | from:parent | ready"
        ])

        let (status, body) = try await harness.get("/v1/backlog?project=alpha")

        XCTAssertEqual(status, 200)
        let child = try XCTUnwrap(backlogJSON(body).first { $0["id"] as? String == "child" })
        XCTAssertEqual(child["from"] as? String, "parent")
        let parent = try XCTUnwrap(backlogJSON(body).first { $0["id"] as? String == "parent" })
        XCTAssertNil(parent["from"], "an item that came from nowhere reports no parent")
    }

    /// Provenance is descriptive: an item carrying one is judged for pickup on
    /// exactly the terms it would be without it.
    func testProvenanceDoesNotChangeTheReadinessVerdict() async throws {
        try registerProject(
            named: "alpha",
            items: [
                "- [ ] child | Fully groomed | ready | size: S | from:parent → [detail](backlog/child.md)",
                "- [ ] lone | Fully groomed | ready | size: S → [detail](backlog/lone.md)"
            ],
            details: [
                "backlog/child.md": groomedDetail(id: "child"),
                "backlog/lone.md": groomedDetail(id: "lone")
            ]
        )

        let (_, body) = try await harness.get("/v1/backlog?project=alpha")

        let items = backlogJSON(body)
        for id in ["child", "lone"] {
            let entry = try XCTUnwrap(items.first { $0["id"] as? String == id })
            XCTAssertEqual(entry["ready"] as? Bool, true, "\(id): \(entry)")
            XCTAssertNil(entry["notReady"], "\(id)")
        }
    }

    // MARK: - Sequencing

    /// A driver picking the next item to run has to be able to see that a
    /// perfectly groomed item is still waiting on something — and on what. This
    /// used to be prose in an epic preamble, so the only way to find out was to
    /// start the run.
    func testAnItemWaitingOnAnUnfinishedDependencyIsNotReady() async throws {
        try registerProject(
            named: "alpha",
            items: [
                "- [ ] run-output-pr | The prerequisite | ready | size: S → [detail](backlog/run-output-pr.md)",
                "- [ ] dependent | Builds on it | ready | size: S | needs:run-output-pr → [detail](backlog/dependent.md)"
            ],
            details: [
                "backlog/run-output-pr.md": groomedDetail(id: "run-output-pr"),
                "backlog/dependent.md": groomedDetail(id: "dependent")
            ]
        )

        let (status, body) = try await harness.get("/v1/backlog?project=alpha")

        XCTAssertEqual(status, 200)
        let dependent = try XCTUnwrap(backlogJSON(body).first { $0["id"] as? String == "dependent" })
        XCTAssertEqual(dependent["needs"] as? [String], ["run-output-pr"])
        XCTAssertEqual(dependent["ready"] as? Bool, false)
        XCTAssertEqual(dependent["notReady"] as? [String], ["needs run-output-pr — not done (ready)"])
        // The prerequisite itself is runnable, and records no dependency.
        let prerequisite = try XCTUnwrap(backlogJSON(body).first { $0["id"] as? String == "run-output-pr" })
        XCTAssertEqual(prerequisite["ready"] as? Bool, true)
        XCTAssertNil(prerequisite["needs"])
    }

    /// Once the prerequisite is `done`, nothing else has to change for the
    /// dependent to be picked up.
    func testTheDependentBecomesReadyWhenItsDependencyIsDone() async throws {
        try registerProject(
            named: "alpha",
            items: [
                "- [x] run-output-pr | The prerequisite | done",
                "- [ ] dependent | Builds on it | ready | size: S | needs:run-output-pr → [detail](backlog/dependent.md)"
            ],
            details: ["backlog/dependent.md": groomedDetail(id: "dependent")]
        )

        let (_, body) = try await harness.get("/v1/backlog?project=alpha")

        let dependent = try XCTUnwrap(backlogJSON(body).first { $0["id"] as? String == "dependent" })
        XCTAssertEqual(dependent["needs"] as? [String], ["run-output-pr"],
                       "the dependency is still recorded once it is satisfied")
        XCTAssertEqual(dependent["ready"] as? Bool, true)
        XCTAssertNil(dependent["notReady"])
    }

    /// A typo cannot make an item runnable, and the reason distinguishes the two
    /// problems — "not done" would send a groomer hunting for an item that was
    /// never there.
    func testADependencyNamingNothingIsReportedAsSuch() async throws {
        try registerProject(
            named: "alpha",
            items: [
                "- [ ] dependent | Waits on a typo | ready | size: S | needs:no-such-item → [detail](backlog/dependent.md)"
            ],
            details: ["backlog/dependent.md": groomedDetail(id: "dependent")]
        )

        let (_, body) = try await harness.get("/v1/backlog?project=alpha")

        let dependent = try XCTUnwrap(backlogJSON(body).first { $0["id"] as? String == "dependent" })
        XCTAssertEqual(dependent["notReady"] as? [String], ["needs no-such-item — no such item"])
    }

    // MARK: - Helpers

    /// A groomed `backlog/<id>.md` — What, How, Validation and a `verify:`, the
    /// whole of what the gate reads out of a detail file.
    private func groomedDetail(id: String) -> String {
        """
        ---
        id: \(id)
        title: Fully groomed
        size: S
        verify:
          - name: build
            cmd: "swift build"
        ---

        ## What

        The outcome this item delivers.

        ## How

        Touch these files, follow this pattern.

        ## Validation

        - [ ] The observable behaviour that proves it works

        ## Out of Scope

        - Anything else
        """
    }

    private func backlogJSON(_ body: [String: Any]) -> [[String: Any]] {
        body["items"] as? [[String: Any]] ?? []
    }

    /// Builds a real `ProjectSession` over a throwaway directory. The BACKLOG.md
    /// is written first, so the session picks it up on init the way the app does
    /// — and the view model has a file to write back to. Returns the view model
    /// the endpoint mutates.
    @discardableResult
    // MARK: - Landing a done item's branch

    /// The defect this covers: thirty items on 2026-09-18 read `done` with
    /// their work on branches nothing had merged, `approve` refused each one
    /// as "not awaiting approval (status: done)", and no endpoint could land
    /// them. This one merges through the same gate an approval uses.
    func testLandMergesADoneItemsUnmergedBranch() async throws {
        try registerGitProject(named: "gamma", itemID: "item-1", autoMerge: false, verify: "true",
                               line: "- [x] item-1 | Landed by hand | verify: true")
        let root = projectRoot("gamma")
        XCTAssertEqual(gitOut(["rev-list", "--count", "kiteloop/item-1", "^main"], in: root), "1")

        let (status, body) = try await harness.post("/v1/backlog/land", ["project": "gamma", "item": "item-1"])

        XCTAssertEqual(status, 200, "\(body)")
        XCTAssertEqual(body["merged"] as? Bool, true)
        XCTAssertEqual(body["status"] as? String, "done", "landing does not change the item's status")
        XCTAssertEqual(body["verify"] as? [String], ["item verify: true"])
        assertLanded(in: root)
    }

    /// A branch the base already holds is not a failure — the sweep simply
    /// stops naming the item — but it is not a landing either.
    func testLandOnAnAlreadyMergedBranchSaysNothingToLand() async throws {
        try registerGitProject(named: "gamma", itemID: "item-1", autoMerge: false, verify: "true",
                               line: "- [x] item-1 | Landed by hand | verify: true")
        let root = projectRoot("gamma")
        gitOut(["merge", "--ff-only", "kiteloop/item-1"], in: root)

        let (status, body) = try await harness.post("/v1/backlog/land", ["project": "gamma", "item": "item-1"])

        XCTAssertEqual(status, 409)
        XCTAssertEqual(body["merged"] as? Bool, false)
        XCTAssertTrue((body["reason"] as? String ?? "").contains("nothing to land"), "\(body)")
    }

    /// An item at its gate is approve's to land, and the refusal says so.
    func testLandOnAnItemThatIsNotDoneIs409() async throws {
        try registerGitProject(named: "gamma", itemID: "item-1", autoMerge: false, verify: "true")

        let (status, body) = try await harness.post("/v1/backlog/land", ["project": "gamma", "item": "item-1"])

        XCTAssertEqual(status, 409)
        XCTAssertTrue((body["error"] as? String ?? "").contains("not done"), "\(body)")
    }

    /// The gate is the same one approve's merge runs through: a red verify
    /// refuses, the branch is untouched, and the item stays done.
    func testLandRefusesWhenTheVerifyFailsAndLeavesTheBranch() async throws {
        let backlog = try registerGitProject(named: "gamma", itemID: "item-1", autoMerge: false, verify: "false",
                                             line: "- [x] item-1 | Landed by hand | verify: false")
        let root = projectRoot("gamma")

        let (status, body) = try await harness.post("/v1/backlog/land", ["project": "gamma", "item": "item-1"])

        XCTAssertEqual(status, 409)
        XCTAssertEqual(body["merged"] as? Bool, false)
        XCTAssertTrue((body["reason"] as? String ?? "").contains("verify failed"), "\(body)")
        XCTAssertEqual(gitOut(["rev-list", "--count", "kiteloop/item-1", "^main"], in: root), "1")
        XCTAssertEqual(item("item-1", in: backlog)?.status, .done)
    }

    /// A done item whose land was refused still reads Done, so its Notes carry
    /// the refusal: why, and which branch the work is still on.
    func testARefusedLandIsNotedWithItsReasonAndBranch() {
        let note = BacklogViewModel.landRefusedNote(branch: "kiteloop/item-1",
                                                    reason: "merge conflict in: CHANGELOG.md")
        XCTAssertTrue(note.hasPrefix("Land refused: merge conflict in: CHANGELOG.md"))
        XCTAssertTrue(note.contains("kiteloop/item-1"))
        XCTAssertTrue(note.contains("not merged"))
    }

    // MARK: - Merge on approval

    /// The defect this covers: approving used to stamp `done` and merge nothing,
    /// so the backlog reported delivery while the commits sat on a branch `main`
    /// had never seen. Five items reached that state on 2026-08-09.
    func testApproveMergesTheBranchWhenAutoMergeIsOn() async throws {
        let backlog = try registerGitProject(named: "gamma", itemID: "item-1",
                                             autoMerge: true, verify: "true")

        let (status, body) = try await harness.post("/v1/backlog/approve", [
            "project": "gamma", "item": "item-1", "approve": true
        ])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["merged"] as? Bool, true)
        XCTAssertEqual(body["resolved"] as? String, "approved")
        // A headless caller never sees the run log, so the response is where it
        // learns what the merge was actually gated on.
        XCTAssertEqual(body["verify"] as? [String], ["item verify: true"])
        XCTAssertEqual(item("item-1", in: backlog)?.status, .done)
        // The branch is what the claim rests on: main must actually contain it.
        assertLanded(in: projectRoot("gamma"))
    }

    /// A merge that cannot be kept must not leave the item `done`. Reporting
    /// delivery over work that never landed is the whole defect.
    func testApproveDoesNotMarkDoneWhenTheMergeVerifyFails() async throws {
        let backlog = try registerGitProject(named: "delta", itemID: "item-1",
                                             autoMerge: true, verify: "false")

        let (status, body) = try await harness.post("/v1/backlog/approve", [
            "project": "delta", "item": "item-1", "approve": true
        ])

        XCTAssertEqual(status, 409)
        XCTAssertEqual(body["merged"] as? Bool, false)
        XCTAssertEqual(body["resolved"] as? String, "not approved")
        XCTAssertEqual(body["reason"] as? String,
                       "verify failed on merged tree (item verify: false)")
        XCTAssertEqual(item("item-1", in: backlog)?.status, .awaitingApproval,
                       "a failed merge leaves the item at the gate, not Done")
    }

    /// The item's own defect: a sibling merged into main while this item sat at
    /// its gate, so its branch now conflicts. The cache already knows —
    /// refreshed when the item reached the gate and after every merge since —
    /// so approving answers 409 immediately, naming the conflict, without ever
    /// running a merge or the item's verify.
    func testApproveOnAStaleItemIs409BeforeAnyMergeOrVerifyRuns() async throws {
        let backlog = try registerGitProject(named: "kappa", itemID: "item-1",
                                             autoMerge: true, verify: "touch verify-ran.txt")
        let root = projectRoot("kappa")
        // The sibling merge: a conflicting commit lands on main, on the same
        // file the item's branch already committed.
        try "main change".write(
            to: root.appending(path: "work.txt"), atomically: true, encoding: .utf8)
        gitOut(["add", "work.txt"], in: root)
        gitOut(["commit", "-m", "sibling merge"], in: root)
        await backlog.refreshGateFreshness(projectRoot: root)

        let (status, body) = try await harness.post("/v1/backlog/approve", [
            "project": "kappa", "item": "item-1", "approve": true
        ])

        XCTAssertEqual(status, 409)
        XCTAssertEqual(body["merged"] as? Bool, false)
        XCTAssertEqual(body["resolved"] as? String, "not approved")
        XCTAssertEqual(body["reason"] as? String, "merge conflict in: work.txt")
        XCTAssertEqual(item("item-1", in: backlog)?.status, .awaitingApproval)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appending(path: "verify-ran.txt").path(percentEncoded: false)),
            "the verify must never run for an item already known to be stale")
    }

    /// The item's own defect: the cache says conflict, but the branch has
    /// since been rebased onto main (as a gate refresh round does) and now
    /// merges clean — the cached verdict names a tip the branch has left
    /// behind, so the approval must read git rather than the stale cache, and
    /// land on the first call.
    func testApproveMergesOnTheFirstCallWhenACachedConflictPredatesARebase() async throws {
        let backlog = try registerGitProject(named: "nu", itemID: "item-1",
                                             autoMerge: true, verify: "true")
        let root = projectRoot("nu")
        // The sibling merge: a conflicting commit lands on main, on the same
        // file the item's branch already committed.
        try "main change".write(
            to: root.appending(path: "work.txt"), atomically: true, encoding: .utf8)
        gitOut(["add", "work.txt"], in: root)
        gitOut(["commit", "-m", "sibling merge"], in: root)
        await backlog.refreshGateFreshness(projectRoot: root)
        XCTAssertEqual(backlog.freshnessByItemID["item-1"]?.clean, false,
                       "precondition: the cache must start out naming a conflict")

        // The rebase: the branch merges main in, resolving the conflict in
        // main's favour — the same outcome a gate refresh round leaves behind,
        // done by hand here since this test is about the approval endpoint,
        // not the round itself.
        gitOut(["checkout", "kiteloop/item-1"], in: root)
        gitOut(["merge", "-X", "theirs", "--no-ff", "-m", "merge main", "main"], in: root)
        gitOut(["checkout", "main"], in: root)

        let (status, body) = try await harness.post("/v1/backlog/approve", [
            "project": "nu", "item": "item-1", "approve": true
        ])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["merged"] as? Bool, true)
        XCTAssertEqual(body["resolved"] as? String, "approved")
        XCTAssertEqual(item("item-1", in: backlog)?.status, .done)
        assertLanded(in: root)
    }

    /// The other half: a cached conflict still naming the branch's *current*
    /// tip is trusted exactly as before — refused with the paths, and no merge
    /// or verify ever attempted.
    func testApproveStaysRefusedWhenTheCachedConflictStillNamesTheCurrentTip() async throws {
        let backlog = try registerGitProject(named: "xi", itemID: "item-1",
                                             autoMerge: true, verify: "touch verify-ran.txt")
        let root = projectRoot("xi")
        try "main change".write(
            to: root.appending(path: "work.txt"), atomically: true, encoding: .utf8)
        gitOut(["add", "work.txt"], in: root)
        gitOut(["commit", "-m", "sibling merge"], in: root)
        await backlog.refreshGateFreshness(projectRoot: root)

        let (status, body) = try await harness.post("/v1/backlog/approve", [
            "project": "xi", "item": "item-1", "approve": true
        ])

        XCTAssertEqual(status, 409)
        XCTAssertEqual(body["merged"] as? Bool, false)
        XCTAssertEqual(body["reason"] as? String, "merge conflict in: work.txt")
        XCTAssertEqual(item("item-1", in: backlog)?.status, .awaitingApproval)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appending(path: "verify-ran.txt").path(percentEncoded: false)),
            "the branch's tip never moved since the cache was computed — no merge attempt was warranted")
    }

    /// The travel incident of 2026-08-10, at the headless surface: the project's
    /// merge-verify command passes and the item's own `verify:` does not. The
    /// project command used to *replace* the item's, so this merged on a suite
    /// unrelated to the diff. Both run now, and either one failing refuses.
    func testApproveStillRunsTheItemsVerifyWhenTheProjectSetsAMergeCommand() async throws {
        let backlog = try registerGitProject(named: "iota", itemID: "item-1",
                                             autoMerge: true, verify: "false")
        registry.entry(forProject: "iota")?.autopilot.autoMergeVerifyCommand = "true"

        let (status, body) = try await harness.post("/v1/backlog/approve", [
            "project": "iota", "item": "item-1", "approve": true
        ])

        XCTAssertEqual(status, 409)
        XCTAssertEqual(body["merged"] as? Bool, false)
        XCTAssertEqual(body["reason"] as? String,
                       "verify failed on merged tree (item verify: false)",
                       "the refusal must name which of the two commands failed")
        XCTAssertEqual(item("item-1", in: backlog)?.status, .awaitingApproval)
        // And main did not move: the branch is still unmerged.
        XCTAssertEqual(gitOut(["rev-list", "--count", "refs/heads/kiteloop/item-1", "--not", "HEAD"],
                              in: projectRoot("iota")), "1")
    }

    /// The 409 names the reason, but the refusal rolled the merged tree back —
    /// so a headless driver reading only `reason` cannot see what failed. The
    /// output travels with it.
    func testApproveCarriesTheFailingVerifysOutput() async throws {
        try registerGitProject(named: "theta", itemID: "item-1", autoMerge: true,
                               verify: "echo BOOM-not-compiling && false")

        let (status, body) = try await harness.post("/v1/backlog/approve", [
            "project": "theta", "item": "item-1", "approve": true
        ])

        XCTAssertEqual(status, 409)
        XCTAssertTrue((body["verifyOutput"] as? String ?? "").contains("BOOM-not-compiling"),
                      "no evidence in the response: \(body)")
    }

    /// A refusal with nothing to show — the verify never ran — must not carry an
    /// empty field a driver would print as a blank failure.
    func testARefusalWithNoOutputOmitsTheField() async throws {
        let backlog = try registerGitProject(named: "iota", itemID: "item-1", autoMerge: true, verify: "true")
        // A refusal that never runs the verify: the merge itself conflicts.
        // (A merely dirty checkout no longer refuses — merge and verify run in
        // a scratch worktree since the gate stopped dirtying the checkout.)
        let root = projectRoot("iota")
        try "main change".write(
            to: root.appending(path: "work.txt"), atomically: true, encoding: .utf8)
        gitOut(["add", "work.txt"], in: root)
        gitOut(["commit", "-m", "sibling merge"], in: root)
        await backlog.refreshGateFreshness(projectRoot: root)

        let (status, body) = try await harness.post("/v1/backlog/approve", [
            "project": "iota", "item": "item-1", "approve": true
        ])

        XCTAssertEqual(status, 409)
        XCTAssertTrue((body["reason"] as? String ?? "").contains("merge conflict"), "\(body)")
        XCTAssertNil(body["verifyOutput"])
    }

    /// Auto-merge off is a legitimate configuration — but the response must say
    /// the branch is still the only place the work exists.
    func testApproveWithAutoMergeOffSaysTheBranchAwaitsAHumanMerge() async throws {
        let backlog = try registerGitProject(named: "epsilon", itemID: "item-1",
                                             autoMerge: false, verify: "true")

        let (status, body) = try await harness.post("/v1/backlog/approve", [
            "project": "epsilon", "item": "item-1", "approve": true
        ])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["merged"] as? Bool, false)
        XCTAssertEqual(body["resolved"] as? String, "approved")
        XCTAssertEqual(item("item-1", in: backlog)?.status, .done)
        XCTAssertTrue((body["mergeSkipped"] as? String ?? "").contains("waiting for a human merge"))
        XCTAssertEqual(gitOut(["rev-list", "--count", "refs/heads/kiteloop/item-1", "--not", "HEAD"],
                              in: projectRoot("epsilon")), "1", "the branch is deliberately not merged")
    }

    /// An item whose work is already on main — merged by hand, or one that never
    /// had a branch — resolves without claiming a merge it did not perform.
    func testApproveWithNothingToMergeSaysSoRatherThanClaimingAMerge() async throws {
        let backlog = try registerProject(named: "zeta", items: [
            "- [ ] item-1 | Needs sign-off | awaiting-approval"
        ])

        let (status, body) = try await harness.post("/v1/backlog/approve", [
            "project": "zeta", "item": "item-1", "approve": true
        ])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["merged"] as? Bool, false)
        XCTAssertEqual(body["resolved"] as? String, "approved")
        XCTAssertEqual(item("item-1", in: backlog)?.status, .done)
        XCTAssertTrue((body["mergeSkipped"] as? String ?? "").contains("nothing to merge"))
    }

    /// Rejecting is untouched by any of the above: no merge is attempted and the
    /// item goes back to Ready with the reason recorded.
    func testRejectNeverMergesEvenWithAutoMergeOn() async throws {
        let backlog = try registerGitProject(named: "eta", itemID: "item-1",
                                             autoMerge: true, verify: "true")

        let (status, body) = try await harness.post("/v1/backlog/approve", [
            "project": "eta", "item": "item-1", "approve": false, "reason": "not yet"
        ])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["resolved"] as? String, "rejected")
        XCTAssertNil(body["merged"])
        XCTAssertEqual(item("item-1", in: backlog)?.status, .ready)
        XCTAssertEqual(gitOut(["rev-list", "--count", "refs/heads/kiteloop/item-1", "--not", "HEAD"],
                              in: projectRoot("eta")), "1", "a rejected item's branch stays unmerged")
    }

    // MARK: - Git-backed fixture

    private func projectRoot(_ name: String) -> URL {
        tempDir.appendingPathComponent(name, isDirectory: true)
    }

    /// A project whose root is a real repository with the item's branch carrying
    /// one commit `main` cannot reach — the state an item at the gate is in.
    @discardableResult
    private func registerGitProject(
        named name: String,
        itemID: String,
        autoMerge: Bool,
        verify: String,
        line: String? = nil
    ) throws -> BacklogViewModel {
        let backlog = try registerProject(named: name, items: [
            line ?? "- [ ] \(itemID) | Needs sign-off | verify: \(verify) | awaiting-approval"
        ])
        let root = projectRoot(name)
        gitOut(["init", "-b", "main"], in: root)
        gitOut(["config", "user.email", "test@test.com"], in: root)
        gitOut(["config", "user.name", "Test"], in: root)
        gitOut(["add", "."], in: root)
        gitOut(["commit", "-m", "init"], in: root)
        // One commit on the item's branch, off the checked-out main.
        gitOut(["checkout", "-b", "kiteloop/\(itemID)"], in: root)
        try "work\n".write(to: root.appending(path: "work.txt"), atomically: true, encoding: .utf8)
        gitOut(["add", "work.txt"], in: root)
        gitOut(["commit", "-m", "work"], in: root)
        gitOut(["checkout", "main"], in: root)
        registry.entry(forProject: name)?.autopilot.approvalGate = autoMerge ? .land : .propose
        return backlog
    }

    /// A landed merge leaves the work in main and the branch removed — the
    /// ref was all that was left of it once every commit on it was in main.
    private func assertLanded(in root: URL, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(gitOut(["ls-tree", "--name-only", "main", "work.txt"], in: root), "work.txt",
                       "main must actually contain the branch's work", file: file, line: line)
        XCTAssertEqual(gitOut(["rev-parse", "--verify", "--quiet", "refs/heads/kiteloop/item-1"], in: root), "",
                       "the branch is removed once it landed", file: file, line: line)
    }

    @discardableResult
    private func gitOut(_ args: [String], in directory: URL) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: - Freshness

    /// The other half of the same defect, at `GET /v1/backlog`: a stale item at
    /// the gate carries its verdict in the listing too, so the board reads
    /// "stale" before anyone tries to approve it.
    func testBacklogListingCarriesFreshnessForAStaleGateItem() async throws {
        let backlog = try registerGitProject(named: "lambda", itemID: "item-1",
                                             autoMerge: true, verify: "true")
        let root = projectRoot("lambda")
        try "main change".write(
            to: root.appending(path: "work.txt"), atomically: true, encoding: .utf8)
        gitOut(["add", "work.txt"], in: root)
        gitOut(["commit", "-m", "sibling merge"], in: root)
        await backlog.refreshGateFreshness(projectRoot: root)

        let (status, body) = try await harness.get("/v1/backlog?project=lambda")

        XCTAssertEqual(status, 200)
        let entry = try XCTUnwrap(backlogJSON(body).first { $0["id"] as? String == "item-1" })
        let freshness = try XCTUnwrap(entry["freshness"] as? [String: Any])
        XCTAssertEqual(freshness["clean"] as? Bool, false)
        XCTAssertEqual(freshness["conflicts"] as? [String], ["work.txt"])
        XCTAssertNotNil(freshness["checkedAt"] as? String)
    }

    /// A branch that still merges cleanly reads clean, not merely absent.
    func testBacklogListingCarriesCleanFreshnessForAGateItemThatStillMerges() async throws {
        let backlog = try registerGitProject(named: "mu", itemID: "item-1",
                                             autoMerge: true, verify: "true")
        await backlog.refreshGateFreshness(projectRoot: projectRoot("mu"))

        let (_, body) = try await harness.get("/v1/backlog?project=mu")

        let entry = try XCTUnwrap(backlogJSON(body).first { $0["id"] as? String == "item-1" })
        let freshness = try XCTUnwrap(entry["freshness"] as? [String: Any])
        XCTAssertEqual(freshness["clean"] as? Bool, true)
        XCTAssertEqual(freshness["conflicts"] as? [String], [])
    }

    // MARK: - Move

    func testMoveToTopReordersWithinTheEpic() async throws {
        let vm = try registerProject(named: "mover", items: [
            "- [ ] first | First | ready",
            "- [ ] second | Second | ready",
        ])
        let (status, body) = try await harness.post("/v1/backlog/move", [
            "project": "mover", "item": "second",
        ])
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["moved"] as? Bool, true)
        XCTAssertEqual(vm.backlogFile?.sections.first?.items.map(\.id), ["second", "first"])
    }

    func testMoveBeforeANamedItem() async throws {
        let vm = try registerProject(named: "mover2", items: [
            "- [ ] one | One | ready",
            "- [ ] two | Two | ready",
            "- [ ] three | Three | ready",
        ])
        let (status, _) = try await harness.post("/v1/backlog/move", [
            "project": "mover2", "item": "one", "before": "three",
        ])
        XCTAssertEqual(status, 200)
        XCTAssertEqual(vm.backlogFile?.sections.first?.items.map(\.id), ["two", "one", "three"])
    }

    func testMovingADoneItemAnswers409() async throws {
        _ = try registerProject(named: "mover3", items: [
            "- [x] shipped | Shipped | done",
            "- [ ] open | Open | ready",
        ])
        let (status, _) = try await harness.post("/v1/backlog/move", [
            "project": "mover3", "item": "shipped",
        ])
        XCTAssertEqual(status, 409)
    }

    func testMovingBeforeAnUnknownItemAnswers404() async throws {
        _ = try registerProject(named: "mover4", items: ["- [ ] only | Only | ready"])
        let (status, _) = try await harness.post("/v1/backlog/move", [
            "project": "mover4", "item": "only", "before": "ghost",
        ])
        XCTAssertEqual(status, 404)
    }

    // MARK: - Lane

    /// A `Now` epic is carried across to `lane:now` on load, so these projects
    /// file their items under an area epic — the lane is then only what the
    /// line says.
    func testBacklogListingCarriesEachItemsLane() async throws {
        _ = try registerProject(named: "laner", items: [
            "- [ ] marked | Marked | size:S | lane:now | ready",
            "- [ ] plain | Plain | size:S | ready",
        ], epic: "Platform")

        let (status, body) = try await harness.get("/v1/backlog?project=laner")

        XCTAssertEqual(status, 200)
        let lanes = Dictionary(uniqueKeysWithValues: backlogJSON(body).map {
            ($0["id"] as? String ?? "", $0["lane"] as? String)
        })
        XCTAssertEqual(lanes, ["marked": "now", "plain": "later"])
    }

    func testLaneNowMarksTheItemWithoutMovingIt() async throws {
        let vm = try registerProject(named: "laner2", items: [
            "- [ ] first | First | size:S | ready",
            "- [ ] second | Second | size:S | ready",
        ], epic: "Platform")

        let (status, body) = try await harness.post("/v1/backlog/lane", [
            "project": "laner2", "item": "second", "lane": "now",
        ])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["was"] as? String, "later")
        XCTAssertEqual(body["lane"] as? String, "now")
        XCTAssertEqual(body["changed"] as? Bool, true)
        XCTAssertEqual(vm.backlogFile?.sections.first?.items.map(\.id), ["first", "second"])
        let onDisk = try String(contentsOf: tempDir.appending(path: "laner2/BACKLOG.md"), encoding: .utf8)
        XCTAssertTrue(onDisk.contains("- [ ] second | Second | size:S | lane:now | ready"), onDisk)
        XCTAssertTrue(onDisk.contains("- [ ] first | First | size:S | ready"), onDisk)
    }

    func testLaneLaterClearsTheMark() async throws {
        let vm = try registerProject(named: "laner3", items: [
            "- [ ] promoted | Promoted | size:S | lane:now | ready",
        ], epic: "Platform")

        let (status, body) = try await harness.post("/v1/backlog/lane", [
            "project": "laner3", "item": "promoted", "lane": "later",
        ])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["was"] as? String, "now")
        XCTAssertEqual(vm.backlogFile?.sections.first?.items.first?.lane, .later)
        let onDisk = try String(contentsOf: tempDir.appending(path: "laner3/BACKLOG.md"), encoding: .utf8)
        XCTAssertFalse(onDisk.contains("lane:"), onDisk)
    }

    func testLaneOnADoneItemAnswers409() async throws {
        _ = try registerProject(named: "laner4", items: [
            "- [x] shipped | Shipped | done",
        ], epic: "Platform")
        let (status, _) = try await harness.post("/v1/backlog/lane", [
            "project": "laner4", "item": "shipped", "lane": "now",
        ])
        XCTAssertEqual(status, 409)
    }

    func testAnUnknownLaneAnswers400() async throws {
        let vm = try registerProject(named: "laner5", items: [
            "- [ ] open | Open | ready",
        ], epic: "Platform")
        let (status, _) = try await harness.post("/v1/backlog/lane", [
            "project": "laner5", "item": "open", "lane": "soon",
        ])
        XCTAssertEqual(status, 400)
        XCTAssertEqual(vm.backlogFile?.sections.first?.items.first?.lane, .later)
    }

    private func registerProject(
        named name: String,
        items: [String],
        epic: String = "Now",
        details: [String: String] = [:]
    ) throws -> BacklogViewModel {
        let root = tempDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rootURL = URL(fileURLWithPath: root.path(percentEncoded: false), isDirectory: false)
        let project = KiteloopProject(rootURL: rootURL)
        try project.ensureDirectoryExists()

        try "# \(name) Backlog\n\n## \(epic)\n\n\(items.joined(separator: "\n"))\n"
            .write(to: root.appending(path: "BACKLOG.md"), atomically: true, encoding: .utf8)
        for (path, contents) in details {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }

        let eventBus = EventBus(eventsURL: project.eventsURL)
        let orchestrator = Orchestrator(
            runtime: MockAgentRuntime(),
            eventBus: eventBus,
            subscriptionEngine: SubscriptionEngine(eventBus: eventBus),
            memoryManager: MemoryManager(project: project)
        )
        // Before the session: `BacklogViewModel` takes the inbox at construction,
        // and the gate's own notice is what resolves when the gate resolves.
        orchestrator.configureNotifications(notificationsURL: project.notificationsURL)
        let session = ProjectSession(
            project: project,
            projectURL: rootURL,
            orchestrator: orchestrator,
            sessionStore: SessionStore(projectDir: rootURL),
            knowledgeStore: AgentKnowledgeStore(baseURL: project.knowledgeURL),
            knowledgeIndex: KnowledgeIndex(baseURL: project.knowledgeURL),
            context: makeContext()
        )
        registry.register(session: session, autopilot: BacklogAutopilot())
        return session.backlogViewModel
    }

    /// The project's inbox, as the session wired it.
    private func inbox(project name: String) throws -> NotificationStore {
        guard let store = registry.entry(forProject: name)?.session.orchestrator.notificationStore else {
            throw XCTSkip("no inbox registered for \(name)")
        }
        return store
    }

    /// Files the summons a run raises when its item reaches the gate, and waits
    /// for it to land — `notify` posts to the store off the caller's turn.
    private func postApprovalNotice(project name: String, itemID: String) async throws {
        guard let session = registry.entry(forProject: name)?.session else {
            throw XCTSkip("no session registered for \(name)")
        }
        session.orchestrator.notify(
            agentID: "worker", type: .approval,
            title: "Approval needed in \(name)", body: "\(itemID) — needs sign-off",
            itemID: itemID, projectPath: session.project.rootURL.path(percentEncoded: false))
        let store = try inbox(project: name)
        try await eventually("the summons to reach the inbox") {
            await store.pendingCount() == 1
        }
    }

    private func item(_ id: String, in backlog: BacklogViewModel) -> BacklogItem? {
        backlog.backlogFile?.sections.flatMap(\.items).first { $0.id == id }
    }

    private func backlogContents(project: String) throws -> String {
        try String(contentsOf: tempDir.appending(path: "\(project)/BACKLOG.md"), encoding: .utf8)
    }

    /// All stores are pointed at the temp directory so the tests never read or
    /// write the developer's real global config.
    private func makeContext() -> ProjectSessionContext {
        ProjectSessionContext(
            runtimeFactory: { MockAgentRuntime() },
            agentCatalogStore: AgentCatalogStore(storageURL: tempDir.appendingPathComponent("catalog.json")),
            packageResolver: nil,
            globalConfigStore: GlobalConfigStore(storageURL: tempDir.appendingPathComponent("global.json")),
            orgManifestLoader: OrgManifestLoader(),
            repoCloneService: RepoCloneService()
        )
    }
}
