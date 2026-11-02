import XCTest
@testable import Kiteloop

/// The update check's one piece of judgement is this comparison, and every way
/// it can go wrong is a way the app either nags about a version the user
/// already has or stays quiet about one they don't. So: the ordering string
/// comparison gets wrong, the shapes a tag actually arrives in, and the
/// versions that are not versions at all.
final class ReleaseVersionTests: XCTestCase {

    // MARK: - Ordering

    /// The case a lexical comparison gets backwards: the tenth patch release
    /// sorts before the ninth as text, and would never be offered.
    func testATenthPatchReleaseIsNewerThanTheNinth() {
        XCTAssertTrue(ReleaseVersion.isNewer("0.4.10", than: "0.4.9"))
        XCTAssertFalse(ReleaseVersion.isNewer("0.4.9", than: "0.4.10"))
    }

    func testEachComponentDecidesBeforeTheOnesAfterIt() {
        XCTAssertTrue(ReleaseVersion.isNewer("1.0.0", than: "0.99.99"))
        XCTAssertTrue(ReleaseVersion.isNewer("0.5.0", than: "0.4.99"))
        XCTAssertFalse(ReleaseVersion.isNewer("0.4.99", than: "0.5.0"))
    }

    /// An installed copy at or ahead of the published release is told nothing —
    /// a developer build running ahead of the last tag must not be nagged.
    func testTheSameOrAnOlderReleaseIsNotNews() {
        XCTAssertFalse(ReleaseVersion.isNewer("0.4.8", than: "0.4.8"))
        XCTAssertFalse(ReleaseVersion.isNewer("0.4.7", than: "0.4.8"))
    }

    // MARK: - The shapes a tag arrives in

    /// Releases here are tagged `v0.4.8`; the app reports `0.4.8`. The two are
    /// compared, not matched as text.
    func testALeadingVDoesNotMakeATagNewer() {
        XCTAssertFalse(ReleaseVersion.isNewer("v0.4.8", than: "0.4.8"))
        XCTAssertTrue(ReleaseVersion.isNewer("v0.4.9", than: "0.4.8"))
        XCTAssertTrue(ReleaseVersion.isNewer("V0.4.9", than: "0.4.8"))
    }

    /// A missing component is zero, so a two-part tag and its three-part
    /// spelling are the same version rather than one being newer.
    func testAMissingComponentReadsAsZero() {
        XCTAssertEqual(ReleaseVersion("0.5"), ReleaseVersion("0.5.0"))
        XCTAssertFalse(ReleaseVersion.isNewer("0.5", than: "0.5.0"))
        XCTAssertFalse(ReleaseVersion.isNewer("0.5.0", than: "0.5"))
        XCTAssertTrue(ReleaseVersion.isNewer("0.5.1", than: "0.5"))
    }

    func testSurroundingWhitespaceIsIgnored() {
        XCTAssertTrue(ReleaseVersion.isNewer("  v0.4.9\n", than: "0.4.8"))
    }

    // MARK: - What is not a version

    /// An unbundled build reports `"dev"`. It is compared against nothing, so
    /// running from Xcode never raises the notice.
    func testAnUnbundledBuildIsNeverToldItIsOutOfDate() {
        XCTAssertNil(ReleaseVersion("dev"))
        XCTAssertFalse(ReleaseVersion.isNewer("0.9.9", than: "dev"))
    }

    /// A release tagged after something other than its number, or carrying a
    /// pre-release suffix, is not guessed at — it is simply not offered.
    func testAnUnreadableTagIsNotOffered() {
        XCTAssertNil(ReleaseVersion(""))
        XCTAssertNil(ReleaseVersion("nightly"))
        XCTAssertNil(ReleaseVersion("0.5.0-beta.1"))
        XCTAssertNil(ReleaseVersion("0..1"))
        XCTAssertNil(ReleaseVersion("-1.0"))
        XCTAssertFalse(ReleaseVersion.isNewer("0.5.0-beta.1", than: "0.4.8"))
    }

    func testAReadableTagParsesToItsComponents() {
        XCTAssertEqual(ReleaseVersion("v1.2.3")?.components, [1, 2, 3])
        XCTAssertEqual(ReleaseVersion("7")?.components, [7])
    }
}
