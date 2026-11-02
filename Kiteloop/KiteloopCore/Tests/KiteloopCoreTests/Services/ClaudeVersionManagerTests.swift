import XCTest
@testable import KiteloopCore

final class ClaudeVersionManagerTests: XCTestCase {
    func testParseVersionFromOutput() {
        XCTAssertEqual(ClaudeVersionManager.parseVersion("claude 1.2.3"), "1.2.3")
        XCTAssertEqual(ClaudeVersionManager.parseVersion("1.0.0"), "1.0.0")
        XCTAssertEqual(ClaudeVersionManager.parseVersion("Claude Code v2.1.0-beta"), "2.1.0")
        XCTAssertNil(ClaudeVersionManager.parseVersion("no version here"))
        XCTAssertNil(ClaudeVersionManager.parseVersion(""))
    }

    func testCompareVersions() {
        XCTAssertEqual(ClaudeVersionManager.compareVersions("1.0.0", "1.0.0"), .orderedSame)
        XCTAssertEqual(ClaudeVersionManager.compareVersions("1.0.0", "2.0.0"), .orderedAscending)
        XCTAssertEqual(ClaudeVersionManager.compareVersions("2.0.0", "1.0.0"), .orderedDescending)
        XCTAssertEqual(ClaudeVersionManager.compareVersions("1.2.3", "1.2.4"), .orderedAscending)
        XCTAssertEqual(ClaudeVersionManager.compareVersions("1.3.0", "1.2.9"), .orderedDescending)
        XCTAssertEqual(ClaudeVersionManager.compareVersions("10.0.0", "9.9.9"), .orderedDescending)
    }

    func testMismatchDetection() async {
        let manager = ClaudeVersionManager(pinnedVersion: "1.5.0")
        let isPinned = await manager.isPinned()
        XCTAssertTrue(isPinned)

        let pinned = await manager.pinnedVersion()
        XCTAssertEqual(pinned, "1.5.0")
    }

    func testNoPinnedVersion() async {
        let manager = ClaudeVersionManager(pinnedVersion: nil)
        let isPinned = await manager.isPinned()
        XCTAssertFalse(isPinned)

        let mismatch = await manager.checkMismatch()
        XCTAssertNil(mismatch)
    }
}
