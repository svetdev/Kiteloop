import AppKit
import XCTest
import KiteloopCore
@testable import Kiteloop

/// The pane records what the page writes to its console and the errors it
/// throws, so a blank dev page says why. These pin each level, the error
/// count, the caps, that a new page starts an empty list while an in-page
/// route change does not, and that the page's own console still works.
@MainActor
final class WebPreviewConsoleTests: XCTestCase {
    private func page(_ script: String) -> String {
        "<html><body><p>console</p><script>\(script)</script></body></html>"
    }

    /// Where a page is served from when a test needs an http origin — an
    /// uncaught error's details, an in-page route change.
    private let devServer = URL(string: "http://localhost:4173/")!

    func testConsoleErrorIsAnErrorEntryAndCounted() async throws {
        let preview = WebPreviewViewModel()
        try await load(page("console.error('boom');"), into: preview)

        try await eventually("the error arrives") { !preview.consoleEntries.isEmpty }
        XCTAssertEqual(preview.consoleEntries.map(\.level), [.error])
        XCTAssertEqual(preview.consoleEntries.first?.text, "boom")
        XCTAssertEqual(preview.consoleErrorCount, 1)
    }

    func testAnUncaughtExceptionIsAnErrorEntry() async throws {
        let preview = WebPreviewViewModel()
        try await load(page("throw new Error('kaput');"), servedFrom: devServer, into: preview)

        try await eventually("the exception arrives") { !preview.consoleEntries.isEmpty }
        let entry = try XCTUnwrap(preview.consoleEntries.first)
        XCTAssertEqual(entry.level, .error)
        XCTAssertTrue(entry.text.contains("kaput"), entry.text)
        XCTAssertEqual(preview.consoleErrorCount, 1)
    }

