import XCTest

/// QA flow for `approving-a-qa-item-shows-no-storyboard`: an item waiting at
/// the approval gate whose QA run kept a storyboard gets a Storyboard button
/// beside Approve, opening every step — caption above picture — in a sheet;
/// an item with no storyboard gets no button.
///
/// The `storyboardGate` scenario has the app write both items to the Quick
/// Start project's BACKLOG.md and the storyboard to `.kiteloop/storyboards/` in
/// its throwaway home as Quick Start opens — this process is sandboxed out of
/// that home — so the flow reaches the gate without running a QA flow inside a
/// QA flow.
final class ApprovingAQAItemShowsNoStoryboard: QAStoryboardTestCase {
    private let captions = ["The Autopilot view opens", "The row shows a branch",
                            "FAILED: The button is blue — got grey"]
    private var storyboardButtons: XCUIElementQuery {
        app.buttons.matching(identifier: "autopilot-gate-storyboard-button")
    }
    private var sheet: XCUIElement { app.sheets.firstMatch }

    override func setUp() async throws {
        try await super.setUp()
        app.launchEnvironment["UI_TEST_SCENARIO"] = "storyboardGate"
    }

    func testTheGateShowsWhatQASaw() {
        step("Kiteloop opens the Quick Start project, reading only its throwaway home") {
            app.launch()
            XCTAssertTrue(app.buttons["quick-start-button"].waitForExistence(timeout: 15))
            assertNoPrivacyDialog()
            assertNoRecentProjects()
            app.buttons["quick-start-button"].click()
            let input = app.descendants(matching: .any).matching(identifier: "input-text-field").firstMatch
            XCTAssertTrue(input.waitForExistence(timeout: 25), "the chat input should appear once the project opens")
        }
        step("The Autopilot view shows both items Waiting for you, each with its branch") {
            app.descendants(matching: .any)["autopilot-sidebar-entry"].firstMatch.click()
            // The Waiting on you drawer opens on its own with two approvals
            // pending and squeezes the Autopilot until the row's titles and
            // buttons truncate.
            let drawerClose = app.buttons
                .matching(NSPredicate(format: "identifier == 'waiting-drawer' AND label == 'Close'")).firstMatch
            if drawerClose.waitForExistence(timeout: 3) { drawerClose.click() }
            let waiting = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label BEGINSWITH 'Waiting for you' OR value BEGINSWITH 'Waiting for you'"))
            XCTAssertTrue(waiting.firstMatch.waitForExistence(timeout: 10),
                          "the approval box should show")
            for branch in ["kiteloop/qa-demo", "kiteloop/plain-item"] {
                XCTAssertTrue(app.staticTexts[branch].firstMatch.waitForExistence(timeout: 5),
                              "the gate should name the branch \(branch)")
            }
        }
        step("The Demo QA change row reads Reject, Storyboard, Approve") {
            XCTAssertTrue(storyboardButtons.firstMatch.waitForExistence(timeout: 10),
                          "the item with a kept storyboard should offer Storyboard")
            let storyboard = storyboardButtons.firstMatch.frame
            let branch = app.staticTexts["kiteloop/qa-demo"].firstMatch.frame
            XCTAssertEqual(storyboard.midY, branch.midY, accuracy: 20, "Storyboard should sit on the Demo QA change row")
            let reject = button("Reject", inRowAt: storyboard.midY).frame
            let approve = button("Approve", inRowAt: storyboard.midY).frame
            XCTAssertLessThan(reject.maxX, storyboard.minX, "Reject should come before Storyboard")
            XCTAssertLessThan(storyboard.maxX, approve.minX, "Storyboard should come before Approve")
        }
        step("The Plain change row shows Reject and Approve only") {
            XCTAssertEqual(storyboardButtons.count, 1, "only the item with a storyboard should offer one")
            let row = app.staticTexts["kiteloop/plain-item"].firstMatch.frame.midY
            XCTAssertTrue(button("Approve", inRowAt: row).exists, "Plain change should still offer Approve")
            XCTAssertTrue(button("Reject", inRowAt: row).exists, "Plain change should still offer Reject")
        }
        step("Storyboard opens a sheet titled Demo QA change, step 1 then step 2, each caption above its picture") {
            storyboardButtons.firstMatch.click()
            XCTAssertTrue(sheet.waitForExistence(timeout: 10), "a sheet should open")
            XCTAssertTrue(sheet.staticTexts["Demo QA change"].firstMatch.waitForExistence(timeout: 5),
                          "the sheet should be titled with the item")
            let first = caption(0), second = caption(1)
            XCTAssertTrue(first.waitForExistence(timeout: 10), "step 1's caption should show")
            XCTAssertTrue(second.exists, "step 2's caption should show")
            XCTAssertLessThan(first.frame.maxY, second.frame.minY, "step 1 should come before step 2")
            // SwiftUI exposes no element for AsyncImage's picture, so its place
            // is read off the captions: a screenshot fills the space between a
            // caption and the next, and the photograph shows it.
            XCTAssertGreaterThan(second.frame.minY - first.frame.maxY, 200,
                                 "step 1's picture should sit between its caption and step 2's")
            XCTAssertFalse(sheet.buttons["Approve"].exists, "the sheet should not offer Approve")
            XCTAssertFalse(sheet.buttons["Reject"].exists, "the sheet should not offer Reject")
        }
        step("At the bottom of the sheet, step 3's FAILED caption is marked, with its picture below and nothing after") {
            let third = caption(2)
            XCTAssertTrue(third.waitForExistence(timeout: 5), "step 3's caption should be in the sheet")
            scrollToBottom(sheet.scrollViews.firstMatch, showing: third)
            XCTAssertTrue(third.isHittable, "step 3's caption should be on screen at the bottom of the sheet")
            XCTAssertGreaterThan(third.frame.minY - caption(1).frame.maxY, 200,
                                 "step 3 should come after step 2 and its picture")
            let captions = sheet.descendants(matching: .any).matching(identifier: "qa-storyboard-step-caption")
            XCTAssertEqual(captions.count, 3, "the sheet should hold exactly three steps")
        }
        step("Done closes the sheet; both items are still Waiting for you, Storyboard still on Demo QA change") {
            sheet.buttons["qa-storyboard-done-button"].click()
            XCTAssertTrue(waitUntilGone(sheet), "the sheet should close")
            XCTAssertTrue(app.staticTexts["kiteloop/qa-demo"].firstMatch.exists)
            XCTAssertTrue(app.staticTexts["kiteloop/plain-item"].firstMatch.exists)
            XCTAssertEqual(storyboardButtons.count, 1, "Storyboard should still be on Demo QA change only")
        }
    }

    private func caption(_ index: Int) -> XCUIElement {
        sheet.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'qa-storyboard-step-caption' AND (label CONTAINS %@ OR value CONTAINS %@)",
                                  captions[index], captions[index]))
            .firstMatch
    }

    /// The button titled `title` whose row is at `midY` — every gated row has
    /// its own Reject and Approve.
    private func button(_ title: String, inRowAt midY: CGFloat) -> XCUIElement {
        let match = app.buttons.matching(NSPredicate(format: "label == %@", title)).allElementsBoundByIndex
            .first { abs($0.frame.midY - midY) < 20 }
        return match ?? app.buttons["no \(title) on this row"]
    }

    /// Scrolls `scroller` to its end. Which sign of delta scrolls down is
    /// not something XCUITest promises, so it tries the other one when
    /// `element`, near the end, is still off screen.
    private func scrollToBottom(_ scroller: XCUIElement, showing element: XCUIElement) {
        scroller.scroll(byDeltaX: 0, deltaY: -5000)
        if !element.isHittable { scroller.scroll(byDeltaX: 0, deltaY: 10000) }
    }

    private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }
}
