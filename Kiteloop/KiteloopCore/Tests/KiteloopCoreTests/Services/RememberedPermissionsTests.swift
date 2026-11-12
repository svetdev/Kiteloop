import XCTest
@testable import KiteloopCore

final class RememberedPermissionsTests: XCTestCase {

    private let file = Data(#"""
    {"permissions": {"allow": ["Bash(make test)", "Read(//tmp/**)"], "deny": ["WebSearch"]}, "env": {"A": "1"}}
    """#.utf8)

    func testTheFileIsTheProjectsLocalClaudeSettings() {
        XCTAssertEqual(RememberedPermissions.fileURL(projectRoot: URL(fileURLWithPath: "/work/app")).path,
                       "/work/app/.claude/settings.local.json")
    }

    func testTheRulesAreTheAllowListInTheFilesOrder() {
        XCTAssertEqual(RememberedPermissions.rules(in: file), ["Bash(make test)", "Read(//tmp/**)"])
    }

    func testNoFileOrAFileThatIsNotSettingsHoldsNoRules() {
        XCTAssertEqual(RememberedPermissions.rules(in: nil), [])
        XCTAssertEqual(RememberedPermissions.rules(in: Data("[1, 2]".utf8)), [])
        XCTAssertEqual(RememberedPermissions.rules(in: Data("not json".utf8)), [])
        XCTAssertEqual(RememberedPermissions.rules(in: Data(#"{"permissions": {"deny": ["X"]}}"#.utf8)), [])
    }

    func testRemovingARuleLeavesTheRestOfTheFileAsItWas() throws {
        let rewritten = try XCTUnwrap(RememberedPermissions.removing("Bash(make test)", from: file))

        XCTAssertEqual(RememberedPermissions.rules(in: rewritten), ["Read(//tmp/**)"])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: rewritten) as? [String: Any])
        XCTAssertEqual((json["permissions"] as? [String: Any])?["deny"] as? [String], ["WebSearch"])
        XCTAssertEqual(json["env"] as? [String: String], ["A": "1"])
    }

    func testRemovingFromAProjectRewritesItsFileAndAnswersWhatIsLeft() throws {
        let root = try makeTemporaryDirectory(prefix: "remembered-permissions")
        let url = RememberedPermissions.fileURL(projectRoot: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try file.write(to: url)
        XCTAssertEqual(RememberedPermissions.load(projectRoot: root), ["Bash(make test)", "Read(//tmp/**)"])

        XCTAssertEqual(try RememberedPermissions.remove("Read(//tmp/**)", projectRoot: root), ["Bash(make test)"])
        XCTAssertEqual(RememberedPermissions.load(projectRoot: root), ["Bash(make test)"])

        let before = try Data(contentsOf: url)
        XCTAssertEqual(try RememberedPermissions.remove("Bash(nothing)", projectRoot: root), ["Bash(make test)"])
        XCTAssertEqual(try Data(contentsOf: url), before, "a rule the file does not hold leaves the file untouched")
    }

    func testAProjectWithNoFileHoldsNothingAndRemovingCreatesNone() throws {
        let root = try makeTemporaryDirectory(prefix: "remembered-permissions-empty")
        XCTAssertEqual(RememberedPermissions.load(projectRoot: root), [])
        XCTAssertEqual(try RememberedPermissions.remove("Bash(make)", projectRoot: root), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: RememberedPermissions.fileURL(projectRoot: root).path))
    }

    func testARuleTheFileDoesNotHoldRewritesNothing() {
        XCTAssertNil(RememberedPermissions.removing("Bash(rm -rf /)", from: file))
        XCTAssertNil(RememberedPermissions.removing("Bash(make test)", from: nil))
        XCTAssertNil(RememberedPermissions.removing("Bash(make test)", from: Data("[]".utf8)))
    }
}
