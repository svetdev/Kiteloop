import XCTest
@testable import KiteloopCore

/// The phone's one-tap replies: the starters until the list is set, an empty
/// list once cleared, and Settings' lines read as replies.
final class QuickRepliesTests: XCTestCase {

    func testAListNeverSetReadsAsTheStarters() {
        XCTAssertEqual(QuickReplies.effective(GlobalConfig()), QuickReplies.starters)
    }

    func testAClearedListStaysEmptyAcrossASaveAndLoad() throws {
        var config = GlobalConfig()
        config.quickReplies = []

        let reloaded = try JSONDecoder().decode(GlobalConfig.self, from: JSONEncoder().encode(config))

        XCTAssertEqual(QuickReplies.effective(reloaded), [])
    }

    func testASavedListIsTheOneInEffect() throws {
        var config = GlobalConfig()
        config.quickReplies = ["Ship it"]

        let reloaded = try JSONDecoder().decode(GlobalConfig.self, from: JSONEncoder().encode(config))

        XCTAssertEqual(QuickReplies.effective(reloaded), ["Ship it"])
    }

    func testSettingsLinesAreTrimmedAndBlankOnesDropped() {
        XCTAssertEqual(QuickReplies.list(from: "  Continue \n\n Run the tests\n   \n"), ["Continue", "Run the tests"])
    }
}
