import XCTest
@testable import KiteloopCore

/// `canonicalPath` is the single source of project identity: NSOpenPanel hands back
/// directory URLs with a trailing slash while restored bookmarks and recents usually
/// don't, so the same folder must collapse to one id either way. These tests pin the
/// stripping rules, the edge cases that must *not* be stripped, and the identity
/// guarantees `ProjectStore` and `ControlSessionRegistry` rely on.
final class KiteloopProjectCanonicalPathTests: XCTestCase {

    // MARK: - Trailing slash stripping

    func testStripsSingleTrailingSlash() {
        XCTAssertEqual(KiteloopProject.canonicalPath("/Users/dev/proj/"), "/Users/dev/proj")
    }

    func testStripsRepeatedTrailingSlashes() {
        XCTAssertEqual(KiteloopProject.canonicalPath("/Users/dev/proj///"), "/Users/dev/proj")
    }

    func testLeavesPathWithoutTrailingSlashUnchanged() {
        XCTAssertEqual(KiteloopProject.canonicalPath("/Users/dev/proj"), "/Users/dev/proj")
    }

    func testPreservesInteriorSlashes() {
        XCTAssertEqual(
            KiteloopProject.canonicalPath("/Users/dev//nested/proj/"),
            "/Users/dev//nested/proj"
        )
    }

    func testIsIdempotent() {
        let once = KiteloopProject.canonicalPath("/Users/dev/proj/")
        XCTAssertEqual(KiteloopProject.canonicalPath(once), once)
    }

    // MARK: - Edge cases

    func testRootPathIsPreserved() {
        // The `count > 1` guard exists so "/" never collapses to the empty string.
        XCTAssertEqual(KiteloopProject.canonicalPath("/"), "/")
    }

    func testMultipleSlashOnlyPathCollapsesToRoot() {
        XCTAssertEqual(KiteloopProject.canonicalPath("///"), "/")
    }

    func testEmptyPathIsPreserved() {
        XCTAssertEqual(KiteloopProject.canonicalPath(""), "")
    }

    func testPreservesSpacesAndUnicode() {
        XCTAssertEqual(
            KiteloopProject.canonicalPath("/Users/dev/My Projects/café/"),
            "/Users/dev/My Projects/café"
        )
    }

    func testDoesNotResolveRelativeComponents() {
        // Canonicalization is purely lexical on trailing slashes — it is not a
        // filesystem realpath, and callers depend on that (no I/O, no symlink walk).
        XCTAssertEqual(KiteloopProject.canonicalPath("/Users/dev/../dev/proj"), "/Users/dev/../dev/proj")
    }

    // MARK: - Project identity

    func testIDIsStableAcrossTrailingSlashVariants() {
        let withSlash = KiteloopProject(rootURL: URL(fileURLWithPath: "/Users/dev/proj", isDirectory: true))
        let withoutSlash = KiteloopProject(rootURL: URL(fileURLWithPath: "/Users/dev/proj", isDirectory: false))

        XCTAssertTrue(withSlash.rootURL.path(percentEncoded: false).hasSuffix("/"))
        XCTAssertEqual(withSlash.id, withoutSlash.id)
        XCTAssertEqual(withSlash.id, "/Users/dev/proj")
    }

    func testInitLeavesRootURLUntouched() {
        // Identity is canonicalized; `rootURL` must survive verbatim for file I/O.
        let url = URL(fileURLWithPath: "/Users/dev/proj", isDirectory: true)
        let project = KiteloopProject(rootURL: url)

        XCTAssertEqual(project.rootURL, url)
        XCTAssertEqual(project.rootURL.path(percentEncoded: false), "/Users/dev/proj/")
    }

    func testIDDecodesPercentEncodedPaths() {
        let project = KiteloopProject(rootURL: URL(fileURLWithPath: "/Users/dev/My Projects/", isDirectory: true))
        XCTAssertEqual(project.id, "/Users/dev/My Projects")
    }

