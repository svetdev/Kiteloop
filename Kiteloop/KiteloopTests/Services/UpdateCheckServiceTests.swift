import XCTest
@testable import Kiteloop

/// Counts what the service asked GitHub for, so a test can tell a check that
/// consulted the network from one the day's allowance held back.
private actor FetchLog {
    private(set) var calls = 0
    func record() { calls += 1 }
}

/// The three ways in — the menu item, the passive check at launch, and the
/// notice window asking for itself when it has nothing to show — and the three
/// things the item asks of them: a newer release is surfaced with its link, no
/// newer release says nothing, and an unreachable GitHub is silent rather than
/// an error in the user's way.
///
/// The fetch, the clock and the defaults are all injected, so none of this
/// touches the network, the real clock or `UserDefaults.standard`.
@MainActor
final class UpdateCheckServiceTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        // A suite of this test's own: the passive check records the day it last
        // got an answer, and that must not leak into the app's defaults or
        // into the next test.
        suiteName = "UpdateCheckServiceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private static let release = LatestRelease(
        version: "v0.4.9",
        url: URL(string: "https://github.com/svetdev/Kiteloop/releases/tag/v0.4.9")!
    )

    /// A service whose GitHub either answers with `release` or refuses.
    private func makeService(installed: String = "0.4.8",
                             release: LatestRelease? = UpdateCheckServiceTests.release,
                             failure: UpdateCheckFailure = .endpointUnreachable,
                             now: @escaping () -> Date = Date.init,
                             log: FetchLog? = nil) -> UpdateCheckService {
        UpdateCheckService(
            currentVersion: installed,
            fetch: {
                await log?.record()
                guard let release else { throw failure }
                return release
            },
            now: now,
            defaults: defaults
        )
    }

    // MARK: - The menu item

    /// AC 1: a newer release is surfaced, and the link the notice offers is the
    /// one GitHub published.
    func testANewerReleaseIsSurfacedWithItsLink() async {
        let service = makeService()
        await service.checkNow()
        guard case .available(let found) = service.state else {
            return XCTFail("expected a newer release, got \(service.state)")
        }
        XCTAssertEqual(found.version, "v0.4.9")
        XCTAssertEqual(found.url, Self.release.url)
    }

    /// AC 1: with nothing newer published, the check says so rather than
    /// offering the version the user is already running.
    func testAnUpToDateCopyIsToldSoAndOfferedNothing() async {
        let service = makeService(installed: "0.4.9")
        await service.checkNow()
        XCTAssertEqual(service.state, .upToDate)
    }

    /// AC 2: offline, the menu item says the check could not be made. It never
    /// throws and never claims an update.
    func testAnUnreachableGitHubIsReportedAndOffersNothing() async {
        let service = makeService(release: nil)
        await service.checkNow()
        XCTAssertEqual(service.state, .unreachable(.endpointUnreachable))
    }

    /// GitHub answering is not GitHub being unreachable: each refusal is kept,
    /// and the notice says it in its own words.
    func testEachRefusalIsReportedAsItselfAndInItsOwnWords() async {
        let failures: [UpdateCheckFailure] = [.endpointUnreachable, .noReleasePublished, .rateLimited, .malformedRelease]
        for failure in failures {
            let service = makeService(release: nil, failure: failure)
            await service.checkNow()
            XCTAssertEqual(service.state, .unreachable(failure))
        }
        let sentences = failures.map(SoftwareUpdateView.sentence(for:))
        XCTAssertEqual(Set(sentences).count, failures.count)
        XCTAssertEqual(sentences.filter { $0.contains("Couldn't reach GitHub") }.count, 1)
    }

    func testTheStatusSaysWhichRefusalItIs() {
        XCTAssertNil(UpdateCheckFailure.forStatus(200))
        XCTAssertEqual(UpdateCheckFailure.forStatus(404), .noReleasePublished)
        XCTAssertEqual(UpdateCheckFailure.forStatus(403), .rateLimited)
        XCTAssertEqual(UpdateCheckFailure.forStatus(429), .rateLimited)
        XCTAssertEqual(UpdateCheckFailure.forStatus(500), .endpointUnreachable)
        XCTAssertEqual(UpdateCheckFailure.forStatus(0), .endpointUnreachable)
    }

    /// The passive check stays silent on every refusal, and none of them spends
    /// the day's allowance.
    func testThePassiveCheckIsSilentOnEveryRefusalAndRecordsNoAnswer() async {
        for failure in [UpdateCheckFailure.endpointUnreachable, .noReleasePublished, .rateLimited, .malformedRelease] {
            let service = makeService(release: nil, failure: failure)
            let shown = await service.checkPassively()
            XCTAssertFalse(shown)
            XCTAssertEqual(service.state, .idle)
            XCTAssertNil(defaults.object(forKey: UpdateCheckService.lastCheckDefaultsKey))
        }
    }

    // MARK: - Skip This Version

    private static let newer = LatestRelease(
        version: "v0.5.0", url: URL(string: "https://github.com/svetdev/Kiteloop/releases/tag/v0.5.0")!)

    /// Skips v0.4.9 through the window, on a service built over the shared
    /// defaults — then forgets that check's date, so the launch check that
    /// follows is due and actually asks.
    private func skipTheOfferedRelease() async {
        let offering = makeService()
        await offering.checkNow()
        offering.skipOfferedVersion()
        defaults.removeObject(forKey: UpdateCheckService.lastCheckDefaultsKey)
    }

    func testTheLaunchCheckIsQuietAboutASkippedVersion() async {
        await skipTheOfferedRelease()
        let log = FetchLog()
        let service = makeService(log: log)
        let shown = await service.checkPassively()
        XCTAssertFalse(shown)
        XCTAssertEqual(service.state, .idle)
        let calls = await log.calls
        XCTAssertEqual(calls, 1, "the launch check asked, and found only the skipped version")
    }

    func testTheLaunchCheckOffersAReleaseNewerThanTheSkippedOne() async {
        await skipTheOfferedRelease()
        let service = makeService(release: Self.newer)
        let shown = await service.checkPassively()
        XCTAssertTrue(shown)
        XCTAssertEqual(service.state, .available(Self.newer))
    }

    func testAnExplicitCheckStillShowsTheSkippedVersion() async {
        await skipTheOfferedRelease()
        let service = makeService()
        await service.checkNow()
        XCTAssertEqual(service.state, .available(Self.release))
        XCTAssertTrue(service.isSkipped(Self.release), "a new service reads the skip from the same defaults")
    }

    func testNothingIsSkippedWhenNoReleaseIsOnOffer() async {
        let service = makeService(installed: "0.4.9")
        await service.checkNow()
        service.skipOfferedVersion()
        XCTAssertNil(defaults.string(forKey: UpdateCheckService.skippedVersionDefaultsKey))
    }

    // MARK: - The passive check at launch

    /// AC 1: at launch, a newer release is what the caller is told to put on
    /// screen.
    func testThePassiveCheckReportsANewerRelease() async {
        let service = makeService()
        let hasUpdate = await service.checkPassively()
        XCTAssertTrue(hasUpdate)
        XCTAssertEqual(service.state, .available(Self.release))
    }

    /// AC 1: an up-to-date copy launches in silence — nothing to show, and no
    /// notice state left behind for anything else to read.
    func testThePassiveCheckIsSilentWhenUpToDate() async {
        let service = makeService(installed: "0.4.9")
        let hasUpdate = await service.checkPassively()
        XCTAssertFalse(hasUpdate)
        XCTAssertEqual(service.state, .idle)
    }

    /// AC 2: offline at launch, the check fails silently — no notice, no
    /// error state on screen, nothing that could block the launch.
    func testThePassiveCheckFailsSilentlyOffline() async {
        let service = makeService(release: nil)
        let hasUpdate = await service.checkPassively()
        XCTAssertFalse(hasUpdate)
        XCTAssertEqual(service.state, .idle)
    }

    // MARK: - The window opening with nothing behind it

    /// The window is also in the Window menu and is restored at launch, so it
    /// can open with no check running. Opened on `.idle`, it asks, and ends on
    /// the verdict rather than on a spinner nothing is behind.
    func testTheWindowAsksWhenItHasNothingToShow() async {
        let log = FetchLog()
        let service = makeService(log: log)
        await service.checkIfNothingToShow()
        let calls = await log.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(service.state, .available(Self.release))
    }

    /// An answer already on screen is left alone: bringing the window forward
    /// again neither re-asks GitHub nor replaces what it says.
    func testTheWindowDoesNotReAskWhenItAlreadyShowsAnAnswer() async {
        let log = FetchLog()
        let service = makeService(installed: "0.4.9", log: log)
        await service.checkNow()
        XCTAssertEqual(service.state, .upToDate)

        await service.checkIfNothingToShow()
        let calls = await log.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(service.state, .upToDate)
    }

    /// The same for a release already offered — the notice keeps the release
    /// and its link instead of being fetched again.
    func testTheWindowKeepsAReleaseItIsAlreadyOffering() async {
        let log = FetchLog()
        let service = makeService(log: log)
        await service.checkNow()
        XCTAssertEqual(service.state, .available(Self.release))

        await service.checkIfNothingToShow()
        let calls = await log.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(service.state, .available(Self.release))
    }

    // MARK: - At most once a day

    /// The rate limit: a second launch inside the day makes no request at all.
    func testASecondPassiveCheckInsideTheDayAsksNothing() async {
        let log = FetchLog()
        let service = makeService(log: log)
        _ = await service.checkPassively()
        _ = await service.checkPassively()
        let calls = await log.calls
        XCTAssertEqual(calls, 1)
    }

    /// Once the day has passed, the next launch asks again.
    func testThePassiveCheckAsksAgainAfterADay() async {
        let log = FetchLog()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var clock = start
        let service = makeService(now: { clock }, log: log)

        _ = await service.checkPassively()
        clock = start.addingTimeInterval(UpdateCheckService.passiveInterval + 1)
        _ = await service.checkPassively()

        let calls = await log.calls
        XCTAssertEqual(calls, 2)
    }

    /// A check that never reached GitHub does not spend the day: a laptop
    /// opened before its network is up would otherwise stay quiet until
    /// tomorrow even once it is online.
    func testAFailedCheckDoesNotSpendTheDay() async {
        let log = FetchLog()
        let service = makeService(release: nil, log: log)
        _ = await service.checkPassively()
        _ = await service.checkPassively()
        let calls = await log.calls
        XCTAssertEqual(calls, 2)
    }

    // MARK: - The version it compares against

    /// An unbundled build reports `"dev"`, which is no version at all, so a
    /// copy run from Xcode is never told it is out of date.
    func testAnUnbundledBuildIsNeverOfferedAnUpdate() async {
        let service = makeService(installed: "dev")
        await service.checkNow()
        XCTAssertEqual(service.state, .upToDate)
    }

    // MARK: - The release's notes

    /// A literal `releases/latest` payload, with `bodyField` spliced in as-is
    /// so a test can send notes, `null` or no key at all.
    private static func payload(bodyField: String?) -> Data {
        let body = bodyField.map { ", \"body\": \($0)" } ?? ""
        return Data("""
        {"tag_name": "v0.4.9", "html_url": "https://github.com/svetdev/Kiteloop/releases/tag/v0.4.9"\(body)}
        """.utf8)
    }

    /// The notes GitHub published are what the notice shows, as written.
    func testDecodedNotesAreTheReleaseBody() throws {
        let release = try UpdateCheckService.decodeRelease(Self.payload(bodyField: "\"## Fixes\\n- x\""))
        XCTAssertEqual(release.notes, "## Fixes\n- x")
        XCTAssertEqual(release.version, "v0.4.9")
    }

    /// GitHub sends `null` for a release published without notes: no notes,
    /// and not an unreadable answer.
    func testANullBodyDecodesToEmptyNotes() throws {
        let release = try UpdateCheckService.decodeRelease(Self.payload(bodyField: "null"))
        XCTAssertEqual(release.notes, "")
    }

    /// A payload with no `body` key at all reads the same way.
    func testAMissingBodyDecodesToEmptyNotes() throws {
        let release = try UpdateCheckService.decodeRelease(Self.payload(bodyField: nil))
        XCTAssertEqual(release.notes, "")
    }
}
