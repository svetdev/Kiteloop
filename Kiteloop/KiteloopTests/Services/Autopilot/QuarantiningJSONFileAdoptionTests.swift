import XCTest
import KiteloopCore
@testable import Kiteloop

/// `QuarantiningJSONFile` adopted by `GlobalConfigStore`: an unreadable config
/// is moved aside rather than destroyed, and a later save does not touch the
/// evidence. The quarantine itself is package code, tested beside it.
final class QuarantiningJSONFileAdoptionTests: XCTestCase {
    private var tempDir: URL!
    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = try makeTemporaryDirectory(prefix: "quarantining-json")
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    private func makeInbox(_ name: String = "inbox") -> NotificationStore {
        NotificationStore(notificationsURL: tempDir.appending(path: "\(name).log"))
    }

    private func quarantined(besides url: URL) throws -> [URL] {
        let prefix = "\(url.lastPathComponent).unreadable-"
        return try FileManager.default
            .contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - Adoption: GlobalConfigStore

    @MainActor
    func testGlobalConfigStoreKeepsAConfigItCannotDecode() async throws {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)
        let url = tempDir.appending(path: "global-config.json")
        let original = Data(#"{"knowledgeRepoPath": "/tmp/knowl"#.utf8)
        try original.write(to: url)

        let store = GlobalConfigStore(storageURL: url, reporter: reporter)
        await reporter.drain()

        // Starting fresh is still the only thing the store can do — what changed
        // is that the bytes it could not read are still on disk.
        XCTAssertNil(store.config.knowledgeRepoPath)
        let aside = try quarantined(besides: url)
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(aside.first)), original)
        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.title, "Could not read Settings")
    }

    /// The save that used to destroy the evidence. It now lands on a path nothing
    /// occupies, and the quarantined copy is untouched by it.
    @MainActor
    func testASaveAfterQuarantineDoesNotTouchTheQuarantinedFile() async throws {
        let reporter = StoreProblemReporter(notifications: makeInbox())
        let url = tempDir.appending(path: "global-config.json")
        let original = Data("}{ not a config".utf8)
        try original.write(to: url)

        let store = GlobalConfigStore(storageURL: url, reporter: reporter)
        store.setDefaultModel("claude-opus-5")
        await reporter.drain()

        let aside = try XCTUnwrap(try quarantined(besides: url).first)
        XCTAssertEqual(try Data(contentsOf: aside), original)
        XCTAssertTrue(exists(url))
        let rewritten = try JSONDecoder().decode(GlobalConfig.self, from: try Data(contentsOf: url))
        XCTAssertEqual(rewritten.defaultModel, "claude-opus-5")
    }

    @MainActor
    func testGlobalConfigStoreLoadsAReadableConfigExactlyAsBefore() async throws {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)
        let url = tempDir.appending(path: "global-config.json")
        var written = GlobalConfig()
        written.knowledgeRepoPath = "/tmp/knowledge"
        written.defaultModel = "claude-opus-5"
        written.controlServerPort = 4517
        try JSONEncoder().encode(written).write(to: url)

        let store = GlobalConfigStore(storageURL: url, reporter: reporter)
        await reporter.drain()

        XCTAssertEqual(store.config.knowledgeRepoPath, "/tmp/knowledge")
        XCTAssertEqual(store.config.defaultModel, "claude-opus-5")
        XCTAssertEqual(store.config.controlServerPort, 4517)
        XCTAssertEqual(try quarantined(besides: url).count, 0)
        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 0)
    }
}
