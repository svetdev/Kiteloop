import XCTest
@testable import KiteloopCore

/// `~/.kiteloop/portfolio.md` is typed by a human into a file named `.md`, so
/// the reading has to survive what a human types into one: a heading, a bullet,
/// a `~`, the same project written twice in two spellings. Every line it refuses
/// is a project missing from the Portfolio screen with nothing saying why, so
/// what it refuses is worth pinning.
final class PortfolioListTests: XCTestCase {

    // MARK: - What counts as a path

    func testOnePathPerLineInTheOrderWritten() {
        let paths = PortfolioList.parse("""
        /work/beta
        /work/alpha
        /work/gamma
        """)

        XCTAssertEqual(paths, ["/work/beta", "/work/alpha", "/work/gamma"])
    }

    func testCommentsHeadingsAndBlankLinesAreIgnored() {
        let paths = PortfolioList.parse("""
        # Kiteloop portfolio
        #
        # One project root per line.

        /work/alpha

        # /work/disabled
        /work/beta
        """)

        XCTAssertEqual(paths, ["/work/alpha", "/work/beta"])
    }

    /// The file is markdown and will be read in an editor that renders it, so a
    /// list somebody wrote as a list is not a syntax error.
    func testMarkdownBulletsAreAccepted() {
        let paths = PortfolioList.parse("""
        - /work/alpha
        * /work/beta
        """)

        XCTAssertEqual(paths, ["/work/alpha", "/work/beta"])
    }

    /// A `#` is legal in a directory name. Stripping a trailing comment would
    /// send the screen looking for a project under a prefix of the folder that
    /// was actually named — a silent wrong answer, where refusing the line at
    /// least shows up as a skipped path.
    func testHashInsideAPathIsNotTreatedAsAComment() {
        XCTAssertEqual(PortfolioList.parse("/work/c#-tooling"), ["/work/c#-tooling"])
    }

    /// The home path `FileManager` hands back carries a trailing slash, so the
    /// expectation is built from it stripped — a path is joined to it, not
    /// concatenated onto it.
    func testTildeIsExpandedToTheHomeDirectory() {
        let home = KiteloopProject.canonicalPath(
            FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false))

        XCTAssertEqual(PortfolioList.parse("~/code/app"), [home + "/code/app"])
    }

    /// And the expansion joins rather than concatenates: a `//` in the middle of
    /// a path is not what anyone typed, and it would be carried all the way into
    /// the project identity a portfolio row is keyed on.
    func testTildeExpansionLeavesNoDoubledSeparator() {
        let path = try? XCTUnwrap(PortfolioList.parse("~/code/app").first)

        XCTAssertNotNil(path)
        XCTAssertFalse(path?.contains("//") ?? true)
    }

    // MARK: - One project, listed once

    /// The same folder written three ways is one project. Without this the
    /// screen draws it as three sections with identical contents, and the item
    /// count triples.
    func testTrailingSlashesAndRepeatsCollapseToOneEntry() {
        let paths = PortfolioList.parse("""
        /work/alpha
        /work/alpha/
        /work/alpha
        """)

        XCTAssertEqual(paths, ["/work/alpha"])
    }

    /// The first spelling survives, because that is the order the file reads in.
    func testTheFirstSpellingOfADuplicateIsTheOneKept() {
        XCTAssertEqual(PortfolioList.parse("/work/beta\n/work/alpha\n/work/beta/"),
                       ["/work/beta", "/work/alpha"])
    }

    // MARK: - Missing file

    /// Before anyone has written a portfolio there is no file, and that is a
    /// state the screen offers to fix — never an error.
    func testAMissingFileIsAnEmptyPortfolio() {
        let missing = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString)/portfolio.md")

        XCTAssertEqual(PortfolioList.load(from: missing), [])
    }

    func testLoadReadsTheFileOnDisk() throws {
        let dir = try makeTemporaryDirectory(prefix: "portfolio-list")
        let url = dir.appending(path: "portfolio.md")
        try "# heading\n/work/alpha\n".write(to: url, atomically: true, encoding: .utf8)

        XCTAssertEqual(PortfolioList.load(from: url), ["/work/alpha"])
    }

    /// A strict decode fails on the whole file over one byte, which reads as no
    /// portfolio at all — and the seed control then refuses, because the file is
    /// there. The lines around the bad byte have to keep their projects.
    func testABadByteDoesNotHideTheOtherPaths() throws {
        let dir = try makeTemporaryDirectory(prefix: "portfolio-list")
        let url = dir.appending(path: "portfolio.md")
        var data = Data("/work/alpha\n/work/br".utf8)
        data.append(0xFF)
        data.append(Data("ken\n/work/beta\n".utf8))
        try data.write(to: url)

        let paths = PortfolioList.load(from: url)

        XCTAssertEqual(paths.filter { $0 == "/work/alpha" || $0 == "/work/beta" },
                       ["/work/alpha", "/work/beta"])
        XCTAssertEqual(paths.first, "/work/alpha")
        XCTAssertEqual(paths.last, "/work/beta")
    }

    // MARK: - Seeding

    /// The seed file has to read back as the list it was written from —
    /// otherwise the first thing the seed control does is produce a portfolio
    /// the screen cannot show.
    func testSeededTextRoundTripsThroughTheParser() {
        let paths = ["/work/alpha", "/work/beta"]

        XCTAssertEqual(PortfolioList.parse(PortfolioList.text(for: paths)), paths)
    }

    /// The preamble is the file's own documentation for whoever opens it in an
    /// editor, so it has to be comment lines rather than content.
    func testSeededTextDocumentsItselfInComments() {
        let text = PortfolioList.text(for: ["/work/alpha"])

        XCTAssertTrue(text.hasPrefix("# Kiteloop portfolio"))
        XCTAssertTrue(text.contains("BACKLOG.md"))
    }

    func testSeedingAnEmptyPortfolioProducesNoPaths() {
        XCTAssertEqual(PortfolioList.parse(PortfolioList.text(for: [])), [])
    }
}
