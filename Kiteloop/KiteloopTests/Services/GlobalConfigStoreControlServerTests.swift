import XCTest
@testable import Kiteloop

/// The control server settings are the only ones that decide whether Kiteloop
/// opens a loopback socket at launch (`KiteloopApp` reads them straight from the
/// persisted config), so a lost or mistyped round-trip either silently disables
/// headless drive or reopens a port the user turned off. These tests pin the
/// set → save → load path down to the on-disk JSON.
@MainActor
final class GlobalConfigStoreControlServerTests: XCTestCase {

    private var tempDir: URL!
    private var storageURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = try makeTemporaryDirectory(prefix: "global-config-store")
        storageURL = tempDir.appendingPathComponent("global-config.json")
    }

    override func tearDownWithError() throws {
        storageURL = nil
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Round-trip

    func testSetControlServerUpdatesInMemoryConfig() {
        let store = GlobalConfigStore(storageURL: storageURL)
        store.setControlServer(enabled: true, port: 4517)

        XCTAssertEqual(store.config.controlServerEnabled, true)
        XCTAssertEqual(store.config.controlServerPort, 4517)
    }

    func testSetControlServerSurvivesReload() {
        GlobalConfigStore(storageURL: storageURL).setControlServer(enabled: true, port: 5150)

        let reloaded = GlobalConfigStore(storageURL: storageURL)
        XCTAssertEqual(reloaded.config.controlServerEnabled, true)
        XCTAssertEqual(reloaded.config.controlServerPort, 5150)
    }

    /// Disabling must persist as an explicit `false`, not as an absent key —
    /// `KiteloopApp` treats both as "off", but a dropped key would let a later
    /// merge or default resurrect the enabled state.
    func testDisablingPersistsExplicitFalse() throws {
        let store = GlobalConfigStore(storageURL: storageURL)
        store.setControlServer(enabled: true, port: 5150)
        store.setControlServer(enabled: false, port: 5150)

        let reloaded = GlobalConfigStore(storageURL: storageURL)
        XCTAssertEqual(reloaded.config.controlServerEnabled, false)
        XCTAssertEqual(reloaded.config.controlServerPort, 5150)

        let json = try decodedJSON()
        XCTAssertEqual(json["controlServerEnabled"] as? Bool, false)
    }

    func testLastWriteWins() {
        let store = GlobalConfigStore(storageURL: storageURL)
        store.setControlServer(enabled: true, port: 4517)
        store.setControlServer(enabled: true, port: 9001)

        let reloaded = GlobalConfigStore(storageURL: storageURL)
        XCTAssertEqual(reloaded.config.controlServerPort, 9001)
    }

    // MARK: - On-disk shape

    func testWritesExpectedJSONKeys() throws {
        GlobalConfigStore(storageURL: storageURL).setControlServer(enabled: true, port: 4517)

        let json = try decodedJSON()
        XCTAssertEqual(json["controlServerEnabled"] as? Bool, true)
        XCTAssertEqual(json["controlServerPort"] as? Int, 4517)
    }

    // MARK: - Isolation from other settings

    /// The store rewrites the whole file on every setter, so a control-server
    /// save must not drop unrelated settings — or enabling the control server
    /// would wipe the user's knowledge repo path.
    func testSavingControlServerPreservesOtherSettings() {
        let store = GlobalConfigStore(storageURL: storageURL)
        store.setDefaultModel("claude-opus-5")
        store.setDefaultEffort("high")
        store.setControlServer(enabled: true, port: 4517)

        let reloaded = GlobalConfigStore(storageURL: storageURL)
        XCTAssertEqual(reloaded.config.defaultModel, "claude-opus-5")
        XCTAssertEqual(reloaded.config.defaultEffort, "high")
        XCTAssertEqual(reloaded.config.controlServerEnabled, true)
        XCTAssertEqual(reloaded.config.controlServerPort, 4517)
    }

    /// Saving an unrelated setting after the control server was configured must
    /// carry the control-server fields along.
    func testSavingOtherSettingsPreservesControlServer() {
        let store = GlobalConfigStore(storageURL: storageURL)
        store.setControlServer(enabled: true, port: 4517)
        store.setKnowledgeRepoPath("/tmp/knowledge")

        let reloaded = GlobalConfigStore(storageURL: storageURL)
        XCTAssertEqual(reloaded.config.knowledgeRepoPath, "/tmp/knowledge")
        XCTAssertEqual(reloaded.config.controlServerEnabled, true)
        XCTAssertEqual(reloaded.config.controlServerPort, 4517)
    }

    // MARK: - Defaults

    /// A config file that predates the control server settings must decode with
    /// both fields nil, so the launch check falls back to "off".
    func testLegacyConfigWithoutControlServerKeysDecodesAsNil() throws {
        try Data(#"{"defaultModel":"claude-opus-5"}"#.utf8).write(to: storageURL)

        let store = GlobalConfigStore(storageURL: storageURL)
        XCTAssertEqual(store.config.defaultModel, "claude-opus-5")
        XCTAssertNil(store.config.controlServerEnabled)
        XCTAssertNil(store.config.controlServerPort)
    }

    func testFreshStoreHasNoControlServerSettings() {
        let store = GlobalConfigStore(storageURL: storageURL)
        XCTAssertNil(store.config.controlServerEnabled)
        XCTAssertNil(store.config.controlServerPort)
    }

    // MARK: - Port validation

    /// The Settings port field is the only writer of `controlServerPort`, and the
    /// launch path converts whatever it finds with `UInt16.init` — so an
    /// out-of-range value used to trap at startup. `resolvedPort` is what keeps a
    /// hand-edited or stale config from crashing the app.
    func testResolvedPortFallsBackWhenUnset() {
        XCTAssertEqual(KiteloopControlServer.resolvedPort(nil), KiteloopControlServer.defaultPort)
    }

    func testResolvedPortFallsBackOnOutOfRangeValues() {
        for bad in [-1, 0, 80, 1023, 65536, 999_999] {
            XCTAssertEqual(
                KiteloopControlServer.resolvedPort(bad),
                KiteloopControlServer.defaultPort,
                "port \(bad) must fall back instead of trapping or binding"
            )
        }
    }

    func testResolvedPortKeepsValuesInRange() {
        XCTAssertEqual(KiteloopControlServer.resolvedPort(1024), 1024)
        XCTAssertEqual(KiteloopControlServer.resolvedPort(5150), 5150)
        XCTAssertEqual(KiteloopControlServer.resolvedPort(65535), 65535)
    }

    func testIsValidPortMatchesTheAdvertisedRange() {
        XCTAssertFalse(KiteloopControlServer.isValidPort(1023))
        XCTAssertTrue(KiteloopControlServer.isValidPort(1024))
        XCTAssertTrue(KiteloopControlServer.isValidPort(65535))
        XCTAssertFalse(KiteloopControlServer.isValidPort(65536))
        XCTAssertTrue(KiteloopControlServer.isValidPort(Int(KiteloopControlServer.defaultPort)))
    }

    /// A config written by an older build (or by hand) can hold a port the app
    /// cannot bind; it must still load, and resolve to the default.
    func testPersistedOutOfRangePortResolvesToDefaultAtLaunch() throws {
        try Data(#"{"controlServerEnabled":true,"controlServerPort":80}"#.utf8).write(to: storageURL)

        let store = GlobalConfigStore(storageURL: storageURL)
        XCTAssertEqual(store.config.controlServerPort, 80)
        XCTAssertEqual(
            KiteloopControlServer.resolvedPort(store.config.controlServerPort),
            KiteloopControlServer.defaultPort
        )
    }

    // MARK: - Helpers

    private func decodedJSON() throws -> [String: Any] {
        let data = try Data(contentsOf: storageURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
