import XCTest
import KiteloopCore
import WebKit
@testable import Kiteloop

/// `web_scroll` exists so a screenshot can reach past the fold, so what these
/// cover is the two things that makes true.
///
/// The first is that the movement actually lands before anyone photographs it: a
/// page asking for `scroll-behavior: smooth` is still gliding when the script
/// returns, and a report written from that moment describes a place the page is
/// no longer at. The second is the report itself — an agent capturing a long page
/// screenful by screenful loops on "is this the bottom", and a scroll that moves
/// without saying where it ended up leaves it either stopping early or scrolling
/// forever into an empty document.
///
/// The hosts here are all under `.invalid`, which is reserved never to resolve:
/// the gate decides before anything is fetched, so these exercise the real
/// delegate path without a test ever reaching the network.
@MainActor
final class WebScrollToolTests: XCTestCase {
    private var tempDir: URL!
    private var runtime: MockAgentRuntime!
    private var orchestrator: Orchestrator!

    /// What `load` gives the pane, and what every offset here is measured
    /// against. Taken from the shared helper rather than restated, so the two
    /// cannot drift apart into offsets that no longer mean anything.
    private static let viewportHeight = Int(WebTestLoad.viewport.height)

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "web-scroll-tests")

        let eventBus = EventBus(eventsURL: tempDir.appending(path: "events"))
        let subscriptionEngine = SubscriptionEngine(eventBus: eventBus)
        let project = KiteloopProject(rootURL: tempDir)
        let memoryManager = MemoryManager(project: project)
        runtime = MockAgentRuntime()
        orchestrator = Orchestrator(runtime: runtime, eventBus: eventBus,
                                    subscriptionEngine: subscriptionEngine, memoryManager: memoryManager)
    }

    // MARK: - Moving the viewport

    func testScrollingDownMovesTheViewportAndSaysWhereItLanded() async throws {
        let preview = WebPreviewViewModel()
        try await load(Self.tallHTML, into: preview)

        let outcome = await preview.scroll(.down, settle: 0.2)

        guard case .scrolled(let position, .sameDocument) = outcome else {
            return XCTFail("expected an in-place scroll, got: \(outcome)")
        }
        let live = await liveOffset(preview)
        XCTAssertGreaterThan(position.moved, 0)
        XCTAssertEqual(position.after.offset, live, "the report describes a place the page is not at")
        XCTAssertFalse(position.atBottom)
        XCTAssertTrue(outcome.report().contains("There is more below"), outcome.report())
    }

    /// A screenful less a sliver, not a screenful: a line of text sitting across
    /// the fold has to be whole in one of the two screenshots rather than sliced
    /// in both.
    func testConsecutiveScreenfulsOverlapSoNothingIsLostAtTheSeam() async throws {
        let preview = WebPreviewViewModel()
        try await load(Self.tallHTML, into: preview)

        guard case .scrolled(let position, _) = await preview.scroll(.down, settle: 0.2) else {
            return XCTFail("expected a scroll")
        }
        XCTAssertLessThan(position.moved, position.after.viewport,
                          "a full-viewport step drops whatever straddles the fold")
        XCTAssertGreaterThan(position.moved, position.after.viewport / 2,
                             "an overlap this large turns one page into a great many screenshots")
    }

    /// The end of the page is the fact an agent working down a page loops on, so
    /// it is stated rather than left to be inferred from the numbers.
    func testScrollingToTheBottomSaysItIsTheBottom() async throws {
        let preview = WebPreviewViewModel()
        try await load(Self.tallHTML, into: preview)

        let outcome = await preview.scroll(.bottom, settle: 0.2)

        guard case .scrolled(let position, _) = outcome else { return XCTFail("expected a scroll") }
        XCTAssertTrue(position.atBottom, "\(position)")
        XCTAssertFalse(position.atTop)
        XCTAssertTrue(outcome.report().contains("This is the bottom of the page."), outcome.report())
        XCTAssertFalse(outcome.report().contains("There is more below"), outcome.report())
    }

    /// Scrolling into the end of a page is the loop's exit condition. A report
    /// that reads the same as a scroll that moved is one an agent keeps repeating.
    func testScrollingDownAtTheBottomMovesNothingAndSaysWhy() async throws {
        let preview = WebPreviewViewModel()
        try await load(Self.tallHTML, into: preview)
        _ = await preview.scroll(.bottom, settle: 0.2)

        let outcome = await preview.scroll(.down, settle: 0.2)

        guard case .scrolled(let position, _) = outcome else { return XCTFail("expected a scroll") }
        XCTAssertEqual(position.moved, 0)
        XCTAssertTrue(outcome.report().contains("already at the bottom"), outcome.report())
    }

    func testScrollingBackUpAndToTheTop() async throws {
        let preview = WebPreviewViewModel()
        try await load(Self.tallHTML, into: preview)
        _ = await preview.scroll(.bottom, settle: 0.2)

        guard case .scrolled(let up, _) = await preview.scroll(.up, settle: 0.2) else {
            return XCTFail("expected a scroll")
        }
        XCTAssertLessThan(up.moved, 0)
        XCTAssertTrue(up.report(contains: "Scrolled up"), up.movementSentence)

        guard case .scrolled(let top, _) = await preview.scroll(.top, settle: 0.2) else {
            return XCTFail("expected a scroll")
        }
        let live = await liveOffset(preview)
        XCTAssertTrue(top.atTop, "\(top)")
        XCTAssertEqual(live, 0)
    }

    /// A page with nothing below the fold has to say so: an agent told only that
    /// the page "did not move" cannot tell that apart from a scroll that failed.
    func testAPageThatFitsReportsNothingBelowTheFold() async throws {
        let preview = WebPreviewViewModel()
        try await load(Self.shortHTML, into: preview)

        let outcome = await preview.scroll(.down, settle: 0.2)

        guard case .scrolled(let position, _) = outcome else { return XCTFail("expected a scroll") }
        XCTAssertEqual(position.moved, 0)
        XCTAssertTrue(position.fitsInViewport, "\(position)")
        XCTAssertTrue(outcome.report().contains("nothing below the fold"), outcome.report())
    }

    /// `scroll-behavior: smooth` is the case the report is written against: the
    /// page is still travelling when the script returns, so a position read at
    /// that instant is wrong and the screenshot taken next is of a blur. The
    /// scroll asks for `instant` precisely so neither happens.
    func testASmoothScrollingPageHasLandedBeforeItIsReported() async throws {
        let preview = WebPreviewViewModel()
        try await load(Self.smoothTallHTML, into: preview)

        // A settle far shorter than a smooth scroll's animation: if the page were
        // still gliding, this would catch it mid-flight.
        guard case .scrolled(let position, _) = await preview.scroll(.down, settle: 0.05) else {
            return XCTFail("expected a scroll")
        }
        let live = await liveOffset(preview)
        XCTAssertGreaterThanOrEqual(position.after.offset, Self.viewportHeight - 100,
                                    "the page was still animating when its position was reported")
        XCTAssertEqual(position.after.offset, live)
    }

    // MARK: - Scrolling to an element

    func testScrollingToARefBringsThatElementIntoView() async throws {
        let preview = WebPreviewViewModel()
        try await load(Self.tallHTML, into: preview)
        let ref = try await ref(preview, named: "Deep control")
        let onScreenBefore = await isOnScreen("#deep", in: preview)
        XCTAssertFalse(onScreenBefore, "the control started on screen")

        let outcome = await preview.scrollToElement(ref, settle: 0.2)

        guard case .broughtIntoView(let element, let position, _) = outcome else {
            return XCTFail("expected the element to be brought into view, got: \(outcome)")
        }
        let onScreenAfter = await isOnScreen("#deep", in: preview)
        XCTAssertEqual(element.name, "Deep control")
        XCTAssertGreaterThan(position.moved, 0)
        XCTAssertTrue(onScreenAfter, "the control is still off screen")
        XCTAssertTrue(outcome.report().contains("Deep control"), outcome.report())
    }

    /// Centred, not merely on screen: a control flush against the top edge is
    /// technically visible and useless in a screenshot, with whatever sits above
    /// it cut off.
    func testTheElementLandsAwayFromTheEdges() async throws {
        let preview = WebPreviewViewModel()
        try await load(Self.tallHTML, into: preview)
        let ref = try await ref(preview, named: "Middle control")

        _ = await preview.scrollToElement(ref, settle: 0.2)

        let measured = await rectTop("#middle", in: preview)
        let top = try XCTUnwrap(measured)
        XCTAssertGreaterThan(top, 100, "the control is jammed against the top of the pane")
        XCTAssertLessThan(top, Double(Self.viewportHeight) - 100)
    }

    /// A ref from a superseded snapshot names some other element now, and
    /// scrolling to whatever happens to be sitting at that number is how an agent
    /// screenshots the wrong part of a page and believes it.
    func testAStaleRefIsRefusedRatherThanScrolledSomewhere() async throws {
        let preview = WebPreviewViewModel()
        try await load(Self.tallHTML, into: preview)
        let ref = try await ref(preview, named: "Deep control")
        _ = try await list(preview)

        let outcome = await preview.scrollToElement(ref, settle: 0.2)

        guard case .refused(.stale) = outcome else {
            return XCTFail("expected a refusal, got: \(outcome)")
        }
        let live = await liveOffset(preview)
        XCTAssertTrue(outcome.report().contains("web_list_elements"), outcome.report())
        XCTAssertEqual(live, 0, "a refused scroll moved the page anyway")
    }

    /// The page redrew without navigating, so the generation still matches while
    /// the node is gone — the case only the page-side registry can catch.
    func testARefWhoseElementLeftThePageIsRefused() async throws {
        let preview = WebPreviewViewModel()
        try await load(Self.tallHTML, into: preview)
        let ref = try await ref(preview, named: "Deep control")
        _ = try? await preview.webView.evaluateJavaScript("document.getElementById('deep').remove(); 1")

        let outcome = await preview.scrollToElement(ref, settle: 0.2)

        XCTAssertEqual(outcome, .refused(.detached))
        XCTAssertTrue(outcome.report().contains("no longer on the page"), outcome.report())
    }

    // MARK: - What a scroll costs

    /// Nothing about the document changed, so the numbers from the last listing
    /// still name the same controls. Paying for a re-list after every screenful
    /// would make capturing a long page the expensive thing it exists to avoid.
    func testScrollingLeavesElementRefsUsable() async throws {
        let preview = WebPreviewViewModel()
        try await load(Self.tallHTML, into: preview)
        let ref = try await ref(preview, named: "Deep control")

        _ = await preview.scroll(.bottom, settle: 0.2)

        guard case .found(let element) = await preview.resolveElement(ref) else {
            return XCTFail("a scroll invalidated a ref it never had to")
        }
        XCTAssertEqual(element.name, "Deep control")
    }

    /// …but a page that appends as it is scrolled has controls the listing never
    /// saw, and the agent has to be told to look again before addressing them.
    func testTheReportSaysToListAgainForWhatTheScrollBroughtIn() async throws {
        let preview = WebPreviewViewModel()
        try await load(Self.tallHTML, into: preview)

        let report = await preview.scroll(.down, settle: 0.2).report()

        XCTAssertTrue(report.contains("Existing element refs still work"), report)
        XCTAssertTrue(report.contains("web_list_elements"), report)
    }

    /// The ordinary scroll is the one an agent runs in a loop, so it must not
    /// carry a sentence about a navigation that did not happen.
    func testAnOrdinaryScrollDoesNotTalkAboutNavigation() async throws {
        let preview = WebPreviewViewModel()
        try await load(Self.tallHTML, into: preview)

        let report = await preview.scroll(.down, settle: 0.2).report()

        XCTAssertFalse(report.contains("did not navigate"), report)
    }

    // MARK: - Attribution

    /// A scroll handler that navigates is exactly as much a way around the gate
    /// as a link is: in External mode an unapproved host has to park for the
    /// human rather than load because the agent scrolled.
    func testANavigationAScrollSetsOffIsGatedAsTheAgentsOwn() async throws {
        let preview = WebPreviewViewModel()
        preview.mode = .external
        let page = try writePage(Self.scrollNavigatesHTML)
        try await loadFile(page, into: preview)

        let outcome = await preview.scroll(.down, settle: 3)

        guard case .scrolled(_, .awaitingApproval(let url)) = outcome else {
            return XCTFail("a scroll handler navigated straight past the gate: \(outcome)")
        }
        XCTAssertEqual(url.host, "example.invalid")
        XCTAssertTrue(outcome.report().contains("waiting on them"), outcome.report())
        XCTAssertFalse(preview.isAgentDriving, "the span outlived the navigation it was covering")
    }

    /// What approval buys, from the same seat: an allowlisted host reached by a
    /// scroll handler is not asked about again, and the pane goes.
    ///
    /// The symmetric half of the test above, and it earns its place — a gate that
    /// parked everything would satisfy that one perfectly.
    func testAnApprovedHostAScrollNavigatesToIsNotHeldAgain() async throws {
        let preview = WebPreviewViewModel()
        preview.mode = .external
        preview.allowlist = ["example.invalid"]
        let page = try writePage(Self.scrollNavigatesHTML)
        try await loadFile(page, into: preview)

        let outcome = await preview.scroll(.down, settle: 3)

        guard case .scrolled(_, let effect) = outcome else {
            return XCTFail("expected a scroll, got: \(outcome)")
        }
        // `.invalid` never resolves, so the load fails after the gate lets it by —
        // what is under test is the decision, and parking is the only way an
        // approved host can fail to make one.
        XCTAssertNil(preview.pendingExternalURL, "an approved host was held for approval a second time")
        XCTAssertNil(preview.blockedMessage, "External mode blocked a host the human approved")
        if case .awaitingApproval = effect {
            XCTFail("the gate parked a host it had already been given: \(effect)")
        }
    }

    /// The gate is only a gate if WebKit actually asks it, and every method of
    /// `WKNavigationDelegate` is optional — a signature that stops witnessing the
    /// requirement compiles clean, is never called, and every navigation is
    /// allowed by default. That is not hypothetical: it is how this shipped, and
    /// the failure is invisible from the Swift side, so it is asserted against the
    /// Objective-C runtime directly.
    func testTheGateIsWiredIntoWebKitAtAll() throws {
        let preview = WebPreviewViewModel()
        let delegate = try XCTUnwrap(preview.webView.navigationDelegate)

        XCTAssertTrue(
            delegate.responds(to: Selector("webView:decidePolicyForNavigationAction:decisionHandler:")),
            "WebKit has no navigation-policy method to call — the gate is decorative and everything loads"
        )
    }

    func testTheAgentDrivenSpanClosesWhenTheScrollIsDone() async throws {
        let preview = WebPreviewViewModel()
        preview.mode = .external
        try await load(Self.tallHTML, into: preview)

        _ = await preview.scroll(.down, settle: 0.2)

        XCTAssertFalse(preview.isAgentDriving, "a scroll that ended still claiming the pane gates the human")
        XCTAssertTrue(preview.allowsInPageNavigation(to: Self.externalURL),
                      "the human is browsing again once the scroll is done")
    }

    /// A refused scroll must not leave the span open either — the refusal happens
    /// before the span in `scrollToElement`, and this is what holds that ordering.
    func testARefusedScrollLeavesThePaneUnclaimed() async throws {
        let preview = WebPreviewViewModel()
        try await load(Self.tallHTML, into: preview)

        _ = await preview.scrollToElement(WebElementRef(index: 99, generation: 1), settle: 0.2)

        XCTAssertFalse(preview.isAgentDriving)
    }

    // MARK: - Reporting, without a page

    func testTheReportNamesTheVisibleBandAndTheWholePage() {
        let position = WebScrollPosition(
            before: WebScrollMetrics(offset: 0, viewport: 700, content: 4200),
            after: WebScrollMetrics(offset: 630, viewport: 700, content: 4200)
        )

        let report = WebScrollOutcome.scrolled(position, .sameDocument).report()

        XCTAssertTrue(report.contains("Scrolled down 630px."), report)
        XCTAssertTrue(report.contains("Showing 630–1330px of 4200px."), report)
    }

    /// The visible band never runs past the end of the document — a viewport
    /// hanging over the bottom would otherwise report a page taller than it is.
    func testTheVisibleBandStopsAtTheEndOfTheDocument() {
        let position = WebScrollPosition(
            before: WebScrollMetrics(offset: 0, viewport: 700, content: 900),
            after: WebScrollMetrics(offset: 200, viewport: 700, content: 900)
        )

        XCTAssertEqual(position.visibleBottom, 900)
        XCTAssertTrue(position.atBottom)
    }

    /// Fractional layout and page zoom leave a page a pixel short of its own
    /// height at the true bottom, and an agent told it is half a pixel from the
    /// end scrolls forever.
    func testAPixelShortOfTheEndStillReadsAsTheBottom() {
        let position = WebScrollPosition(
            before: WebScrollMetrics(offset: 3000, viewport: 700, content: 4200),
            after: WebScrollMetrics(offset: 3499, viewport: 700, content: 4200)
        )

        XCTAssertTrue(position.atBottom)
    }

    func testANavigatingScrollIsReportedAlongsideThePosition() {
        let position = WebScrollPosition(
            before: WebScrollMetrics(offset: 0, viewport: 700, content: 4200),
            after: WebScrollMetrics(offset: 0, viewport: 700, content: 700)
        )

        let report = WebScrollOutcome.scrolled(position, .navigated(Self.externalURL)).report()

        XCTAssertTrue(report.contains("The page navigated to"), report)
    }

    func testAPaneWithNothingToScrollSaysSoRatherThanReportingZeroes() {
        let report = WebScrollOutcome.failed.report()

        XCTAssertTrue(report.contains("nothing to scroll"), report)
        XCTAssertTrue(report.contains("web_navigate"), report)
    }

    // MARK: - Directions

    func testOnlyTheFourDirectionsParse() {
        XCTAssertEqual(WebScrollDirection(token: " DOWN "), .down)
        XCTAssertEqual(WebScrollDirection(token: "bottom"), .bottom)
        XCTAssertNil(WebScrollDirection(token: "downwards"))
        XCTAssertNil(WebScrollDirection(token: "500px"))
        XCTAssertEqual(WebScrollDirection.tokens, "down, up, top, bottom")
    }

    // MARK: - Reachability (driven through the real MCP tool-call path)

    func testScrollingIsRefusedWithoutAnAttachedPane() async {
        await callTool(preview: nil, input: #"{"direction": "down"}"#)

        XCTAssertTrue(runtime.mcpToolResults[0].contains("no web preview pane is attached"),
                      "got: \(runtime.mcpToolResults[0])")
    }

    func testScrollingIsRefusedWhenNoPageIsLoaded() async {
        await callTool(preview: WebPreviewViewModel(), input: #"{"direction": "down"}"#)

        XCTAssertTrue(runtime.mcpToolResults[0].contains("web_navigate"),
                      "got: \(runtime.mcpToolResults[0])")
    }

    /// Working down a page is the ordinary case, so it needs no arguments at all.
    func testAnEmptyCallScrollsDown() async throws {
        let preview = WebPreviewViewModel()
        try await load(Self.tallHTML, into: preview)

        await callTool(preview: preview, input: "{}")

        XCTAssertTrue(runtime.mcpToolResults[0].hasPrefix("Scrolled down"),
                      "got: \(runtime.mcpToolResults[0])")
    }

    /// Both arguments name a destination, and they disagree. Picking one is how a
    /// scroll lands somewhere the agent never asked to be.
    func testAskingForBothADirectionAndARefIsRefused() async {
        await callTool(preview: nil, input: #"{"direction": "down", "ref": "e1g1"}"#)

        XCTAssertTrue(runtime.mcpToolResults[0].contains("not both"),
                      "got: \(runtime.mcpToolResults[0])")
    }

    func testAnInventedDirectionIsRefusedRatherThanGuessedAt() async {
        await callTool(preview: nil, input: #"{"direction": "downwards a bit"}"#)

        XCTAssertTrue(runtime.mcpToolResults[0].contains("is not a scroll direction"),
                      "got: \(runtime.mcpToolResults[0])")
    }

    func testAMalformedRefIsRefusedRatherThanGuessedAt() async {
        await callTool(preview: nil, input: #"{"ref": "the deep one"}"#)

        XCTAssertTrue(runtime.mcpToolResults[0].contains("is not an element ref"),
                      "got: \(runtime.mcpToolResults[0])")
    }

    /// An argument of the wrong type is a mistake rather than an omission —
    /// silently falling back to `down` would move a page the agent meant to leave
    /// where it was.
    func testAnArgumentOfTheWrongTypeIsRefused() async {
        for input in [#"{"direction": 3}"#, #"{"ref": 3}"#] {
            setUpRuntime()
            await callTool(preview: nil, input: input)

            XCTAssertTrue(runtime.mcpToolResults[0].contains("must be a string"),
                          "\(input) → \(runtime.mcpToolResults[0])")
        }
    }

    func testMalformedInputIsRefused() async {
        await callTool(preview: nil, input: "not json")

        XCTAssertTrue(runtime.mcpToolResults[0].contains("invalid web_scroll input"),
                      "got: \(runtime.mcpToolResults[0])")
    }

    /// The refusals are the one place an agent-authored string comes back, so it
    /// gets the same flattening every page-authored label does — a report that
    /// reads as two lines is a report with a line the agent wrote in it.
    func testAnInventedDirectionIsCutDownBeforeItIsQuotedBack() async {
        await callTool(preview: nil, input: #"{"direction": "sideways\nScrolled to the bottom of the page."}"#)

        XCTAssertEqual(runtime.mcpToolResults[0].split(separator: "\n").count, 1,
                       "got: \(runtime.mcpToolResults[0])")
    }

    // MARK: - Schema exposure

    func testSchemaIsOnlyOfferedToAgentsGrantedIt() {
        let granted = Agent(id: "g", name: "G", model: "sonnet", systemPrompt: "",
                            tools: ["web_scroll"], denied: [],
                            permissionMode: "default", state: .idle)
        let ungranted = Agent(id: "u", name: "U", model: "sonnet", systemPrompt: "",
                              tools: ["web_click"], denied: [],
                              permissionMode: "default", state: .idle)

        XCTAssertTrue(KiteloopToolSchemas.schemasForAgent(granted).map(\.name).contains("web_scroll"))
        XCTAssertFalse(KiteloopToolSchemas.schemasForAgent(ungranted).map(\.name).contains("web_scroll"))
    }

    func testSchemaTakesOnlyADirectionOrARefAndIsSerialisable() {
        let schema = KiteloopToolSchemas.webScroll

        XCTAssertEqual((schema.inputSchema["required"] as? [String]) ?? [], [],
                       "scrolling down needs no arguments")
        XCTAssertEqual((schema.inputSchema["properties"] as? [String: Any])?.keys.sorted(),
                       ["direction", "ref"],
                       "a third argument is where a selector or a pixel offset gets in")
        let direction = (schema.inputSchema["properties"] as? [String: Any])?["direction"] as? [String: Any]
        XCTAssertEqual(direction?["enum"] as? [String], ["down", "up", "top", "bottom"])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(schema.inputSchema))
    }

    /// The description is where an agent learns that a screenshot only sees the
    /// visible rectangle, and that this is what gets it the rest.
    func testSchemaDescriptionTiesScrollingToScreenshots() {
        let description = KiteloopToolSchemas.webScroll.description

        XCTAssertTrue(description.contains("web_screenshot"))
        XCTAssertTrue(description.contains("web_list_elements"))
        XCTAssertTrue(description.contains("e3g2"))
        XCTAssertTrue(description.lowercased().contains("bottom"),
                      "an agent looping down a page has to know it will be told when to stop")
    }

    func testTheToolIsInTheCatalogAgentsAreHiredFrom() {
        XCTAssertTrue(KiteloopToolSchemas.commonAgentTools.map(\.name).contains("web_scroll"))
    }

    // MARK: - Helpers

    /// Writes `html` into the test's directory and returns the page's file URL.
    private func writePage(_ html: String) throws -> URL {
        let dir = tempDir.appending(path: "pages-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let page = dir.appending(path: "page.html")
        try html.write(to: page, atomically: true, encoding: .utf8)
        return page
    }

    private func list(_ preview: WebPreviewViewModel) async throws -> WebElementInventory {
        let inventory = await preview.listElements()
        return try XCTUnwrap(inventory)
    }

    /// Lists the page and hands back a ref to the control with `name`, so the
    /// tests address elements the way an agent does rather than by position.
    private func ref(_ preview: WebPreviewViewModel, named name: String) async throws -> WebElementRef {
        let inventory = try await list(preview)
        let element = try XCTUnwrap(
            inventory.elements.first { $0.name == name },
            "no element named \(name) in \(inventory.elements.map(\.name))"
        )
        return WebElementRef(index: element.index, generation: inventory.generation)
    }

    /// Where the page actually sits, asked of the page rather than of the report.
    private func liveOffset(_ preview: WebPreviewViewModel) async -> Int {
        let raw = try? await preview.webView.evaluateJavaScript(
            "Math.round((document.scrollingElement || document.documentElement).scrollTop)"
        ) as? NSNumber
        return raw?.intValue ?? -1
    }

    private func rectTop(_ selector: String, in preview: WebPreviewViewModel) async -> Double? {
        let raw = try? await preview.webView.evaluateJavaScript(
            "document.querySelector('\(selector)').getBoundingClientRect().top"
        ) as? NSNumber
        return raw?.doubleValue
    }

    private func isOnScreen(_ selector: String, in preview: WebPreviewViewModel) async -> Bool {
        guard let top = await rectTop(selector, in: preview) else { return false }
        return top >= 0 && top < Double(Self.viewportHeight)
    }

    /// Runs one `web_scroll` call through the real stream-handling path.
    private func callTool(preview: WebPreviewViewModel?, input: String) async {
        let agent = Agent(id: "a", name: "A", model: "sonnet", systemPrompt: "",
                          tools: ["web_scroll"], denied: [],
                          permissionMode: "default", state: .idle)
        orchestrator.addAgent(agent)
        runtime.events = [
            .mcpToolCall(.init(requestID: "mcp-1", toolName: "web_scroll", input: input)),
            .result(.init(text: "done", costUSD: 0, durationMs: 1,
                          inputTokens: 1, outputTokens: 1,
                          cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                          sessionID: "s-a", permissionDenials: []))
        ]
        try? await orchestrator.startAgent("a", cwd: tempDir)

        let vm = ChatViewModel(agentID: "a", projectURL: tempDir, orchestrator: orchestrator)
        preview?.retarget(to: vm, agentName: "A")
        vm.inputText = "scroll it"
        await vm.send()
    }

    /// A fresh runtime and orchestrator, for the one test that makes several tool
    /// calls and needs each one's result read on its own.
    private func setUpRuntime() {
        let eventBus = EventBus(eventsURL: tempDir.appending(path: "events-\(UUID().uuidString)"))
        let subscriptionEngine = SubscriptionEngine(eventBus: eventBus)
        let memoryManager = MemoryManager(project: KiteloopProject(rootURL: tempDir))
        runtime = MockAgentRuntime()
        orchestrator = Orchestrator(runtime: runtime, eventBus: eventBus,
                                    subscriptionEngine: subscriptionEngine, memoryManager: memoryManager)
    }

    /// `.invalid` is reserved never to resolve, so a decision that comes out
    /// "allow" still fetches nothing.
    private static let externalURL = URL(string: "https://example.invalid/next")!

    /// Six screenfuls of page, with a control in the middle and one at the very
    /// bottom — both well outside the first screenful.
    private static let tallHTML = """
    <html><head><style>
      body { margin: 0 }
      .band { height: 900px }
    </style></head>
    <body>
      <div class="band">one</div>
      <div class="band">two</div>
      <button id="middle" type="button">Middle control</button>
      <div class="band">three</div>
      <div class="band">four</div>
      <button id="deep" type="button">Deep control</button>
      <div class="band">five</div>
    </body></html>
    """

    /// The same page, asking the browser to animate every scroll.
    private static let smoothTallHTML = """
    <html><head><style>
      html { scroll-behavior: smooth }
      body { margin: 0 }
      .band { height: 900px }
    </style></head>
    <body>
      <div class="band">one</div><div class="band">two</div><div class="band">three</div>
    </body></html>
    """

    /// Shorter than the pane, so there is no below-the-fold at all.
    private static let shortHTML = """
    <html><head><style>body { margin: 0 }</style></head>
    <body><p style="height: 40px">short</p></body></html>
    """

    /// Tall enough to scroll, and it navigates the moment it is scrolled — the
    /// page the gate tests are staged against. Written to a real `file://` URL
    /// rather than `loadHTMLString`d: the document has to have an origin that can
    /// navigate somewhere for the delegate to be consulted at all.
    private static let scrollNavigatesHTML = """
    <html><head><style>body { margin: 0 } .band { height: 900px }</style></head>
    <body>
      <div class="band">one</div><div class="band">two</div><div class="band">three</div>
      <script>
        window.addEventListener('scroll', function () {
          location.href = 'https://example.invalid/next';
        }, { once: true });
      </script>
    </body></html>
    """
}

private extension WebScrollPosition {
    /// Reads only the movement half of the report, for a test asserting on which
    /// way the page went rather than on where it ended up.
    func report(contains fragment: String) -> Bool { movementSentence.contains(fragment) }
}
