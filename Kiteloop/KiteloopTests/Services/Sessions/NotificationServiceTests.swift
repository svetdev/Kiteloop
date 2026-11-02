import AppKit
import XCTest
import KiteloopCore
@testable import Kiteloop

@MainActor
final class NotificationServiceTests: XCTestCase {

    // MARK: - Routing

    func testActionableTypesReachTheSystemChannel() {
        XCTAssertTrue(NotificationService.usesSystemChannel(.approval))
        XCTAssertTrue(NotificationService.usesSystemChannel(.question))
    }

    func testAmbientTypesStayInTheInbox() {
        XCTAssertFalse(NotificationService.usesSystemChannel(.complete))
        XCTAssertFalse(NotificationService.usesSystemChannel(.event))
        XCTAssertFalse(NotificationService.usesSystemChannel(.error))
    }

    // MARK: - Gate identity

    func testGateKeyIgnoresItemIdentityAndTimestamp() {
        let first = NotificationItem(
            agentID: "builder", type: .approval,
            title: "Approval needed in kiteloop", body: "add-banner — Add the banner"
        )
        let second = NotificationItem(
            agentID: "builder", type: .approval,
            title: "Approval needed in kiteloop", body: "add-banner — Add the banner"
        )

        XCTAssertNotEqual(first.id, second.id, "each emission is a distinct item")
        XCTAssertEqual(
            NotificationService.gateKey(for: first),
            NotificationService.gateKey(for: second),
            "the same gate re-emitted must key the same"
        )
    }

    func testGateKeyDistinguishesDifferentGates() {
        let approval = NotificationItem(
            agentID: "builder", type: .approval,
            title: "Approval needed in kiteloop", body: "add-banner — Add the banner"
        )
        let otherItem = NotificationItem(
            agentID: "builder", type: .approval,
            title: "Approval needed in kiteloop", body: "fix-badge — Fix the badge"
        )
        let otherProject = NotificationItem(
            agentID: "builder", type: .approval,
            title: "Approval needed in sidecar", body: "add-banner — Add the banner"
        )
        let question = NotificationItem(
            agentID: "builder", type: .question,
            title: "Approval needed in kiteloop", body: "add-banner — Add the banner"
        )

        let keys = Set([approval, otherItem, otherProject, question].map(NotificationService.gateKey(for:)))
        XCTAssertEqual(keys.count, 4)
    }

    // MARK: - One banner per gate

    func testLedgerDeliversAGateOnceOnly() {
        var ledger = NotificationService.GateLedger()
        XCTAssertTrue(ledger.shouldDeliver("approval|kiteloop|add-banner"))
        XCTAssertFalse(ledger.shouldDeliver("approval|kiteloop|add-banner"))
        XCTAssertFalse(ledger.shouldDeliver("approval|kiteloop|add-banner"))
    }

    func testLedgerDeliversDistinctGates() {
        var ledger = NotificationService.GateLedger()
        XCTAssertTrue(ledger.shouldDeliver("approval|kiteloop|add-banner"))
        XCTAssertTrue(ledger.shouldDeliver("approval|kiteloop|fix-badge"))
        XCTAssertTrue(ledger.shouldDeliver("question|builder|which one?"))
    }

    func testResetLetsAGateBannerAgain() {
        var ledger = NotificationService.GateLedger()
        XCTAssertTrue(ledger.shouldDeliver("approval|kiteloop|add-banner"))
        ledger.reset()
        XCTAssertTrue(ledger.shouldDeliver("approval|kiteloop|add-banner"))
    }

    // MARK: - Notify User hooks

    func testHookBannerKeepsTheTitleTheUserWrote() {
        let banner = NotificationService.hookBanner(ruleID: "rule-1", title: "Build broken", body: "main is red")

        XCTAssertEqual(banner.title, "Build broken")
        XCTAssertFalse(banner.title.contains("finished"))
        XCTAssertEqual(banner.body, "main is red")
    }

    func testHookBannerTruncatesTheBody() {
        let banner = NotificationService.hookBanner(ruleID: "rule-1", title: "Build broken",
                                                    body: String(repeating: "x", count: 300))

        XCTAssertEqual(banner.body.count, 140)
    }

    func testHookBannerKeysOnTheRule() {
        let first = NotificationService.hookBanner(ruleID: "rule-1", title: "Build broken", body: "main is red")
        let again = NotificationService.hookBanner(ruleID: "rule-1", title: "Build broken", body: "still red")
        let other = NotificationService.hookBanner(ruleID: "rule-2", title: "Build broken", body: "main is red")

        XCTAssertEqual(first.key, again.key, "one rule firing twice replaces its own banner")
        XCTAssertNotEqual(first.key, other.key, "two rules are two notifications")
    }

