import XCTest
@testable import KiteloopCore

/// The phones registered for pushes: one row per token however often a phone
/// registers, kept across a relaunch, readable by this user only.
final class PushDeviceStoreTests: XCTestCase {

    private var url: URL!

    override func setUpWithError() throws {
        url = try makeTemporaryDirectory(prefix: "push-devices").appending(path: "push-devices.json")
    }

    private func device(_ token: String, name: String = "iPhone") -> PushDevice {
        PushDevice(token: token, environment: .sandbox, name: name, registeredAt: Date(timeIntervalSince1970: 0))
    }

    func testRegisteringStoresTheDevice() async {
        let store = PushDeviceStore(url: url)
        await store.register(device("t1"))

        let devices = await store.all()
        XCTAssertEqual(devices.map(\.token), ["t1"])
    }

    func testRegisteringTheSameTokenAgainDoesNotDuplicateIt() async {
        let store = PushDeviceStore(url: url)
        await store.register(device("t1", name: "old"))
        await store.register(device("t1", name: "new"))

        let devices = await store.all()
        XCTAssertEqual(devices.map(\.name), ["new"])
    }

    func testTheDevicesSurviveARelaunchAndTheFileIsPrivate() async throws {
        await PushDeviceStore(url: url).register(device("t1"))

        let devices = await PushDeviceStore(url: url).all()
        XCTAssertEqual(devices.map(\.token), ["t1"])
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testRemovingADeviceForgetsIt() async {
        let store = PushDeviceStore(url: url)
        await store.register(device("t1"))
        await store.register(device("t2"))
        await store.remove(token: "t1")

        let devices = await store.all()
        XCTAssertEqual(devices.map(\.token), ["t2"])
    }
}
