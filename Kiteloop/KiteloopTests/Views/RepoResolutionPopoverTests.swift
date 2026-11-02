import KiteloopCore
import XCTest
@testable import Kiteloop

/// The two ways of resolving a missing repo both say what happened when they
/// fail: a clone that git refused shows its reason in the row, and a folder
/// that is not a git clone is refused by name instead of silently.
final class RepoResolutionPopoverTests: XCTestCase {

    func testFailedStatusShowsItsReason() {
        XCTAssertEqual(
            RepoResolutionPopover.failureReason(for: .failed("Clone failed")),
            "Clone failed"
        )
        XCTAssertEqual(
            RepoResolutionPopover.failureReason(for: .failed("Clone timed out after 600s")),
            "Clone timed out after 600s"
        )
    }

    func testEveryOtherStatusShowsNothing() {
        let quiet: [RepoCloneService.CloneStatus?] = [
            nil,
            .notCloned,
            .cloning(bytesOnDisk: 0),
            .cloning(bytesOnDisk: 4_096),
            .pulling,
            .cloned(sizeOnDisk: 1_024)
        ]
        for status in quiet {
            XCTAssertNil(
                RepoResolutionPopover.failureReason(for: status),
                "expected no failure text for \(String(describing: status))"
            )
        }
    }

    func testFolderWithoutGitIsRefusedByName() throws {
        let folder = try makeTemporaryDirectory(prefix: "not-a-clone")
        let refusal = try XCTUnwrap(
            RepoResolutionPopover.linkRefusal(forFolder: folder, repo: "kiteloop")
        )
        XCTAssertTrue(
            refusal.contains(folder.lastPathComponent),
            "refusal should name the folder that was rejected: \(refusal)"
        )
        XCTAssertTrue(refusal.contains("not a git clone"), refusal)
        XCTAssertTrue(refusal.contains("kiteloop"), refusal)
    }

    func testFolderWithGitIsLinked() throws {
        let folder = try makeTemporaryDirectory(prefix: "a-clone")
        try FileManager.default.createDirectory(
            at: folder.appending(path: ".git"),
            withIntermediateDirectories: true
        )
        XCTAssertNil(RepoResolutionPopover.linkRefusal(forFolder: folder, repo: "kiteloop"))
    }

    /// The refresh belongs to the clone: by the time the helper returns, the
    /// clone has settled and the store has been recomputed against that
    /// settled status — not against a `.cloning` snapshot taken a second in.
    @MainActor
    func testRefreshHappensAfterTheCloneSettles() async throws {
        let orgName = "kiteloop-test-repopopover-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: KiteloopProject.workspacesDir(orgName: orgName)) }
        // Starting at `.cloning` is what the old two-task Clone button left
        // behind: the store is only right again if something refreshes it
        // after the clone settles.
        let cloneService = RepoCloneService(
            statuses: ["kiteloop": .cloning(bytesOnDisk: 0)],
            orgName: orgName
        )

        let store = RepoStatusStore(
            cloneService: cloneService,
            linksURL: try makeTemporaryDirectory(prefix: "repo-links").appending(path: "repo-links.json")
        )
        store.register(agentID: "agent", repos: ["kiteloop"])
        XCTAssertEqual(store.repoStatus["kiteloop"], .cloning)

        await RepoResolutionPopover.cloneThenRefresh(
            repo: "kiteloop",
            org: "org",
            cloneService: cloneService,
            repoStatusStore: store,
            gitExecutable: "/usr/bin/false",
            timeout: 5
        )

        XCTAssertEqual(cloneService.statuses["kiteloop"], .failed("Clone failed"))
        XCTAssertEqual(
            store.repoStatus["kiteloop"], .missing,
            "the store must have been recomputed against the settled clone, not left at .cloning"
        )
        XCTAssertEqual(store.missingRepos(for: "agent"), ["kiteloop"])
    }
}