    func testAHookIsDeliveredWhileTheAppIsFrontmost() {
        let service = NotificationService.shared
        let wasActive = NSApplication.shared.isActive
        service.clearBadge()

        service.notifyHookFired(ruleID: "rule-frontmost", title: "Build broken", body: "main is red")

        XCTAssertEqual(service.pendingCount, 1,
                       "a hook is raised whether or not the app is frontmost (isActive=\(wasActive))")

        service.notifyHookFired(ruleID: "rule-frontmost", title: "Build broken", body: "still red")
        XCTAssertEqual(service.pendingCount, 2, "no once-per-gate ledger stands between a hook and its banner")
    }

    // MARK: - Gates still open as the app is left

    private func row(_ gate: WaitingOnYou.Row.Gate,
                     project: String = "kiteloop",
                     title: String = "Add the banner",
                     detail: String = "which one did you mean?") -> WaitingOnYou.Row {
        WaitingOnYou.Row(
            id: "\(project)#\(title)", projectID: project, projectName: project,
            projectPath: "/tmp/\(project)", gate: gate, title: title,
            detail: detail, since: nil
        )
    }

    func testLeavingGateKeyIsStableAndSeparatesKinds() {
        let approval = row(.approval(itemID: "add-banner"))
        let question = row(.question(agentID: "builder"))

        XCTAssertEqual(NotificationService.gateKey(for: approval),
                       NotificationService.gateKey(for: row(.approval(itemID: "add-banner"))),
                       "the same gate read twice must key the same")
        XCTAssertNotNil(NotificationService.gateKey(for: approval))
        XCTAssertNotNil(NotificationService.gateKey(for: question))
        XCTAssertNotEqual(NotificationService.gateKey(for: approval),
                          NotificationService.gateKey(for: question))
    }

    func testTwoQuestionsFromOneAgentAreTwoGates() {
        let first = row(.question(agentID: "builder"), title: "Ada needs input",
                        detail: "which one did you mean?")
        let second = row(.question(agentID: "builder"), title: "Ada needs input",
                         detail: "shall I delete the branch?")

        XCTAssertNotEqual(NotificationService.gateKey(for: first),
                          NotificationService.gateKey(for: second),
                          "the headline is the same every time; the question is what tells them apart")
    }

    func testAStaleFlagIsNotAGateToBanner() {
        XCTAssertNil(NotificationService.gateKey(for: row(.stale(itemID: "add-banner"))),
                     "a stale flag is nothing to approve or answer")
    }

    func testSameTitleInTwoProjectsAreTwoGates() {
        let here = row(.approval(itemID: "add-banner"), project: "kiteloop")
        let there = row(.approval(itemID: "add-banner"), project: "sidecar")

        XCTAssertNotEqual(NotificationService.gateKey(for: here),
                          NotificationService.gateKey(for: there))
    }

    func testLeavingBannersEachGateOnceAcrossAReturn() {
        let service = NotificationService.shared
        let rows = [row(.approval(itemID: "add-banner")), row(.question(agentID: "builder"), title: "Ada needs input")]
        let before = service.pendingCount

        service.notifyOpenGatesOnLeaving(rows)
        XCTAssertEqual(service.pendingCount, before + 2, "two distinct gates, two banners")

        service.notifyOpenGatesOnLeaving(rows)
        XCTAssertEqual(service.pendingCount, before + 2, "the same gates handed over again deliver nothing")

        // The operator came back and the badge was cleared — which resets
        // `deliveredGates`, and must not reset this path's ledger.
        service.clearBadge()
        service.notifyOpenGatesOnLeaving(rows)
        XCTAssertEqual(service.pendingCount, 0, "a gate already bannered is not bannered again after a return")

        service.notifyOpenGatesOnLeaving([row(.approval(itemID: "fix-badge"), title: "Fix the badge")])
        XCTAssertEqual(service.pendingCount, 1, "a gate not seen before still banners")
    }

    func testLeavingBannersASecondQuestionFromTheSameAgent() {
        let service = NotificationService.shared
        let project = "kiteloop-two-questions"
        let first = row(.question(agentID: "builder"), project: project,
                        title: "Ada needs input", detail: "which one did you mean?")
        let second = row(.question(agentID: "builder"), project: project,
                         title: "Ada needs input", detail: "shall I delete the branch?")
        let before = service.pendingCount

        service.notifyOpenGatesOnLeaving([first])
        XCTAssertEqual(service.pendingCount, before + 1)

        service.notifyOpenGatesOnLeaving([second])
        XCTAssertEqual(service.pendingCount, before + 2,
                       "a different question from the same agent is a gate of its own")

        service.notifyOpenGatesOnLeaving([first, second])
        XCTAssertEqual(service.pendingCount, before + 2, "neither question banners twice")
    }

