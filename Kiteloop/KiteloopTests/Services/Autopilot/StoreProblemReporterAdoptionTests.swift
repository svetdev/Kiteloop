import XCTest
import KiteloopCore
@testable import Kiteloop

/// `StoreProblemReporter` adopted by a store the app owns — `GlobalConfigStore`
/// reporting the write it could not make, once per store rather than once per
/// setter. The reporter itself is package code, tested beside it.
final class StoreProblemReporterAdoptionTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = try makeTemporaryDirectory(prefix: "store-problem-adoption")
    }

    private func makeInbox(_ name: String = "inbox") -> NotificationStore {
        NotificationStore(notificationsURL: tempDir.appending(path: "\(name).log"))
    }

    // MARK: - Adoption: GlobalConfigStore

    /// `save()` used to discard its write error at a `try?`. Every setter saves,
    /// so a config that has stopped saving looks exactly like one nobody changed.
    @MainActor
    func testGlobalConfigStoreReportsAWriteItCouldNotMake() async throws {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)
        // A regular file where the config's directory should be: the durable
        // writer creates that directory first, and cannot.
        let blocker = tempDir.appending(path: "blocked")
        try Data("not a directory".utf8).write(to: blocker)
        let storageURL = blocker.appending(path: "global-config.json")

        let store = GlobalConfigStore(storageURL: storageURL, reporter: reporter)
        store.setDefaultModel("claude-opus-5")
        await reporter.drain()

        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.type, .error)
        XCTAssertEqual(pending.first?.title, "Could not write Settings")
        XCTAssertEqual(pending.first?.body.contains(storageURL.path(percentEncoded: false)), true)
    }

    /// One row for the store, not one per setter — an unwritable config is a
    /// single problem, and the app writes it on every settings change.
    @MainActor
    func testGlobalConfigStoreKeepsOneRowAcrossManyFailedSaves() async throws {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)
        let blocker = tempDir.appending(path: "blocked")
        try Data("not a directory".utf8).write(to: blocker)

        let store = GlobalConfigStore(storageURL: blocker.appending(path: "global-config.json"),
                                      reporter: reporter)
        store.setDefaultModel("claude-opus-5")
        store.setDefaultEffort("high")
        store.setKnowledgeRepoPath("/tmp/knowledge")
        await reporter.drain()

        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 1)
    }

    @MainActor
    func testGlobalConfigStoreReportsNothingWhenTheSaveSucceeds() async {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)

        let store = GlobalConfigStore(storageURL: tempDir.appending(path: "global-config.json"),
                                      reporter: reporter)
        store.setDefaultModel("claude-opus-5")
        await reporter.drain()

        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 0)
    }
}
