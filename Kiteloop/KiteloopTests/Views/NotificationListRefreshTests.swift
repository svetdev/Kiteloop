import XCTest
import KiteloopCore
@testable import Kiteloop

/// What the notifications popover shows, and — the regression this pins — that
/// a later read sees what arrived since the first one.
///
/// The list used to be filled only when the popover opened, on a pull, or after
/// the human acted. Somebody watching for a run to reach its gate saw an empty
/// Needs You until they clicked away and clicked back.
final class NotificationListRefreshTests: XCTestCase {
    private var tempDir: URL!
    private var store: NotificationStore!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "notification-list-refresh")
        store = NotificationStore(notificationsURL: tempDir.appending(path: "notifications.log"))
    }

    private func notice(_ type: NotificationItem.NotificationType) -> NotificationItem {
        NotificationItem(agentID: "agent", type: type, title: "t", body: "b")
    }

    /// The same three-way split the view drew inline: pending and actionable to
    /// the inbox, pending and ambient to activity, resolved to its own list.
    func testTheSplitMatchesWhatTheViewDrew() async {
        let question = notice(.question)
        let completion = notice(.complete)
        let event = notice(.event)
        let handled = notice(.approval)
        for item in [question, completion, event, handled] { await store.add(item) }
        await store.markResolved(id: handled.id)

        let contents = await NotificationListContents.load(from: store)

        XCTAssertEqual(contents.inbox.map(\.id), [question.id])
        XCTAssertEqual(Set(contents.activity.map(\.id)), [completion.id, event.id])
        XCTAssertEqual(contents.resolved.map(\.id), [handled.id])
    }

    /// The regression: a question arrives after the list is already on screen.
    /// No reopen, no pull, no mutation in between — the next load has it.
    func testANoticeArrivingAfterTheFirstLoadShowsUpOnTheNext() async {
        let first = await NotificationListContents.load(from: store)
        XCTAssertTrue(first.inbox.isEmpty)

        let question = notice(.question)
        await store.add(question)

        let second = await NotificationListContents.load(from: store)
        XCTAssertEqual(second.inbox.map(\.id), [question.id])
    }

    /// An empty store is three empty lists, which is what puts the popover's
    /// empty state on screen rather than three bare headers.
    func testAnEmptyStoreLoadsThreeEmptyLists() async {
        let contents = await NotificationListContents.load(from: store)
        XCTAssertTrue(contents.inbox.isEmpty)
        XCTAssertTrue(contents.activity.isEmpty)
        XCTAssertTrue(contents.resolved.isEmpty)
    }

    /// What the mutation paths do to the next load: resolving moves a row out of
    /// the inbox and into Resolved, dismissing removes it from both, and Clear
    /// All empties activity while leaving the inbox alone.
    func testMutationsAreVisibleToTheNextLoad() async {
        let question = notice(.question)
        let error = notice(.error)
        let completion = notice(.complete)
        for item in [question, error, completion] { await store.add(item) }

        await store.markResolved(id: question.id)
        await store.dismissAllPending(actionable: false)

        var contents = await NotificationListContents.load(from: store)
        XCTAssertEqual(contents.inbox.map(\.id), [error.id])
        XCTAssertTrue(contents.activity.isEmpty)
        XCTAssertEqual(contents.resolved.map(\.id), [question.id])

        await store.dismiss(id: error.id)

        contents = await NotificationListContents.load(from: store)
        XCTAssertTrue(contents.inbox.isEmpty)
        XCTAssertEqual(contents.resolved.map(\.id), [question.id])
    }

    /// The loop the view's `.task` runs must not start under the unit suite —
    /// a repeating refresh in a test host is a timer nothing cancels.
    func testTheRefreshLoopIsOffUnderTheUnitSuite() {
        XCTAssertTrue(UITestingSupport.isUnitTesting)
    }

    // MARK: - Where a row leads

    func testAQuestionCarryingAProjectLeadsToTheAgentAskingIt() {
        let question = NotificationItem(agentID: "builder", type: .question, title: "Ada needs input",
                                        body: "Which port?", projectPath: "/tmp/repo")
        XCTAssertEqual(NotificationRowLink(question), .agent(agentID: "builder", projectPath: "/tmp/repo"))
    }

    /// A notice filed before questions carried a project — or one filed by
    /// something that knows none — stays plain text, as it always was.
    func testAQuestionWithNoProjectIsPlainText() {
        XCTAssertEqual(NotificationRowLink(notice(.question)), .none)
    }

    /// The item link is unchanged and comes first.
    func testAnApprovalCarryingAnItemStillOpensTheItem() {
        let approval = NotificationItem(agentID: "worker", type: .approval, title: "t", body: "b",
                                        itemID: "add-banner", projectPath: "/tmp/repo")
        XCTAssertEqual(NotificationRowLink(approval), .item(itemID: "add-banner", projectPath: "/tmp/repo"))
    }

    /// Completions, events and errors are not widened into agent links.
    func testOtherNoticesCarryingAProjectAreNotAgentLinks() {
        for type in [NotificationItem.NotificationType.complete, .event, .error] {
            let item = NotificationItem(agentID: "builder", type: type, title: "t", body: "b",
                                        projectPath: "/tmp/repo")
            XCTAssertEqual(NotificationRowLink(item), .none, "\(type)")
        }
    }

    // MARK: - Opening the agent

    private struct Landing {
        var activeProjectID: String?
        var selected: [String: String] = [:]
        var popoverOpen = true
    }

    @MainActor
    private func land(_ agentID: String, at path: String, open: [KiteloopProject],
                      from landing: Landing) -> Landing {
        var landing = landing
        AgentLinkLanding.land(
            agentID: agentID, projectPath: path,
            openProjects: open, activeProjectID: landing.activeProjectID,
            switchTo: { landing.activeProjectID = $0.id },
            select: { landing.selected[$0] = $1 },
            closeNotifications: { landing.popoverOpen = false })
        return landing
    }

    @MainActor
    func testOpeningAnAgentInAnotherProjectSwitchesToItAndSelectsTheAgent() {
        let here = KiteloopProject(rootURL: tempDir.appending(path: "here"))
        let there = KiteloopProject(rootURL: tempDir.appending(path: "there"))

        let landing = land("builder", at: there.rootURL.path(percentEncoded: false), open: [here, there],
                           from: Landing(activeProjectID: here.id))

        XCTAssertEqual(landing.activeProjectID, there.id)
        XCTAssertEqual(landing.selected, [there.id: "builder"])
    }

    @MainActor
    func testOpeningAnAgentClosesThePopover() {
        let here = KiteloopProject(rootURL: tempDir.appending(path: "here"))

        let landing = land("builder", at: here.rootURL.path(percentEncoded: false), open: [here],
                           from: Landing(activeProjectID: here.id))

        XCTAssertFalse(landing.popoverOpen)
        XCTAssertEqual(landing.activeProjectID, here.id)
        XCTAssertEqual(landing.selected, [here.id: "builder"])
    }

    /// A project closed since the question was asked has no chat to land on.
    @MainActor
    func testOpeningAnAgentInAClosedProjectChangesNothing() {
        let here = KiteloopProject(rootURL: tempDir.appending(path: "here"))

        let landing = land("builder", at: tempDir.appending(path: "gone").path(percentEncoded: false),
                           open: [here], from: Landing(activeProjectID: here.id))

        XCTAssertTrue(landing.popoverOpen)
        XCTAssertEqual(landing.activeProjectID, here.id)
        XCTAssertTrue(landing.selected.isEmpty)
    }

    // MARK: - Naming a notice's agent

    private let rosters = [
        NotificationAgentRoster(projectPath: "/work/one", names: ["dev": "Grace", "ada-2": "Ada"]),
        NotificationAgentRoster(projectPath: "/work/two", names: ["dev": "Linus"]),
    ]

    /// The notice's project decides whose "dev" it is.
    func testANamedProjectsRosterNamesTheAgent() {
        XCTAssertEqual(NotificationListContents.agentName("dev", projectPath: "/work/two", rosters: rosters), "Linus")
        XCTAssertEqual(NotificationListContents.agentName("dev", projectPath: "/work/one/", rosters: rosters), "Grace")
        XCTAssertEqual(NotificationListContents.agentName("ada-2", projectPath: "/work/one", rosters: rosters), "Ada")
    }

    /// A notice that names no project takes the first roster that has the id.
    func testANoticeWithNoProjectTakesTheFirstRosterWithTheID() {
        XCTAssertEqual(NotificationListContents.agentName("ada-2", projectPath: nil, rosters: rosters), "Ada")
        XCTAssertEqual(NotificationListContents.agentName("dev", projectPath: nil, rosters: rosters), "Grace")
    }

    /// An id no open project carries — or not the notice's project — is printed as it is.
    func testAnUnknownIDIsPrintedUnchanged() {
        XCTAssertEqual(NotificationListContents.agentName("ghost", projectPath: nil, rosters: rosters), "ghost")
        XCTAssertEqual(NotificationListContents.agentName("", projectPath: nil, rosters: rosters), "")
        XCTAssertEqual(NotificationListContents.agentName("ada-2", projectPath: "/work/two", rosters: rosters), "ada-2")
        XCTAssertEqual(NotificationListContents.agentName("dev", projectPath: "/work/closed", rosters: rosters), "dev")
        XCTAssertEqual(NotificationListContents.agentName("dev", projectPath: nil, rosters: []), "dev")
    }

    // MARK: - When a notice arrived

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private let enUS = Locale(identifier: "en_US")

    /// A notice from today says its time and nothing else.
    func testANoticeFromTodayIsLabelledWithItsTimeAlone() {
        let item = notice(.approval)
        let label = NotificationListView.arrivalLabel(for: item, now: item.timestamp, calendar: utc, locale: enUS)
        let year = String(utc.component(.year, from: item.timestamp))

        XCTAssertFalse(label.contains(year), label)
        XCTAssertEqual(label, MessageBubble.sentTimeLabel(for: item.timestamp, now: item.timestamp,
                                                          calendar: utc, locale: enUS))
    }

    /// A notice from an earlier day says its date as well as its time, so a gate
    /// waiting since yesterday does not read as one from a minute ago.
    func testANoticeFromAnEarlierDayIsLabelledWithItsDateAndTime() {
        let item = notice(.question)
        let now = item.timestamp.addingTimeInterval(2 * 24 * 60 * 60)
        let label = NotificationListView.arrivalLabel(for: item, now: now, calendar: utc, locale: enUS)
        let timeAlone = NotificationListView.arrivalLabel(for: item, now: item.timestamp, calendar: utc, locale: enUS)

        XCTAssertTrue(label.contains(String(utc.component(.year, from: item.timestamp))), label)
        XCTAssertTrue(label.contains(timeAlone), label)
        XCTAssertNotEqual(label, timeAlone)
    }
}
