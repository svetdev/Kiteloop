import XCTest
@testable import KiteloopCore

final class TeamConfigTests: XCTestCase {

    private func ref(_ ref: String) -> PackageAgentRef {
        PackageAgentRef(id: "a", ref: ref, version: nil, overrides: nil)
    }

    /// Each source flag answers for exactly its own prefix: a `shared:` ref is
    /// shared and nothing else.
    func testSharedRefIsSharedOnly() {
        let r = ref("shared:reviewer")
        XCTAssertTrue(r.isShared)
        XCTAssertFalse(r.isLocal)
        XCTAssertFalse(r.isUser)
        XCTAssertEqual(r.refPrefix, "shared")
        XCTAssertEqual(r.refName, "reviewer")
    }

    func testLocalRefIsLocalOnly() {
        let r = ref("local:builder")
        XCTAssertTrue(r.isLocal)
        XCTAssertFalse(r.isShared)
        XCTAssertFalse(r.isUser)
    }

    func testUserRefIsUserOnly() {
        let r = ref("user:scout")
        XCTAssertTrue(r.isUser)
        XCTAssertFalse(r.isShared)
        XCTAssertFalse(r.isLocal)
    }

    /// A ref with no prefix belongs to none of the three sources; its prefix is
    /// empty and its name is the whole ref.
    func testUnprefixedRefBelongsToNoSource() {
        let r = ref("builder")
        XCTAssertFalse(r.isShared)
        XCTAssertFalse(r.isLocal)
        XCTAssertFalse(r.isUser)
        XCTAssertEqual(r.refPrefix, "")
        XCTAssertEqual(r.refName, "builder")
    }

    /// An unknown prefix is not silently folded into one of the known sources.
    func testUnknownPrefixBelongsToNoSource() {
        let r = ref("remote:builder")
        XCTAssertFalse(r.isShared)
        XCTAssertFalse(r.isLocal)
        XCTAssertFalse(r.isUser)
        XCTAssertEqual(r.refPrefix, "remote")
    }
}