    // MARK: - Where a clicked banner goes

    private func roundTrip(_ destination: BannerDestination?) -> BannerDestination? {
        let content = NotificationService.bannerContent(
            title: "t", body: "b", badge: 1, destination: destination)
        return BannerDestination(userInfo: content.userInfo)
    }

    func testAnApprovalBannerParsesBackToItsProjectAndItem() {
        let written = BannerDestination(kind: .approval, project: "/tmp/kiteloop", id: "add-banner")
        let read = roundTrip(written)

        XCTAssertEqual(read, written)
        XCTAssertEqual(read?.kind, .approval)
        XCTAssertEqual(read?.project, "/tmp/kiteloop")
        XCTAssertEqual(read?.id, "add-banner")
        XCTAssertEqual(read?.gate, .approval(itemID: "add-banner"))
    }

    func testAQuestionBannerParsesBackToItsProjectAndAgent() {
        let written = BannerDestination(kind: .question, project: "/tmp/kiteloop", id: "builder")
        let read = roundTrip(written)

        XCTAssertEqual(read, written)
        XCTAssertEqual(read?.kind, .question)
        XCTAssertEqual(read?.project, "/tmp/kiteloop")
        XCTAssertEqual(read?.id, "builder")
        XCTAssertEqual(read?.gate, .question(agentID: "builder"))
    }

    func testABannerBuiltWithoutADestinationParsesToNone() {
        XCTAssertNil(roundTrip(nil))
    }

    func testAnInboxNoticeCarriesItsProjectAndWhatIsWaiting() {
        let approval = NotificationItem(
            agentID: "worker", type: .approval, title: "Approval needed in kiteloop",
            body: "add-banner — Add the banner", itemID: "add-banner", projectPath: "/tmp/kiteloop")
        let question = NotificationItem(
            agentID: "builder", type: .question, title: "Builder needs input",
            body: "which one?", projectPath: "/tmp/kiteloop")

        XCTAssertEqual(BannerDestination.forNotice(approval),
                       BannerDestination(kind: .approval, project: "/tmp/kiteloop", id: "add-banner"))
        XCTAssertEqual(BannerDestination.forNotice(question),
                       BannerDestination(kind: .question, project: "/tmp/kiteloop", id: "builder"))
    }

    func testANoticeThatNamedNoProjectHasNoDestination() {
        let question = NotificationItem(
            agentID: "builder", type: .question, title: "Builder needs input", body: "which one?")
        XCTAssertNil(BannerDestination.forNotice(question))
    }

    // MARK: - The finished banner

    func testTheFinishedBannerNamesTheAgentAndTheProject() {
        let banner = NotificationService.finishedBanner(
            agentName: "Developer", projectName: "kiteloop", reply: "Done.")
        XCTAssertTrue(banner.title.contains("Developer"))
        XCTAssertTrue(banner.title.contains("kiteloop"))
    }

    func testTheFinishedBannerBodyCarriesNoMarkdownSymbols() {
        let fromHeading = NotificationService.finishedBanner(
            agentName: "Developer", projectName: "kiteloop",
            reply: "```\n\n## Fixed the **banner** in `NotificationService`\n\nMore below.").body
        XCTAssertEqual(fromHeading, "Fixed the banner in NotificationService")
        for symbol in ["#", "**", "`"] {
            XCTAssertFalse(fromHeading.contains(symbol), "the body still shows \(symbol)")
        }

        let fromList = NotificationService.finishedBanner(
            agentName: "Developer", projectName: "kiteloop", reply: "- __Renamed__ my_value").body
        XCTAssertEqual(fromList, "Renamed my_value")
    }

    func testALongReplyIsCutAtAWordWithAnEllipsis() {
        let reply = String(repeating: "word ", count: 30) + "tail"
        let body = NotificationService.finishedBanner(
            agentName: "Developer", projectName: "kiteloop", reply: reply).body

        XCTAssertTrue(body.hasSuffix("…"))
        XCTAssertLessThanOrEqual(body.count, NotificationService.finishedBodyLimit + 1)
        XCTAssertTrue(body.dropLast().hasSuffix("word"), "cut mid-word: \(body)")
    }

    func testAShortReplyIsLeftWhole() {
        let body = NotificationService.finishedBanner(
            agentName: "Developer", projectName: "kiteloop", reply: "All tests pass.").body
        XCTAssertEqual(body, "All tests pass.")
    }

    func testAFinishedBannerOpensTheAgentsChat() {
        let written = BannerDestination(kind: .chat, project: "/tmp/kiteloop", id: "developer")
        let read = roundTrip(written)

        XCTAssertEqual(read, written)
        XCTAssertEqual(read?.kind, .chat)
        XCTAssertEqual(read?.id, "developer")
        XCTAssertNil(read?.gate, "a finished turn is no gate; the window opens the chat itself")
    }

