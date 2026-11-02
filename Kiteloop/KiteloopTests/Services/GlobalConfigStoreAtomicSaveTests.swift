import XCTest
import KiteloopCore
@testable import Kiteloop

/// `~/.kiteloop/global-config.json` is the one file that has to survive a crash:
/// a truncated one decodes as an empty config, and the next setter writes that
/// emptiness back permanently. These tests pin the store to the durable writer
/// rather than to a plain `Data.write`.
@MainActor
final class GlobalConfigStoreAtomicSaveTests: XCTestCase {

    private var tempDir: URL!
    private var storageURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = try makeTemporaryDirectory(prefix: "global-config-atomic")
        storageURL = tempDir.appendingPathComponent("global-config.json")
    }

    override func tearDownWithError() throws {
        storageURL = nil
        tempDir = nil
        try super.tearDownWithError()
    }

    /// Every setter saves, so a writer that abandoned its drafts would litter
    /// `~/.kiteloop` with one file per settings change.
    func testSavingLeavesOnlyTheConfigFileBehind() throws {
        let store = GlobalConfigStore(storageURL: storageURL)
        store.setDefaultModel("claude-opus-5")
        store.setDefaultEffort("high")
        store.setKnowledgeRepoPath("/tmp/knowledge")

        let entries = try FileManager.default
            .contentsOfDirectory(atPath: tempDir.path(percentEncoded: false))
        XCTAssertEqual(entries, ["global-config.json"])
    }

    /// The replacement is a rename, so the destination must never be observed
    /// mid-write — and the JSON left there must always be decodable.
    func testEachSaveLeavesADecodableFile() throws {
        let store = GlobalConfigStore(storageURL: storageURL)

        for i in 0..<20 {
            store.setDefaultModel("model-\(i)")
            let data = try Data(contentsOf: storageURL)
            let decoded = try JSONDecoder().decode(GlobalConfig.self, from: data)
            XCTAssertEqual(decoded.defaultModel, "model-\(i)")
        }
    }

    /// The config can hold a Bedrock block and other backend details, so an
    /// install that tightened the file's permissions must keep them across saves.
    func testSavePreservesTightenedFilePermissions() throws {
        let store = GlobalConfigStore(storageURL: storageURL)
        store.setDefaultModel("claude-opus-5")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: storageURL.path(percentEncoded: false)
        )

        store.setDefaultEffort("high")

        let attributes = try FileManager.default
            .attributesOfItem(atPath: storageURL.path(percentEncoded: false))
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
    }

    /// A config file left truncated by an older, non-durable build must not stop
    /// the app from starting — it loads as defaults and is replaced on the next
    /// save.
    func testTruncatedConfigLoadsAsDefaultsAndIsReplaced() throws {
        try Data(#"{"defaultModel":"claude-op"#.utf8).write(to: storageURL)

        let store = GlobalConfigStore(storageURL: storageURL)
        XCTAssertNil(store.config.defaultModel)

        store.setDefaultModel("claude-opus-5")
        let reloaded = GlobalConfigStore(storageURL: storageURL)
        XCTAssertEqual(reloaded.config.defaultModel, "claude-opus-5")
    }
}
