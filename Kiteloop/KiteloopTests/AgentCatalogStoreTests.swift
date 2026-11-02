import XCTest
import KiteloopCore
@testable import Kiteloop

final class AgentCatalogStoreTests: XCTestCase {
    var tempDir: URL!
    var store: AgentCatalogStore!

    // The async overload can carry actor isolation; synchronous setUp() cannot.
    @MainActor
    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "agent-catalog")
        store = AgentCatalogStore(storageURL: tempDir.appending(path: "catalog.json"))
    }

    @MainActor
    func testSeedsDefaults() {
        XCTAssertFalse(store.templates.isEmpty)
        XCTAssertEqual(store.templates.count, AgentTemplate.catalog.count)
    }

    @MainActor
    func testFindByHandle() {
        XCTAssertNotNil(store.find(handle: "coder"))
        XCTAssertNotNil(store.find(handle: "Coder"))  // case insensitive
        XCTAssertNil(store.find(handle: "nonexistent"))
    }

    @MainActor
    func testSearchByPrefix() {
        let results = store.search(prefix: "co")
        XCTAssertTrue(results.contains(where: { $0.name == "Coder" }))
    }

    @MainActor
    func testAddAndRemove() {
        let custom = AgentTemplate(
            id: "custom-1",
            name: "Custom Agent",
            model: "opus",
            systemPrompt: "You are custom.",
            tools: ["Read"],
            denied: [],
            permissionMode: "plan",
            description: "A custom agent"
        )
        store.add(custom)
        XCTAssertEqual(store.templates.count, AgentTemplate.catalog.count + 1)
        XCTAssertNotNil(store.find(handle: "custom-agent"))

        store.remove(id: "custom-1")
        XCTAssertEqual(store.templates.count, AgentTemplate.catalog.count)
        XCTAssertNil(store.find(handle: "custom-agent"))
    }

    @MainActor
    func testUpdate() {
        guard var template = store.find(handle: "coder") else {
            XCTFail("Coder not found")
            return
        }
        template.model = "opus"
        store.update(template)
        XCTAssertEqual(store.find(handle: "coder")?.model, "opus")
    }

    @MainActor
    func testPersistence() {
        let count = store.templates.count
        let store2 = AgentCatalogStore(storageURL: tempDir.appending(path: "catalog.json"))
        XCTAssertEqual(store2.templates.count, count)
    }

    @MainActor
    func testTemplateHandle() {
        let template = AgentTemplate(
            id: "t",
            name: "Prompt Tuner",
            model: "sonnet",
            systemPrompt: "",
            tools: [],
            denied: [],
            permissionMode: "plan",
            description: ""
        )
        XCTAssertEqual(store.templateHandle(for: template), "prompt-tuner")
    }

    // MARK: - A catalog file the decoder refuses

    /// The failure this pins: `load()` read a file it could not decode exactly
    /// like no file at all, `init` saw an empty `templates` and seeded, and the
    /// `save()` inside the seed wrote the built-in defaults straight over the
    /// user's catalog — every template they had added gone before the window
    /// opened, with nothing said.
    @MainActor
    func testAnUnreadableCatalogIsKeptAsideAndTheDefaultsStillCome() async throws {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)
        let url = tempDir.appending(path: "unreadable.json")
        let original = Data(#"[{"id": "mine-1", "name": "My Age"#.utf8)  // truncated mid-value
        try original.write(to: url)

        let store = AgentCatalogStore(storageURL: url, reporter: reporter)
        await reporter.drain()

        // The whole point: those exact bytes are still readable beside the
        // store's path, where the seed cannot land on them.
        let aside = try quarantined(besides: url)
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(aside.first)), original)
        // And the app still comes up with a working catalog, which is the only
        // thing it can do once the saved one is unreadable.
        XCTAssertEqual(store.templates.count, AgentTemplate.catalog.count)
        XCTAssertNotNil(store.find(handle: "coder"))
    }

    /// A silent rescue only moves the surprise later: the line has to name the
    /// store and the file that was kept.
    @MainActor
    func testAnUnreadableCatalogLogsOneLineNamingWhatWasKept() async throws {
        let reporter = StoreProblemReporter(notifications: makeInbox())
        let marker = "catalog-\(UUID().uuidString)"
        let url = tempDir.appending(path: "\(marker).json")
        try Data("not a catalog at all".utf8).write(to: url)

        _ = AgentCatalogStore(storageURL: url, reporter: reporter)
        await reporter.drain()

        let aside = try XCTUnwrap(try quarantined(besides: url).first)
        let lines = KiteloopFileLogger.shared.snapshot()
            .filter { $0.category == StoreProblemReporter.logCategory && $0.message.contains(marker) }
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.levelTag, "ERROR")
        XCTAssertEqual(lines.first?.message.contains(AgentCatalogStore.storeName), true)
        // By name rather than full path: `contentsOfDirectory` answers in the
        // canonicalized /private/var form while the line carries the caller's
        // /var form, and the quarantine filename is unique on its own.
        XCTAssertEqual(lines.first?.message.contains(aside.lastPathComponent), true)
    }

    /// First launch — the case the old `load()` collapsed the broken one into.
    /// It has to keep behaving exactly as it did.
    @MainActor
    func testNoCatalogFileSeedsTheDefaultsAndKeepsNothingAside() async throws {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)
        let url = tempDir.appending(path: "fresh.json")

        let store = AgentCatalogStore(storageURL: url, reporter: reporter)
        await reporter.drain()

        XCTAssertEqual(store.templates.count, AgentTemplate.catalog.count)
        let written = try JSONDecoder().decode([AgentTemplate].self, from: try Data(contentsOf: url))
        XCTAssertEqual(written.count, AgentTemplate.catalog.count)
        XCTAssertEqual(try quarantined(besides: url).count, 0)
        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 0)
    }

    @MainActor
    func testAReadableCatalogLoadsAndIsNeitherMovedNorOverwritten() async throws {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)
        let url = tempDir.appending(path: "readable.json")
        let original = try JSONEncoder().encode([AgentTemplate(id: "mine-1", name: "My Agent")])
        try original.write(to: url)

        let store = AgentCatalogStore(storageURL: url, reporter: reporter)
        await reporter.drain()

        XCTAssertEqual(store.templates.map(\.id), ["mine-1"])
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try quarantined(besides: url).count, 0)
        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 0)
    }

    /// The watcher's reload must *not* quarantine. A file being edited by hand
    /// is undecodable for as long as it takes to type the rest of it, and moving
    /// it out from under the editor is the same loss the launch read exists to
    /// prevent — so both the file and the loaded catalog are left as they are.
    ///
    /// The readable write first is the control: it proves the watcher is armed
    /// and delivering, so the silence after the broken one is the guard rather
    /// than a test watching nothing. Both writes are in place — not `.atomic` —
    /// since the store watches a descriptor on the file itself, and a replace
    /// would leave it watching the inode nobody writes to any more.
    @MainActor
    func testAnExternalEditThatNoLongerDecodesLeavesTheFileAndCatalogAlone() async throws {
        let reporter = StoreProblemReporter(notifications: makeInbox())
        let url = tempDir.appending(path: "watched.json")
        try JSONEncoder().encode([AgentTemplate(id: "first", name: "First")]).write(to: url)

        let store = AgentCatalogStore(storageURL: url, reporter: reporter)
        XCTAssertEqual(store.templates.map(\.id), ["first"])

        try JSONEncoder().encode([
            AgentTemplate(id: "first", name: "First"),
            AgentTemplate(id: "second", name: "Second")
        ]).write(to: url)
        try await eventually("the watcher to report the write") { @MainActor in
            store.templates.map(\.id) == ["first", "second"]
        }
        XCTAssertEqual(store.templates.map(\.id), ["first", "second"], "the watcher never reported the write")

        let broken = Data(#"[{"id": "first", "name""#.utf8)
        try broken.write(to: url)
        try await Task.sleep(for: .milliseconds(700))
        await reporter.drain()

        XCTAssertEqual(store.templates.map(\.id), ["first", "second"],
                       "a write that no longer decodes must not empty the loaded catalog")
        XCTAssertEqual(try Data(contentsOf: url), broken,
                       "the file a person may still be editing must be left where it is")
        XCTAssertEqual(try quarantined(besides: url).count, 0)
    }

    // MARK: - A write the durable writer cannot make

    /// `save()` used to write with a plain atomic `Data.write` wrapped in
    /// `try?`. A rename that is never flushed becomes a zero-length file on an
    /// unclean shutdown, which `init` reads as no templates at all and seeds
    /// the defaults over — and the discarded error meant a user whose disk was
    /// full kept adding a template and kept finding it gone.
    @MainActor
    func testAWriteThatCannotLandIsReportedAndTheTemplateStaysInMemory() async throws {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)
        // A regular file where the catalog's directory should be: the durable
        // writer creates that directory first, and cannot.
        let blocker = tempDir.appending(path: "blocked")
        try Data("not a directory".utf8).write(to: blocker)
        let storageURL = blocker.appending(path: "catalog.json")

        let store = AgentCatalogStore(storageURL: storageURL, reporter: reporter)
        let custom = AgentTemplate(id: "custom-1", name: "Custom Agent")
        store.add(custom)
        await reporter.drain()

        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.type, .error)
        XCTAssertEqual(pending.first?.title, "Could not write \(AgentCatalogStore.storeName)")
        XCTAssertEqual(pending.first?.body.contains(storageURL.path(percentEncoded: false)), true)

        // Reporting is all this does — the template the caller just added is
        // not undone, so the window still shows it.
        XCTAssertNotNil(store.find(handle: "custom-agent"))
    }

    /// A save that lands leaves only the catalog's own file behind, and it
    /// decodes back into what was saved.
    @MainActor
    func testASuccessfulSaveLeavesOnlyTheCatalogFileAndItDecodes() async throws {
        // Its own directory: setUp's store already persisted catalog.json
        // into tempDir, and this case asserts directory contents.
        let dir = tempDir.appending(path: "clean-store")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "clean.json")
        let store = AgentCatalogStore(storageURL: url)
        let custom = AgentTemplate(id: "custom-1", name: "Custom Agent")

        store.add(custom)

        let entries = try FileManager.default
            .contentsOfDirectory(atPath: dir.path(percentEncoded: false))
        XCTAssertEqual(entries, ["clean.json"])
        let decoded = try JSONDecoder().decode([AgentTemplate].self, from: try Data(contentsOf: url))
        XCTAssertEqual(decoded.map(\.id).sorted(), store.templates.map(\.id).sorted())
    }

    // MARK: - Helpers

    private func makeInbox() -> NotificationStore {
        NotificationStore(notificationsURL: tempDir.appending(path: "inbox-\(UUID().uuidString).log"))
    }

    /// The files sitting beside `url` that the store moved aside.
    private func quarantined(besides url: URL) throws -> [URL] {
        let prefix = "\(url.lastPathComponent).unreadable-"
        return try FileManager.default
            .contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
