import XCTest
import KiteloopCore
@testable import Kiteloop

/// `web_screenshot` hands the agent a *path*, not image bytes — so what matters
/// is where the PNG lands, that its name is stable and collision-free, and that
/// the tool refuses cleanly when there is nothing to capture.
@MainActor
final class WebScreenshotToolTests: XCTestCase {
    private var tempDir: URL!
    private var runtime: MockAgentRuntime!
    private var orchestrator: Orchestrator!

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "web-screenshot-tests")

        let eventBus = EventBus(eventsURL: tempDir.appending(path: "events"))
        let subscriptionEngine = SubscriptionEngine(eventBus: eventBus)
        let project = KiteloopProject(rootURL: tempDir)
        let memoryManager = MemoryManager(project: project)
        runtime = MockAgentRuntime()
        orchestrator = Orchestrator(runtime: runtime, eventBus: eventBus,
                                    subscriptionEngine: subscriptionEngine, memoryManager: memoryManager)
    }

    // MARK: - Where the file lands

    func testScreenshotIsWrittenUnderTheProjectWebDirectory() throws {
        let webDir = KiteloopProject(rootURL: tempDir).webURL
        let file = try WebPreviewViewModel.writeScreenshot(
            Self.png, into: webDir, for: URL(string: "http://localhost:3000/checkout"), at: Self.date
        )

        XCTAssertTrue(webDir.path(percentEncoded: false).hasSuffix("/.kiteloop/web"),
                      "screenshots belong in the gitignored .kiteloop/web/ scratch dir")
        XCTAssertTrue(file.path(percentEncoded: false).hasPrefix(webDir.path(percentEncoded: false) + "/"),
                      "expected a file inside \(webDir.path(percentEncoded: false)), got \(file.path(percentEncoded: false))")
        XCTAssertEqual(file.pathExtension, "png")
        XCTAssertEqual(try Data(contentsOf: file), Self.png)
    }

    func testWriteCreatesTheDirectoryIfItIsMissing() throws {
        let webDir = KiteloopProject(rootURL: tempDir).webURL
        XCTAssertFalse(FileManager.default.fileExists(atPath: webDir.path(percentEncoded: false)))

        _ = try WebPreviewViewModel.writeScreenshot(Self.png, into: webDir, for: nil, at: Self.date)

        XCTAssertTrue(FileManager.default.fileExists(atPath: webDir.path(percentEncoded: false)))
    }

    /// Each call returns its own path, so a second capture in the same second
    /// must not overwrite the image the agent was just told to read.
    func testTwoCapturesInTheSameSecondDoNotOverwriteEachOther() throws {
        let webDir = KiteloopProject(rootURL: tempDir).webURL
        let page = URL(string: "http://localhost:3000/")
        let first = try WebPreviewViewModel.writeScreenshot(Self.png, into: webDir, for: page, at: Self.date)
        let second = try WebPreviewViewModel.writeScreenshot(Self.other, into: webDir, for: page, at: Self.date)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: first), Self.png, "the first capture must survive the second")
        XCTAssertEqual(try Data(contentsOf: second), Self.other)
    }

    // MARK: - Naming

    func testFileNameCarriesThePageAndTheTimestamp() throws {
        let file = try WebPreviewViewModel.writeScreenshot(
            Self.png, into: tempDir, for: URL(string: "https://Example.COM/a/b"), at: Self.date
        )
        XCTAssertEqual(file.lastPathComponent, "example-com-20260805-142530.png")
    }

    func testSlugFallsBackToThePageKindItCanDescribe() {
        XCTAssertEqual(WebPreviewViewModel.pageSlug(URL(string: "http://localhost:3000/x")), "localhost")
        XCTAssertEqual(WebPreviewViewModel.pageSlug(URL(fileURLWithPath: "/tmp/My Page.html")), "my-page")
        XCTAssertEqual(WebPreviewViewModel.pageSlug(nil), "preview")
        XCTAssertEqual(WebPreviewViewModel.pageSlug(URL(string: "about:blank")), "preview",
                       "a hostless URL still has to yield a usable file name")
    }

    func testSlugIsFileNameSafeAndBounded() {
        let long = String(repeating: "section name ", count: 20)
        let slug = WebPreviewViewModel.pageSlug(URL(fileURLWithPath: "/tmp/\(long).html"))

        XCTAssertFalse(slug.contains("/"), "a separator in the slug would escape the web directory")
        XCTAssertFalse(slug.contains(" "))
        XCTAssertLessThanOrEqual(slug.count, 40)
    }

    // MARK: - Retention

    /// Nothing else empties `.kiteloop/web/`, so an unattended run that
    /// screenshots in a loop is what the cap exists to bound.
    func testCapturingPastTheCapLeavesOnlyTheNewestScreenshots() throws {
        let webDir = KiteloopProject(rootURL: tempDir).webURL
        let limit = WebPreviewViewModel.screenshotRetentionLimit
        var written: [URL] = []
        for i in 0..<(limit + 10) {
            let file = try WebPreviewViewModel.writeScreenshot(
                Self.png, into: webDir, for: URL(string: "http://localhost:3000/"),
                at: Self.date.addingTimeInterval(TimeInterval(i))
            )
            // Backdate after the write so the *next* capture is unambiguously
            // the newest file, whatever the wall clock says when this runs.
            try age(file, to: Self.ancient.addingTimeInterval(TimeInterval(i)))
            written.append(file)
        }

        let remaining = try Self.pngs(in: webDir)
        XCTAssertEqual(remaining.count, limit,
                       "the web scratch dir must stay bounded no matter how many captures a run takes")
        XCTAssertEqual(Set(remaining), Set(written.suffix(limit).map(\.lastPathComponent)),
                       "the newest \(limit) captures are the ones worth keeping")
        for gone in written.prefix(10) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: gone.path(percentEncoded: false)),
                           "\(gone.lastPathComponent) is past the cap and should have been pruned")
        }
    }

    /// The path a capture just handed the agent has to still be there when the
    /// agent `Read`s it — pruning must never take the newest file.
    func testTheCaptureThatTriggersThePruneSurvivesIt() throws {
        let webDir = KiteloopProject(rootURL: tempDir).webURL
        try seed(count: WebPreviewViewModel.screenshotRetentionLimit, in: webDir)

        let file = try WebPreviewViewModel.writeScreenshot(
            Self.other, into: webDir, for: URL(string: "http://localhost:3000/"), at: Self.date
        )

        XCTAssertEqual(try Data(contentsOf: file), Self.other)
        XCTAssertEqual(try Self.pngs(in: webDir).count, WebPreviewViewModel.screenshotRetentionLimit)
    }

    func testPruningLeavesNonScreenshotFilesAlone() throws {
        let webDir = KiteloopProject(rootURL: tempDir).webURL
        try seed(count: 5, in: webDir)
        let note = webDir.appending(path: "notes.txt")
        try Data("keep me".utf8).write(to: note)

        WebPreviewViewModel.pruneScreenshots(in: webDir, keeping: 2)

        XCTAssertEqual(try Self.pngs(in: webDir).count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: note.path(percentEncoded: false)),
                      "the cap counts screenshots — it is not licence to empty the directory")
    }

    func testPruningADirectoryUnderTheCapChangesNothing() throws {
        let webDir = KiteloopProject(rootURL: tempDir).webURL
        try seed(count: 3, in: webDir)

        WebPreviewViewModel.pruneScreenshots(in: webDir, keeping: 10)
        WebPreviewViewModel.pruneScreenshots(in: tempDir.appending(path: "never-created"), keeping: 10)

        XCTAssertEqual(try Self.pngs(in: webDir).count, 3)
    }

    // MARK: - Reachability (driven through the real MCP tool-call path)

    func testScreenshotIsRefusedWithoutAnAttachedPane() async {
        let vm = await screenshot(preview: nil)

        XCTAssertNil(vm.webPreview)
        XCTAssertEqual(runtime.mcpToolResults.count, 1)
        XCTAssertTrue(runtime.mcpToolResults[0].contains("no web preview pane is attached"),
                      "an unselected agent has no pane to capture — got: \(runtime.mcpToolResults[0])")
    }

    func testScreenshotIsRefusedWhenNoPageIsLoaded() async {
        let preview = WebPreviewViewModel()
        _ = await screenshot(preview: preview)

        XCTAssertNil(preview.currentURL)
        XCTAssertEqual(runtime.mcpToolResults.count, 1)
        XCTAssertTrue(runtime.mcpToolResults[0].contains("web_navigate"),
                      "an empty pane should point the agent at web_navigate rather than write a blank PNG — got: \(runtime.mcpToolResults[0])")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: KiteloopProject(rootURL: tempDir).webURL.path(percentEncoded: false)),
            "a refused capture must not leave a stray directory behind")
    }

    // MARK: - Schema exposure

    func testSchemaIsOnlyOfferedToAgentsGrantedTheTool() {
        let granted = Agent(id: "g", name: "G", model: "sonnet", systemPrompt: "",
                            tools: ["web_screenshot"], denied: [],
                            permissionMode: "default", state: .idle)
        let ungranted = Agent(id: "u", name: "U", model: "sonnet", systemPrompt: "",
                              tools: ["web_navigate"], denied: [],
                              permissionMode: "default", state: .idle)

        XCTAssertTrue(KiteloopToolSchemas.schemasForAgent(granted).contains { $0.name == "web_screenshot" })
        XCTAssertFalse(KiteloopToolSchemas.schemasForAgent(ungranted).contains { $0.name == "web_screenshot" })
    }

    func testSchemaTakesNoArguments() {
        let schema = KiteloopToolSchemas.webScreenshot
        XCTAssertEqual(schema.name, "web_screenshot")
        XCTAssertEqual(schema.inputSchema["required"] as? [String], [])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(schema.inputSchema))
    }

    // MARK: - Helpers

    /// Runs one `web_screenshot` call through the real stream-handling path.
    private func screenshot(preview: WebPreviewViewModel?) async -> ChatViewModel {
        let agent = Agent(id: "a", name: "A", model: "sonnet",
                          systemPrompt: "", tools: ["web_screenshot"], denied: [],
                          permissionMode: "default", state: .idle)
        orchestrator.addAgent(agent)
        runtime.events = [
            .mcpToolCall(.init(requestID: "mcp-1", toolName: "web_screenshot", input: "{}")),
            .result(.init(text: "done", costUSD: 0, durationMs: 1,
                          inputTokens: 1, outputTokens: 1,
                          cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                          sessionID: "s-a", permissionDenials: []))
        ]
        try? await orchestrator.startAgent("a", cwd: tempDir)

        let vm = ChatViewModel(agentID: "a", projectURL: tempDir, orchestrator: orchestrator)
        preview?.retarget(to: vm, agentName: "A")
        vm.inputText = "screenshot the page"
        await vm.send()
        return vm
    }

    /// Writes `count` PNGs with distinct, ascending modification dates, oldest
    /// first — so a prune has an unambiguous notion of which ones are stale.
    private func seed(count: Int, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for i in 0..<count {
            let file = directory.appending(path: "seed-\(i).png")
            try Self.png.write(to: file)
            try age(file, to: Self.ancient.addingTimeInterval(TimeInterval(i)))
        }
    }

    /// Stamps a file's modification date — what the prune orders by, and the
    /// only way to make ordering deterministic when a test writes faster than
    /// the file system's clock resolution.
    private func age(_ file: URL, to date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date],
                                              ofItemAtPath: file.path(percentEncoded: false))
    }

    private static func pngs(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
            .filter { $0.hasSuffix(".png") }
    }

    private static let date = Calendar(identifier: .gregorian).date(
        from: DateComponents(year: 2026, month: 8, day: 5, hour: 14, minute: 25, second: 30)
    )!
    /// Far enough in the past that a freshly written file is always newer,
    /// whatever the wall clock reads when the suite runs.
    private static let ancient = Date(timeIntervalSince1970: 1_000_000_000)
    private static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01])
    private static let other = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x02])
}