    func testAnUncaughtExceptionNamesItsScriptLineAndColumn() async throws {
        let preview = WebPreviewViewModel()
        try await load("<html><body>\n<p>thrower</p>\n<script>\n  throw new Error('located');\n</script>\n</body></html>",
                       servedFrom: devServer.appending(path: "thrower.html"), into: preview)

        try await eventually("the exception arrives") { !preview.consoleEntries.isEmpty }
        let entry = try XCTUnwrap(preview.consoleEntries.first)
        XCTAssertEqual(entry.level, .error)
        XCTAssertTrue(entry.text.contains("located"), entry.text)
        XCTAssertNotNil(
            entry.text.range(of: #"thrower\.html:4:\d+\)$"#, options: .regularExpression),
            "the entry ends with the throwing line: \(entry.text)"
        )
    }

    func testALoggedErrorIncludesItsStack() async throws {
        let preview = WebPreviewViewModel()
        try await load(page("function fail() { console.error(new Error('x')); } fail();"), into: preview)

        try await eventually("the error arrives") { !preview.consoleEntries.isEmpty }
        let text = try XCTUnwrap(preview.consoleEntries.first?.text)
        XCTAssertTrue(text.contains("x"), text)
        XCTAssertGreaterThan(text.components(separatedBy: "\n").count, 1, text)
    }

    func testALongStackIsCutToTheCap() async throws {
        let preview = WebPreviewViewModel()
        try await load(page("console.error(new Error('y'.repeat(50000)));"), into: preview)

        try await eventually("the error arrives") { !preview.consoleEntries.isEmpty }
        XCTAssertEqual(preview.consoleEntries.first?.text.count, WebPreviewViewModel.consoleTextLimit)
    }

    func testAnUnhandledRejectionIsAnErrorEntry() async throws {
        let preview = WebPreviewViewModel()
        try await load(page("Promise.reject(new Error('refused'));"), into: preview)

        try await eventually("the rejection arrives") { !preview.consoleEntries.isEmpty }
        let entry = try XCTUnwrap(preview.consoleEntries.first)
        XCTAssertEqual(entry.level, .error)
        XCTAssertTrue(entry.text.contains("refused"), entry.text)
    }

    func testLogAndWarnKeepTheirLevelsAndAreNotErrors() async throws {
        let preview = WebPreviewViewModel()
        try await load(page("console.log('hello', 42); console.warn('careful');"), into: preview)

        try await eventually("both lines arrive") { preview.consoleEntries.count == 2 }
        XCTAssertEqual(preview.consoleEntries.map(\.level), [.log, .warn])
        XCTAssertEqual(preview.consoleEntries.map(\.text), ["hello 42", "careful"])
        XCTAssertEqual(preview.consoleErrorCount, 0)
    }

    func testFormatSpecifiersAreFilledInFromTheArguments() async throws {
        let preview = WebPreviewViewModel()
        try await load(page("console.log('%s has %d items', 'cart', 3);"), into: preview)

        try await eventually("the line arrives") { preview.consoleEntries.count == 1 }
        XCTAssertEqual(preview.consoleEntries.map(\.text), ["cart has 3 items"])
    }

    func testAStyleSpecifierTakesItsArgumentAndPrintsNothing() async throws {
        let preview = WebPreviewViewModel()
        try await load(page("console.log('%cStyled', 'color: red');"), into: preview)

        try await eventually("the line arrives") { preview.consoleEntries.count == 1 }
        XCTAssertEqual(preview.consoleEntries.map(\.text), ["Styled"])
    }

    func testArgumentsLeftOverAfterTheSpecifiersAreAppended() async throws {
        let preview = WebPreviewViewModel()
        try await load(page("console.log('%s', 'a', 'b');"), into: preview)

        try await eventually("the line arrives") { preview.consoleEntries.count == 1 }
        XCTAssertEqual(preview.consoleEntries.map(\.text), ["a b"])
    }

    func testALonePercentStaysAndADoublePercentPrintsOne() async throws {
        let preview = WebPreviewViewModel()
        try await load(page("console.log('100%'); console.log('50%% off');"), into: preview)

        try await eventually("both lines arrive") { preview.consoleEntries.count == 2 }
        XCTAssertEqual(preview.consoleEntries.map(\.text), ["100%", "50% off"])
    }

    func testASpecifierWithNoArgumentLeftStaysLiteral() async throws {
        let preview = WebPreviewViewModel()
        try await load(page("console.log('%s and %s', 'only');"), into: preview)

        try await eventually("the line arrives") { preview.consoleEntries.count == 1 }
        XCTAssertEqual(preview.consoleEntries.map(\.text), ["only and %s"])
    }

    func testAnElementIsWrittenAsItsTagAndAttributes() async throws {
        let preview = WebPreviewViewModel()
        let script = "var el = document.createElement('div'); el.id = 'app'; el.textContent = 'hi'; console.log(el);"
        try await load(page(script), into: preview)

        try await eventually("the line arrives") { preview.consoleEntries.count == 1 }
        XCTAssertEqual(preview.consoleEntries.map(\.text), ["<div id=\"app\"></div>"])
    }

    func testAnElementThroughAnObjectSpecifierIsWrittenLikeABareOne() async throws {
        let preview = WebPreviewViewModel()
        let script = "var el = document.createElement('div'); el.id = 'app'; console.log('%o', el);"
        try await load(page(script), into: preview)

        try await eventually("the line arrives") { preview.consoleEntries.count == 1 }
        XCTAssertEqual(preview.consoleEntries.map(\.text), ["<div id=\"app\"></div>"])
    }

    func testAMapIsWrittenAsItsSizeAndEntries() async throws {
        let preview = WebPreviewViewModel()
        try await load(page("console.log(new Map([['a', 1]]));"), into: preview)

        try await eventually("the line arrives") { preview.consoleEntries.count == 1 }
        XCTAssertEqual(preview.consoleEntries.map(\.text), ["Map(1) {\"a\" => 1}"])
    }

    func testASetIsWrittenAsItsSizeAndValues() async throws {
        let preview = WebPreviewViewModel()
        try await load(page("console.log(new Set([1, 2]));"), into: preview)

        try await eventually("the line arrives") { preview.consoleEntries.count == 1 }
        XCTAssertEqual(preview.consoleEntries.map(\.text), ["Set(2) {1, 2}"])
    }

    func testAPlainObjectIsStillWrittenAsJSON() async throws {
        let preview = WebPreviewViewModel()
        try await load(page("console.log({a: 1});"), into: preview)

        try await eventually("the line arrives") { preview.consoleEntries.count == 1 }
        XCTAssertEqual(preview.consoleEntries.map(\.text), ["{\"a\":1}"])
    }

    func testInfoAndDebugKeepTheirLevelsAndAreNotErrors() async throws {
        let preview = WebPreviewViewModel()
        try await load(page("console.info('i'); console.debug('d');"), into: preview)

        try await eventually("both lines arrive") { preview.consoleEntries.count == 2 }
        XCTAssertEqual(preview.consoleEntries.map(\.level), [.info, .debug])
        XCTAssertEqual(preview.consoleEntries.map(\.text), ["i", "d"])
        XCTAssertEqual(preview.consoleErrorCount, 0)
    }

    func testANewPageEmptiesTheConsole() async throws {
        let preview = WebPreviewViewModel()
        try await load(page("console.error('old page');"), into: preview)
        try await eventually("the old page's error arrives") { preview.consoleErrorCount == 1 }

        try await load("<html><body><p>quiet</p></body></html>", into: preview)

        XCTAssertTrue(preview.consoleEntries.isEmpty)
        XCTAssertEqual(preview.consoleErrorCount, 0)
    }

    func testAPushStateKeepsTheConsole() async throws {
        let preview = WebPreviewViewModel()
        let dir = try makeTemporaryDirectory(prefix: "web-preview-console-tests")
        let file = dir.appending(path: "app.html")
        try page("console.error('before route');").write(to: file, atomically: true, encoding: .utf8)
        try await loadFile(file, into: preview)
        try await eventually("the error arrives") { preview.consoleErrorCount == 1 }

        _ = try await preview.webView.evaluateJavaScript("history.pushState(null, '', '#route'); 1")

        try await eventually("the route change is seen") { preview.currentURL?.fragment == "route" }
        XCTAssertEqual(preview.consoleEntries.map(\.text), ["before route"])
        XCTAssertEqual(preview.consoleErrorCount, 1)
    }

    func testOnlyTheNewestEntriesAreKept() async throws {
        let preview = WebPreviewViewModel()
        try await load(page("for (let i = 0; i < 250; i++) { console.log('line ' + i); }"), into: preview)

        try await eventually("the last line arrives") { preview.consoleEntries.last?.text == "line 249" }
        XCTAssertEqual(preview.consoleEntries.count, WebPreviewViewModel.consoleEntryLimit)
        XCTAssertEqual(preview.consoleEntries.first?.text, "line 50")
    }

    func testOverflowCountsTheDroppedLinesAndClearResetsIt() async throws {
        let preview = WebPreviewViewModel()
        try await load(page("for (let i = 0; i < 250; i++) { console.log('line ' + i); }"), into: preview)
        try await eventually("the last line arrives") { preview.consoleEntries.last?.text == "line 249" }

        XCTAssertEqual(preview.consoleEntries.count, 200)
        XCTAssertEqual(preview.consoleDroppedCount, 50)
        XCTAssertEqual(WebPreviewPanel.consoleDroppedTitle(droppedCount: preview.consoleDroppedCount), "50 earlier lines not kept")

        preview.clearConsole()

        XCTAssertEqual(preview.consoleDroppedCount, 0)
        XCTAssertNil(WebPreviewPanel.consoleDroppedTitle(droppedCount: preview.consoleDroppedCount))
    }

    func testCopyAfterAnOverflowStartsWithTheDroppedLine() async throws {
        let preview = WebPreviewViewModel()
        try await load(page("for (let i = 0; i < 250; i++) { console.log('line ' + i); }"), into: preview)
        try await eventually("the last line arrives") { preview.consoleEntries.last?.text == "line 249" }
        let pasteboard = NSPasteboard(name: .init("kiteloop.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        preview.copyConsole(to: pasteboard)

        let lines = try XCTUnwrap(pasteboard.string(forType: .string)).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 201)
        XCTAssertEqual(lines[0], "50 earlier lines not kept")
        XCTAssertTrue(lines[1].hasSuffix(" log line 50"), lines[1])
        XCTAssertTrue(lines[200].hasSuffix(" log line 249"), lines[200])
    }

    func testANewPageResetsTheDroppedCountAndAPushStateDoesNot() async throws {
        let preview = WebPreviewViewModel()
        try await load(page("for (let i = 0; i < 201; i++) { console.log('line ' + i); }"),
                       servedFrom: devServer, into: preview)
        try await eventually("the last line arrives") { preview.consoleEntries.last?.text == "line 200" }

        _ = try await preview.webView.evaluateJavaScript("history.pushState(null, '', '#route'); 1")
        try await eventually("the route change is seen") { preview.currentURL?.fragment == "route" }
        XCTAssertEqual(preview.consoleDroppedCount, 1)

        try await load("<html><body><p>quiet</p></body></html>", into: preview)

        XCTAssertEqual(preview.consoleDroppedCount, 0)
    }

    func testALineLoggedAtTheCapChangesTheFollowKeyButNotTheCount() async throws {
        let preview = WebPreviewViewModel()
        try await load(page("for (let i = 0; i < 200; i++) { console.log('line ' + i); }"), into: preview)
        try await eventually("the last line arrives") { preview.consoleEntries.last?.text == "line 199" }
        let before = WebPreviewPanel.consoleFollowKey(for: preview.consoleEntries)

        _ = try await preview.webView.evaluateJavaScript("console.log('line 200'); 1")

        try await eventually("the extra line arrives") { preview.consoleEntries.last?.text == "line 200" }
        XCTAssertEqual(preview.consoleEntries.count, WebPreviewViewModel.consoleEntryLimit)
        XCTAssertNotEqual(WebPreviewPanel.consoleFollowKey(for: preview.consoleEntries), before)
    }

    func testTheFollowKeyIsNilWhenEmptyAndTheNewestIdOtherwise() {
        XCTAssertNil(WebPreviewPanel.consoleFollowKey(for: []))
        let entries = [WebConsoleEntry(level: .log, text: "a"), WebConsoleEntry(level: .error, text: "b")]
        XCTAssertEqual(WebPreviewPanel.consoleFollowKey(for: entries), entries[1].id)
    }

    func testTheFirstLineAfterClearChangesTheFollowKey() async throws {
        let preview = WebPreviewViewModel()
        try await load(page("console.log('before');"), into: preview)
        try await eventually("the first line arrives") { !preview.consoleEntries.isEmpty }
        let before = WebPreviewPanel.consoleFollowKey(for: preview.consoleEntries)

        preview.clearConsole()
        XCTAssertNil(WebPreviewPanel.consoleFollowKey(for: preview.consoleEntries))
        _ = try await preview.webView.evaluateJavaScript("console.log('after'); 1")

        try await eventually("the later line arrives") { !preview.consoleEntries.isEmpty }
        XCTAssertNotNil(WebPreviewPanel.consoleFollowKey(for: preview.consoleEntries))
        XCTAssertNotEqual(WebPreviewPanel.consoleFollowKey(for: preview.consoleEntries), before)
    }

    func testTheDroppedLineIsDrawnOnlyOnceLinesWereDropped() {
        XCTAssertNil(WebPreviewPanel.consoleDroppedTitle(droppedCount: 0))
        XCTAssertEqual(WebPreviewPanel.consoleDroppedTitle(droppedCount: 1), "1 earlier line not kept")
        XCTAssertEqual(WebPreviewPanel.consoleDroppedTitle(droppedCount: 312), "312 earlier lines not kept")
    }

    func testAVeryLongMessageIsCutToTheCap() async throws {
        let preview = WebPreviewViewModel()
        try await load(page("console.log('x'.repeat(50000));"), into: preview)

        try await eventually("the message arrives") { !preview.consoleEntries.isEmpty }
        XCTAssertEqual(preview.consoleEntries.first?.text.count, WebPreviewViewModel.consoleTextLimit)
    }

    /// The capture script is run again over a spy standing in for the page's
    /// console, so the call-through is observed rather than assumed.
    func testTheWrapperCallsThroughToTheOriginal() async throws {
        let preview = WebPreviewViewModel()
        try await load("<html><body><p>spy</p></body></html>", into: preview)
        _ = try await preview.webView.evaluateJavaScript(
            "window.__calls = []; console.log = function () { __calls.push(Array.from(arguments).join('|')); }; 1"
        )
        _ = try await preview.webView.evaluateJavaScript(WebPreviewViewModel.consoleCaptureSource + "; 1")

        _ = try await preview.webView.evaluateJavaScript("console.log('a', 'b'); 1")

        let calls = try await preview.webView.evaluateJavaScript("__calls.join(',')") as? String
        XCTAssertEqual(calls, "a|b", "the page's own console.log still received the call")
        try await eventually("the pane recorded it too") { preview.consoleEntries.last?.text == "a b" }
    }

    func testAFailedAssertIsAnErrorEntryAndCounted() async throws {
        let preview = WebPreviewViewModel()
        try await load(page("console.assert(false, 'bad state');"), into: preview)

        try await eventually("the assertion arrives") { !preview.consoleEntries.isEmpty }
        XCTAssertEqual(preview.consoleEntries.map(\.level), [.error])
        let text = try XCTUnwrap(preview.consoleEntries.first?.text)
        XCTAssertTrue(text.hasPrefix("Assertion failed:"), text)
        XCTAssertTrue(text.contains("bad state"), text)
        XCTAssertEqual(preview.consoleErrorCount, 1)
    }

    func testAPassingAssertAddsNothing() async throws {
        let preview = WebPreviewViewModel()
        try await load(page("console.assert(true, 'fine'); console.log('sentinel');"), into: preview)

        try await eventually("the sentinel arrives") { !preview.consoleEntries.isEmpty }
        XCTAssertEqual(preview.consoleEntries.map(\.text), ["sentinel"])
        XCTAssertEqual(preview.consoleEntries.map(\.level), [.log])
        XCTAssertEqual(preview.consoleErrorCount, 0)
    }

    /// As above, over a spy standing in for the page's console.assert.
    func testTheAssertWrapperCallsThroughToTheOriginal() async throws {
        let preview = WebPreviewViewModel()
        try await load("<html><body><p>spy</p></body></html>", into: preview)
        _ = try await preview.webView.evaluateJavaScript(
            "window.__calls = []; console.assert = function () { __calls.push(Array.from(arguments).join('|')); }; 1"
        )
        _ = try await preview.webView.evaluateJavaScript(WebPreviewViewModel.consoleCaptureSource + "; 1")

        _ = try await preview.webView.evaluateJavaScript("console.assert(false, 'bad'); console.assert(true, 'ok'); 1")

        let calls = try await preview.webView.evaluateJavaScript("__calls.join(',')") as? String
        XCTAssertEqual(calls, "false|bad,true|ok", "the page's own console.assert still received both calls")
        try await eventually("the pane recorded the failure") { preview.consoleEntries.last?.text == "Assertion failed: bad" }
    }

    func testClearEmptiesTheListAndTheCount() async throws {
        let preview = WebPreviewViewModel()
        try await load(page("console.error('boom');"), into: preview)
        try await eventually("the error arrives") { preview.consoleErrorCount == 1 }

        preview.clearConsole()

        XCTAssertTrue(preview.consoleEntries.isEmpty)
        XCTAssertEqual(preview.consoleErrorCount, 0)
        XCTAssertEqual(WebPreviewPanel.consoleButtonTitle(errorCount: preview.consoleErrorCount), "Console")
    }

    func testAnErrorAfterClearIsTheOnlyEntry() async throws {
        let preview = WebPreviewViewModel()
        try await load(page("console.error('before');"), into: preview)
        try await eventually("the first error arrives") { preview.consoleErrorCount == 1 }

        preview.clearConsole()
        _ = try await preview.webView.evaluateJavaScript("console.error('after'); 1")

        try await eventually("the later error arrives") { !preview.consoleEntries.isEmpty }
        XCTAssertEqual(preview.consoleEntries.map(\.text), ["after"])
        XCTAssertEqual(preview.consoleErrorCount, 1)
    }

    func testCopyPutsOneLinePerEntryInOrder() async throws {
        let preview = WebPreviewViewModel()
        try await load(page("console.log('first'); console.warn('second'); console.error('third');"), into: preview)
        try await eventually("all three lines arrive") { preview.consoleEntries.count == 3 }
        let pasteboard = NSPasteboard(name: .init("kiteloop.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        preview.copyConsole(to: pasteboard)

        let lines = try XCTUnwrap(pasteboard.string(forType: .string)).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasSuffix(" log first"), lines[0])
        XCTAssertTrue(lines[1].hasSuffix(" warn second"), lines[1])
        XCTAssertTrue(lines[2].hasSuffix(" error third"), lines[2])
        XCTAssertEqual(lines.joined(separator: "\n"), WebPreviewViewModel.consoleText(for: preview.consoleEntries))
    }

    func testTheThresholdKeepsOnlyEntriesAtOrAboveItInOrder() {
        let entries = [
            WebConsoleEntry(level: .log, text: "l"),
            WebConsoleEntry(level: .error, text: "e1"),
            WebConsoleEntry(level: .debug, text: "d"),
            WebConsoleEntry(level: .warn, text: "w"),
            WebConsoleEntry(level: .info, text: "i"),
            WebConsoleEntry(level: .error, text: "e2"),
        ]
        func texts(_ threshold: WebPreviewViewModel.ConsoleThreshold) -> [String] {
            WebPreviewViewModel.consoleEntries(entries, at: threshold).map(\.text)
        }

        XCTAssertEqual(texts(.all), ["l", "e1", "d", "w", "i", "e2"])
        XCTAssertEqual(texts(.warnings), ["e1", "w", "e2"])
        XCTAssertEqual(texts(.errors), ["e1", "e2"])
    }

    func testCopyAtTheErrorsThresholdPutsOnlyTheErrorLines() async throws {
        let preview = WebPreviewViewModel()
        try await load(page("console.log('first'); console.error('second'); console.warn('third'); console.error('fourth');"), into: preview)
        try await eventually("all four lines arrive") { preview.consoleEntries.count == 4 }
        let pasteboard = NSPasteboard(name: .init("kiteloop.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        preview.copyConsole(to: pasteboard, threshold: .errors)

        let lines = try XCTUnwrap(pasteboard.string(forType: .string)).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix(" error second"), lines[0])
        XCTAssertTrue(lines[1].hasSuffix(" error fourth"), lines[1])
        XCTAssertEqual(preview.consoleErrorCount, 2)
    }

    func testTheButtonShowsTheErrorCountOnlyWhenThereAreErrors() {
        XCTAssertEqual(WebPreviewPanel.consoleButtonTitle(errorCount: 0), "Console")
        XCTAssertEqual(WebPreviewPanel.consoleButtonTitle(errorCount: 3), "Console (3)")
    }

    func testAConsoleReaderAtTheBottomFollowsNewLines() {
        XCTAssertEqual(WebPreviewPanel.consoleScrollAction(distanceFromBottom: 0), .follow)
    }

    func testTheConsoleBottomIsTheBottomWithinTheTolerance() {
        XCTAssertEqual(WebPreviewPanel.consoleScrollAction(distanceFromBottom: ChatView.atBottomTolerance), .follow)
        XCTAssertEqual(
            WebPreviewPanel.consoleScrollAction(distanceFromBottom: ChatView.atBottomTolerance.nextUp),
            .stayPut
        )
    }

    func testAConsoleReaderScrolledUpIsLeftWhereTheyAre() {
        XCTAssertEqual(WebPreviewPanel.consoleScrollAction(distanceFromBottom: 400), .stayPut)
    }

    /// A list shorter than the sheet reads as a negative distance — nothing to
    /// scroll, so the reader is at the bottom of it.
    func testAConsoleShorterThanItsSheetFollowsNewLines() {
        XCTAssertEqual(WebPreviewPanel.consoleScrollAction(distanceFromBottom: -120), .follow)
    }

    // MARK: - What the list says above its lines

    private func texts(_ notices: [WebPreviewPanel.ConsoleNotice]) -> [String] { notices.map(\.text) }

    func testAPageThatLoggedNothingSaysSo() {
        XCTAssertEqual(texts(WebPreviewPanel.consoleNotices(entries: [], shown: [], droppedCount: 0)),
                       ["This page has written nothing to its console."])
    }

    func testALevelThatHidesEveryLineSaysNothingAtThisLevel() {
        let log = WebConsoleEntry(level: .log, text: "hello")
        XCTAssertEqual(texts(WebPreviewPanel.consoleNotices(entries: [log], shown: [], droppedCount: 0)),
                       ["Nothing at this level was logged."])
    }

    func testLinesOnShowNeedNoNotice() {
        let log = WebConsoleEntry(level: .log, text: "hello")
        XCTAssertEqual(WebPreviewPanel.consoleNotices(entries: [log], shown: [log], droppedCount: 0), [])
    }

    func testDroppedLinesAreNamedAfterAnyEmptyNotice() {
        let log = WebConsoleEntry(level: .log, text: "hello")
        let notices = WebPreviewPanel.consoleNotices(entries: [log], shown: [], droppedCount: 50)
        XCTAssertEqual(texts(notices), ["Nothing at this level was logged.", "50 earlier lines not kept"])
        XCTAssertEqual(notices.last?.id, "web-preview-console-dropped")
    }
}
