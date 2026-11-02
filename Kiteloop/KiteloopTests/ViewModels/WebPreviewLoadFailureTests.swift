import XCTest
import KiteloopCore
@testable import Kiteloop

/// A load the pane actually starts and cannot finish used to reach the human as
/// nothing at all: `didFail` set `isLoading` false and dropped the error, so a
/// dev server that was not running looked exactly like a page that was empty.
/// The same silence was in the action row — a capture WebKit could not render
/// made the Send screenshot button do nothing. These pin both, and pin that the
/// gate's own refusals still read as refusals rather than as failures.
@MainActor
final class WebPreviewLoadFailureTests: XCTestCase {
    private var tempDir: URL!
    private var orchestrator: Orchestrator!

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "web-preview-load-failure-tests")
        let eventBus = EventBus(eventsURL: tempDir.appending(path: "events"))
        orchestrator = Orchestrator(
            runtime: MockAgentRuntime(), eventBus: eventBus,
            subscriptionEngine: SubscriptionEngine(eventBus: eventBus),
            memoryManager: MemoryManager(project: KiteloopProject(rootURL: tempDir))
        )
    }

    // MARK: - A load that fails says so

    /// A `file://` path under a directory that was never created: WebKit begins
    /// the navigation and fails it, with no network and no port involved.
    func testALoadWebKitCannotFinishLeavesAMessageForTheHuman() async throws {
        let preview = WebPreviewViewModel()

        XCTAssertEqual(preview.load(Self.missingPage(under: tempDir), source: .user), .allow,
                       "setup: a file path is local content the gate allows")

        try await eventually("the failed load to be reported") { preview.loadFailure != nil }
        XCTAssertFalse(preview.loadFailure?.isEmpty ?? true,
                       "a blank pane with a blank banner is the bug, not the fix")
        XCTAssertNil(preview.blockedMessage, "nothing was refused, so no refusal banner")
    }

    // MARK: - A refusal is not a failure

    func testAGateRefusalRaisesOneBannerNotTwo() {
        let preview = WebPreviewViewModel()
        preview.mode = .trusted

        XCTAssertEqual(preview.load("https://example.invalid/", source: .user), .deny,
                       "setup: Trusted mode refuses a non-local host")

        XCTAssertNotNil(preview.blockedMessage)
        XCTAssertNil(preview.loadFailure,
                     "a refusal already has its wording in blockedMessage — a second banner reads as a second problem")
    }

    /// The gate says no by cancelling the navigation, and WebKit reports that
    /// cancellation as an error. Fed straight in, because a policy `.cancel`
    /// does not reliably surface one at all — the guard has to hold for the
    /// times it does.
    func testACancelledNavigationIsNotReportedAsAFailure() {
        let preview = WebPreviewViewModel()

        preview.navigationDidFail(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        XCTAssertNil(preview.loadFailure, "NSURLErrorCancelled is how a refusal is spelled")

        preview.navigationDidFail(NSError(domain: "WebKitErrorDomain", code: 102))
        XCTAssertNil(preview.loadFailure, "frame-load-interrupted-by-policy-change is the same refusal")

        preview.navigationDidFail(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost))
        XCTAssertNotNil(preview.loadFailure, "a host that does not resolve is a real failure")
    }

    // MARK: - A failure does not outlive the page it describes

    func testStartingTheNextLoadClearsTheFailure() async throws {
        let preview = WebPreviewViewModel()
        preview.load(Self.missingPage(under: tempDir), source: .user)
        try await eventually("the failed load to be reported") { preview.loadFailure != nil }

        // Checked on the synchronous return, before WebKit has had a chance to
        // fail this one too: what is pinned is that the banner goes down when
        // the load starts, not that the next failure happens to replace it.
        preview.load(Self.missingPage(under: tempDir, named: "another.html"), source: .user)

        XCTAssertNil(preview.loadFailure,
                     "the failure described the load before this one")
    }

    func testALoadThatLandsClearsTheFailure() async throws {
        let preview = WebPreviewViewModel()
        preview.load(Self.missingPage(under: tempDir), source: .user)
        try await eventually("the failed load to be reported") { preview.loadFailure != nil }

        try await load("<p>the page is here now</p>", into: preview)

        XCTAssertNil(preview.loadFailure,
                     "a stale failure must not sit over a page that is on screen")
    }

    // MARK: - Reload after a failure

    /// The dev server that was not up yet: the page appears, and Reload has to
    /// retry the address that failed — a fresh pane has no page of its own to
    /// reload, so WebKit's reload did nothing at all.
    func testReloadInAFreshPaneRetriesTheAddressThatFailed() async throws {
        let preview = WebPreviewViewModel()
        let path = Self.missingPage(under: tempDir)
        preview.load(path, source: .user)
        try await eventually("the failed load to be reported") { preview.loadFailure != nil }

        let page = try Self.write("<p>up now</p>", to: path)
        preview.reload()

        try await eventually("the retried page to land") {
            preview.currentURL?.standardizedFileURL == page && !preview.isLoading
        }
        XCTAssertNil(preview.loadFailure, "the retry landed, so the banner goes")
    }

    func testAFailedLoadKeepsItsAddressAndReloadRetriesIt() async throws {
        let pageA = tempDir.appending(path: "a.html")
        try Data("<p>A</p>".utf8).write(to: pageA)
        let preview = WebPreviewViewModel()
        preview.load(pageA.path(percentEncoded: false), source: .user)
        try await eventually("page A to land") {
            preview.currentURL?.standardizedFileURL == pageA.standardizedFileURL && !preview.isLoading
        }

        let pathB = Self.missingPage(under: tempDir, named: "b.html")
        preview.load(pathB, source: .user)
        try await eventually("the failed load to be reported") { preview.loadFailure != nil }
        try await eventually("WebKit to settle back on A") { !preview.isLoading }
        let addressB = URL(fileURLWithPath: pathB).absoluteString
        XCTAssertEqual(preview.urlText, addressB, "the address typed, not the page before it")

        let pageB = try Self.write("<p>B</p>", to: pathB)
        preview.reload()

        try await eventually("page B to land") {
            preview.currentURL?.standardizedFileURL == pageB && !preview.isLoading
        }
        XCTAssertNil(preview.loadFailure)
        XCTAssertEqual(preview.urlText, addressB)
    }

    /// The retry is a load like any other, so the gate judges it in the mode
    /// the pane is in now, not the one the address failed under.
    func testARetryTheCurrentModeRefusesIsBlockedNotLoaded() throws {
        let preview = WebPreviewViewModel()
        preview.mode = .external
        let url = try XCTUnwrap(URL(string: "https://example.invalid/"))
        preview.navigationDidFail(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost,
                                          userInfo: [NSURLErrorFailingURLErrorKey: url]))
        preview.setMode(.trusted)

        preview.reload()

        XCTAssertEqual(preview.refusedURL, url, "the gate saw the retry and refused it")
        XCTAssertNotNil(preview.blockedMessage, "the usual blocked banner")
        XCTAssertNil(preview.loadFailure, "one banner for one decision")
        XCTAssertNil(preview.currentURL, "nothing was loaded behind the gate's back")
    }

    // MARK: - Stop

    func testStoppingALoadClearsTheSpinnerWithoutABanner() async throws {
        let page = tempDir.appending(path: "page.html")
        try Data("<p>a page</p>".utf8).write(to: page)
        let preview = WebPreviewViewModel()
        XCTAssertEqual(preview.load(page.path(percentEncoded: false), source: .user), .allow,
                       "setup: a file path is local content the gate allows")

        preview.stopLoading()

        try await eventually("the stopped load to leave the spinner off") { !preview.isLoading }
        XCTAssertNil(preview.loadFailure, "stopping is a choice, not a failure")
        XCTAssertNil(preview.blockedMessage, "nothing was refused, so no refusal banner")
    }

    func testStoppingWithNoLoadInFlightChangesNothing() {
        let preview = WebPreviewViewModel()
        let before = preview.currentURL

        preview.stopLoading()

        XCTAssertFalse(preview.isLoading)
        XCTAssertNil(preview.loadFailure)
        XCTAssertEqual(preview.currentURL, before)
    }

    // MARK: - The screenshot button

    /// The pane's web view has a zero frame until it is laid out, which is
    /// exactly the state WebKit cannot render — the same one a human hits when
    /// the click produced nothing at all.
    func testSendScreenshotSaysSoWhenThePaneCannotBeRendered() async throws {
        let preview = WebPreviewViewModel()
        let chat = makeChatVM()
        preview.retarget(to: chat, agentName: "A")

        await preview.sendScreenshotToAgent()

        XCTAssertTrue(chat.pendingAttachments.isEmpty, "setup: there was nothing to attach")
        XCTAssertEqual(preview.loadFailure,
                       WebPreviewViewModel.ScreenshotError.captureFailed.errorDescription,
                       "a click that attaches nothing has to say why")
    }

    /// Each capture is named after its page and time, so two in the tray differ;
    /// `writeScreenshot` uses the same builder.
    func testAScreenshotIsNamedAfterItsPageAndTime() throws {
        let date = try XCTUnwrap(Calendar(identifier: .gregorian).date(from: DateComponents(
            year: 2026, month: 9, day: 22, hour: 14, minute: 15, second: 3)))

        XCTAssertEqual(WebPreviewViewModel.screenshotFilename(
            for: URL(string: "http://localhost:5173/app"), at: date), "localhost-20260922-141503.png")
        XCTAssertEqual(WebPreviewViewModel.screenshotFilename(
            for: URL(fileURLWithPath: "/tmp/site/Landing Page.html"), at: date), "landing-page-20260922-141503.png")
        XCTAssertEqual(WebPreviewViewModel.screenshotFilename(for: nil, at: date), "preview-20260922-141503.png")
    }

    // MARK: - Helpers

    /// A path that resolves nowhere, under a directory that was never created.
    private static func missingPage(under directory: URL, named name: String = "nope.html") -> String {
        directory.appending(path: "never-created/\(name)").path(percentEncoded: false)
    }

    /// Writes `html` to `path`, creating its directory, and returns its file URL.
    private static func write(_ html: String, to path: String) throws -> URL {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(html.utf8).write(to: url)
        return url
    }

    private func makeChatVM() -> ChatViewModel {
        orchestrator.addAgent(Agent(id: "a", name: "A", model: "sonnet",
                                    systemPrompt: "", tools: [], denied: [],
                                    permissionMode: "default", state: .idle))
        return ChatViewModel(agentID: "a", projectURL: tempDir, orchestrator: orchestrator)
    }
}
