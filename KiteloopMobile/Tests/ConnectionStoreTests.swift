import Security
import XCTest
@testable import KiteloopMobile

final class ConnectionStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    /// The keychain, in memory: account → token.
    private var keychain: [String: String] = [:]

    override func setUp() {
        super.setUp()
        suiteName = "ConnectionStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        keychain = [:]
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeStore(status: OSStatus = errSecSuccess) -> ConnectionStore {
        let store = ConnectionStore(defaults: defaults, tokenReader: { [unowned self] in keychain[$0] })
        store.tokenWriter = { [unowned self] account, value in
            if status == errSecSuccess { keychain[account] = value }
            return status
        }
        store.tokenDeleter = { [unowned self] in keychain[$0] = nil }
        return store
    }

    func testConfiguredIsFalseWhenBaseURLIsEmpty() {
        let store = makeStore()
        store.baseURL = ""
        store.token = "a-token"

        XCTAssertFalse(store.configured)
    }

    func testConfiguredIsFalseWhenTokenIsEmpty() {
        let store = makeStore()
        store.baseURL = "http://100.1.1.1:8787"
        store.token = ""

        XCTAssertFalse(store.configured)
    }

    func testConfiguredIsTrueOnlyWhenBothAreSet() {
        let store = makeStore()
        store.baseURL = "http://100.1.1.1:8787"
        store.token = "a-token"

        XCTAssertTrue(store.configured)
    }

    func testTokenStoreProblemIsSetWhenWriterRefuses() {
        let store = makeStore(status: errSecInteractionNotAllowed)
        store.baseURL = "http://100.1.1.1:8787"
        store.token = "a-token"

        XCTAssertNotNil(store.tokenStoreProblem)
        XCTAssertTrue(store.tokenStoreProblem?.contains("\(errSecInteractionNotAllowed)") ?? false)
        XCTAssertTrue(store.configured)
    }

    func testTokenStoreProblemIsNilWhenWriterSucceeds() {
        let store = makeStore()
        store.token = "a-token"

        XCTAssertNil(store.tokenStoreProblem)
    }

    func testTokenStoreProblemClearsAfterSuccessFollowingRefusal() {
        let store = makeStore()
        store.tokenWriter = { _, _ in errSecInteractionNotAllowed }
        store.token = "a-token"
        XCTAssertNotNil(store.tokenStoreProblem)

        store.tokenWriter = { _, _ in errSecSuccess }
        store.token = "another-token"

        XCTAssertNil(store.tokenStoreProblem)
    }

    func testAPhonePairedBeforeThereWereSeveralMacsOpensOnTheSameMac() {
        defaults.set("http://100.1.1.1:4517", forKey: ConnectionStore.legacyURLKey)
        keychain[ConnectionStore.legacyTokenAccount] = "old-token"

        let store = makeStore()

        XCTAssertEqual(store.macs.count, 1)
        XCTAssertEqual(store.baseURL, "http://100.1.1.1:4517")
        XCTAssertEqual(store.token, "old-token")
        XCTAssertTrue(store.configured)
    }

    func testPairingASecondMacKeepsTheFirstAndMakesTheNewOneCurrent() {
        let store = makeStore()
        store.pair(baseURL: "http://100.1.1.1:4517", token: "home", name: "Studio")
        store.pair(baseURL: "http://100.2.2.2:4517", token: "work", name: "Work MacBook")

        XCTAssertEqual(store.macs.map(\.name), ["Studio", "Work MacBook"])
        XCTAssertEqual(store.current?.name, "Work MacBook")
        XCTAssertEqual(store.token, "work")

        store.select(store.macs[0].id)
        XCTAssertEqual(store.baseURL, "http://100.1.1.1:4517")
        XCTAssertEqual(store.token, "home")
    }

    func testPairingTheSameMacAgainUpdatesItsTokenWithoutADuplicate() {
        let store = makeStore()
        store.pair(baseURL: "http://100.1.1.1:4517", token: "first")
        store.pair(baseURL: "http://100.1.1.1:4517/", token: "rotated")

        XCTAssertEqual(store.macs.count, 1)
        XCTAssertEqual(store.token, "rotated")
        XCTAssertEqual(keychain[store.macs[0].tokenAccount], "rotated")
    }

    func testRemovingAMacRemovesItsKeychainToken() {
        let store = makeStore()
        store.pair(baseURL: "http://100.1.1.1:4517", token: "home")
        store.pair(baseURL: "http://100.2.2.2:4517", token: "work")
        let work = store.macs[1]

        store.remove(work.id)

        XCTAssertNil(keychain[work.tokenAccount])
        XCTAssertEqual(store.macs.count, 1)
        XCTAssertEqual(store.token, "home", "removing the current Mac moves to the next one")
    }

    func testRemovingTheLastMacLeavesThePhoneUnpaired() {
        let store = makeStore()
        store.pair(baseURL: "http://100.1.1.1:4517", token: "home")

        store.remove(store.macs[0].id)

        XCTAssertFalse(store.configured)
        XCTAssertTrue(store.macs.isEmpty)
    }

    func testTheSavedMacsSurviveARelaunch() {
        let store = makeStore()
        store.pair(baseURL: "http://100.1.1.1:4517", token: "home", name: "Studio")
        store.pair(baseURL: "http://100.2.2.2:4517", token: "work", name: "Work MacBook")

        let relaunched = makeStore()

        XCTAssertEqual(relaunched.macs.map(\.name), ["Studio", "Work MacBook"])
        XCTAssertEqual(relaunched.current?.name, "Work MacBook")
        XCTAssertEqual(relaunched.token, "work")
    }
}