    // MARK: - The crashed banner

    func testTheCrashedBannerNamesTheAgentTheProjectAndTheReason() {
        let banner = NotificationService.crashedBanner(
            agentName: "Developer", projectName: "kiteloop", reason: "claude: command not found")
        XCTAssertTrue(banner.title.contains("Developer"))
        XCTAssertTrue(banner.title.contains("kiteloop"))
        XCTAssertEqual(banner.body, "claude: command not found")
    }

    func testALongCrashReasonIsCutAtAWordWithAnEllipsis() {
        let reason = String(repeating: "word ", count: 30) + "tail"
        let body = NotificationService.crashedBanner(
            agentName: "Developer", projectName: "kiteloop", reason: reason).body

        XCTAssertTrue(body.hasSuffix("…"))
        XCTAssertLessThanOrEqual(body.count, NotificationService.finishedBodyLimit + 1)
        XCTAssertTrue(body.dropLast().hasSuffix("word"), "cut mid-word: \(body)")
    }

    func testACrashWithNoReasonSaysSo() {
        let body = NotificationService.crashedBanner(
            agentName: "Developer", projectName: "kiteloop", reason: nil).body
        XCTAssertTrue(body.contains("no reason"), body)
    }

    func testACrashedBannerOpensTheAgentsChat() {
        let written = BannerDestination(kind: .chat, project: "/tmp/kiteloop", id: "developer")
        let banner = NotificationService.crashedBanner(
            agentName: "Developer", projectName: "kiteloop", reason: "exit 1")
        let content = NotificationService.bannerContent(
            title: banner.title, body: banner.body, badge: 1, destination: written)

        XCTAssertEqual(BannerDestination(userInfo: content.userInfo), written)
    }

    func testACrashDeliversNothingWhileTheAppIsFrontmost() {
        let service = NotificationService.shared
        service.clearBadge()
        let active = NSApplication.shared.isActive

        service.notifyError(
            agentName: "Developer", projectName: "kiteloop", reason: "exit 1",
            destination: BannerDestination(kind: .chat, project: "/tmp/kiteloop", id: "developer"))

        XCTAssertEqual(service.pendingCount, active ? 0 : 1,
                       "a crash banners only while the app is in the background (isActive=\(active))")
    }

    // MARK: - Where a clicked banner lands in the window

    private let openTabs = [
        KiteloopProject(rootURL: URL(fileURLWithPath: "/tmp/kiteloop")),
        KiteloopProject(rootURL: URL(fileURLWithPath: "/tmp/other"))
    ]

    func testAClickedApprovalBannerOpensTheAutopilotGateOfItsProject() throws {
        let banner = BannerDestination(kind: .approval, project: "/tmp/other", id: "add-banner")

        let landing = try XCTUnwrap(MainWindow.bannerLanding(for: banner, among: openTabs))

        XCTAssertEqual(landing.project.id, "/tmp/other")
        XCTAssertEqual(landing.gate, .approval(itemID: "add-banner"))
    }

    /// Banners posted by path find a tab opened with a trailing slash — the
    /// spelling NSOpenPanel hands back.
    func testAClickedQuestionBannerFindsItsProjectByPath() throws {
        let tabs = [KiteloopProject(rootURL: URL(fileURLWithPath: "/tmp/kiteloop/", isDirectory: true))]
        let banner = BannerDestination(kind: .question, project: "/tmp/kiteloop", id: "builder")

        let landing = try XCTUnwrap(MainWindow.bannerLanding(for: banner, among: tabs))

        XCTAssertEqual(landing.project.id, "/tmp/kiteloop")
        XCTAssertEqual(landing.gate, .question(agentID: "builder"))
    }

    /// A finished turn is no gate, but it lands where a question does: the
    /// agent's own chat, selected in its project.
    func testAClickedFinishedBannerOpensThatAgentsChat() throws {
        let banner = BannerDestination(kind: .chat, project: "/tmp/kiteloop", id: "developer")

        let landing = try XCTUnwrap(MainWindow.bannerLanding(for: banner, among: openTabs))

        XCTAssertEqual(landing.project.id, "/tmp/kiteloop")
        XCTAssertEqual(landing.gate, .question(agentID: "developer"))
    }

    /// A project closed since the banner was posted leaves the window where it
    /// is, as does a banner that carried no destination at all.
    func testABannerForAProjectNotOpenOrWithNoDestinationGoesNowhere() {
        let closed = BannerDestination(kind: .approval, project: "/tmp/closed", id: "add-banner")

        XCTAssertNil(MainWindow.bannerLanding(for: closed, among: openTabs))
        XCTAssertNil(MainWindow.bannerLanding(for: nil, among: openTabs))
    }
}