    func testDistinctFoldersGetDistinctIDs() {
        let a = KiteloopProject(rootURL: URL(fileURLWithPath: "/Users/dev/alpha", isDirectory: true))
        let b = KiteloopProject(rootURL: URL(fileURLWithPath: "/Users/dev/beta", isDirectory: true))
        XCTAssertNotEqual(a.id, b.id)
    }

    func testSiblingPrefixFoldersAreNotConflated() {
        // "/proj" and "/proj-two" share a prefix; stripping must not merge them.
        let a = KiteloopProject(rootURL: URL(fileURLWithPath: "/Users/dev/proj/", isDirectory: true))
        let b = KiteloopProject(rootURL: URL(fileURLWithPath: "/Users/dev/proj-two/", isDirectory: true))
        XCTAssertNotEqual(a.id, b.id)
    }

    func testIDIsUsableAsDictionaryKeyAcrossVariants() {
        // ProjectStore and ControlSessionRegistry key their tables by this id.
        var table: [String: Int] = [:]
        table[KiteloopProject.canonicalPath("/Users/dev/proj/")] = 1
        table[KiteloopProject.canonicalPath("/Users/dev/proj")] = 2

        XCTAssertEqual(table.count, 1)
        XCTAssertEqual(table["/Users/dev/proj"], 2)
    }

    func testHomeWorkspaceIsRecognizedFromTrailingSlashURL() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let project = KiteloopProject(rootURL: home.appending(path: ".kiteloop/home/"))

        XCTAssertEqual(project.id, KiteloopProject.homeWorkspace.id)
        XCTAssertTrue(project.isHomeWorkspace)
    }

    func testNonHomeProjectIsNotHomeWorkspace() {
        let project = KiteloopProject(rootURL: URL(fileURLWithPath: "/Users/dev/proj", isDirectory: true))
        XCTAssertFalse(project.isHomeWorkspace)
    }

    // MARK: - isSamePath

    func testSamePathMatchesAcrossTrailingSlashVariants() {
        XCTAssertTrue(KiteloopProject.isSamePath("/Users/dev/proj/", "/Users/dev/proj"))
        XCTAssertTrue(KiteloopProject.isSamePath("/Users/dev/proj", "/Users/dev/proj/"))
        XCTAssertTrue(KiteloopProject.isSamePath("/Users/dev/proj///", "/Users/dev/proj"))
    }

    func testSamePathMatchesIdenticalSpellings() {
        XCTAssertTrue(KiteloopProject.isSamePath("/Users/dev/proj", "/Users/dev/proj"))
        XCTAssertTrue(KiteloopProject.isSamePath("/", "///"))
    }

    func testSamePathRejectsGenuinelyDifferentPaths() {
        XCTAssertFalse(KiteloopProject.isSamePath("/Users/dev/alpha", "/Users/dev/beta"))
        // A shared prefix is not a match: stripping must not merge siblings.
        XCTAssertFalse(KiteloopProject.isSamePath("/Users/dev/proj/", "/Users/dev/proj-two"))
        // Nor is a parent the same as its child.
        XCTAssertFalse(KiteloopProject.isSamePath("/Users/dev", "/Users/dev/proj"))
    }

    func testSamePathDoesNotResolveSymlinksOrExpandTilde() {
        // The comparison stays lexical: no filesystem, no ~ expansion, no case-folding.
        XCTAssertFalse(KiteloopProject.isSamePath("~/proj", FileManager.default
            .homeDirectoryForCurrentUser.appending(path: "proj").path(percentEncoded: false)))
        XCTAssertFalse(KiteloopProject.isSamePath("/Users/dev/Proj", "/Users/dev/proj"))
        XCTAssertFalse(KiteloopProject.isSamePath("/Users/dev/../dev/proj", "/Users/dev/proj"))
    }
}
