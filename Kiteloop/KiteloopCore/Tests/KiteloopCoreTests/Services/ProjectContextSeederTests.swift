import XCTest
@testable import KiteloopCore

/// The seeder writes `.kiteloop/context.md` once, when a project is first
/// opened, and that file rides into every agent's system prompt for the
/// project. Whatever it leaves out has to say so: a README section that stops
/// mid-word, or a root listing that stops at its cap, reads downstream as the
/// whole of what the project said about itself.
final class ProjectContextSeederTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = try makeTemporaryDirectory(prefix: "project-context-seeder")
    }

    // MARK: - Helpers

    /// Seeds a project rooted at the temp directory and returns what landed in
    /// `.kiteloop/context.md`.
    private func seededContext() throws -> String {
        let project = KiteloopProject(rootURL: tempDir)
        ProjectContextSeeder(project: project).seedIfNeeded()
        return try String(contentsOf: project.contextURL, encoding: .utf8)
    }

    private func writeReadme(_ content: String, named name: String = "README.md") throws {
        try content.write(to: tempDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    // MARK: - README excerpt

    func testALongReadmeIsCutOnAWholeWordAndSaysWhereTheRestIs() throws {
        // 3300 characters of "alpha beta " — the 1500-character cap lands inside
        // the word "alpha", four characters in.
        try writeReadme(String(repeating: "alpha beta ", count: 300))

        let context = try seededContext()

        XCTAssertTrue(
            context.contains("beta…\n\n(Cut here — the rest of the README is in README.md.)"),
            "expected the excerpt to end on a whole word and name the file the rest is in, got:\n\(context)"
        )
        XCTAssertFalse(context.contains("alph…"), "the excerpt was cut mid-word")
    }

    func testTheMarkerNamesWhicheverReadmeItRead() throws {
        try writeReadme(String(repeating: "alpha beta ", count: 300), named: "README.txt")

        let context = try seededContext()

        XCTAssertTrue(context.contains("the rest of the README is in README.txt.)"),
                      "expected the marker to name README.txt, got:\n\(context)")
    }

    func testAReadmeUnderTheCapIsReproducedUnchanged() throws {
        let readme = "# Tiny\n\nOne short paragraph, well under the cap.\n"
        try writeReadme(readme)

        let context = try seededContext()

        XCTAssertTrue(context.contains("## From README\n\n\(readme)"),
                      "expected the README verbatim, got:\n\(context)")
        XCTAssertFalse(context.contains("…"), "a README under the cap needs no ellipsis")
        XCTAssertFalse(context.contains("Cut here"), "a README under the cap needs no marker")
    }

    func testAReadmeWithOneBadByteStillKeepsTheTextAroundIt() throws {
        var bytes = Data("# Title\n".utf8)
        bytes.append(0xFF)
        bytes.append(contentsOf: Data("\nafterBadByteMarker\n".utf8))
        try bytes.write(to: tempDir.appendingPathComponent("README.md"))

        let context = try seededContext()

        XCTAssertTrue(context.contains("## From README"),
                      "a README with one bad byte was left out, got:\n\(context)")
        XCTAssertTrue(context.contains("# Title"), "expected the text before the bad byte")
        XCTAssertTrue(context.contains("afterBadByteMarker"), "expected the text after the bad byte")
    }

    func testNoReadmeMeansNoReadmeSection() throws {
        let context = try seededContext()

        XCTAssertFalse(context.contains("## From README"))
    }

    // MARK: - Structure listing

    func testARootWithMoreEntriesThanTheCapSaysHowManyAreNotShown() throws {
        for i in 0..<25 {
            try "".write(to: tempDir.appendingPathComponent(String(format: "file-%02d.txt", i)),
                         atomically: true, encoding: .utf8)
        }

        let context = try seededContext()

        XCTAssertTrue(context.contains("(5 more entries are in the project root but not shown here.)"),
                      "expected the listing to account for the 5 entries it dropped, got:\n\(context)")
        XCTAssertTrue(context.contains("file-19.txt"), "expected the first 20 sorted entries")
        XCTAssertFalse(context.contains("file-20.txt"), "expected the listing to stop at the cap")
    }

    func testOneEntryOverTheCapIsSaidInTheSingular() throws {
        for i in 0..<21 {
            try "".write(to: tempDir.appendingPathComponent(String(format: "file-%02d.txt", i)),
                         atomically: true, encoding: .utf8)
        }

        let context = try seededContext()

        XCTAssertTrue(context.contains("(1 more entry is in the project root but not shown here.)"),
                      "expected the singular form, got:\n\(context)")
    }

    func testARootUnderTheCapSaysNothingExtra() throws {
        for name in ["Sources", "Tests", "README.md"] {
            try "".write(to: tempDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        let context = try seededContext()

        XCTAssertTrue(context.contains("## Structure"))
        XCTAssertFalse(context.contains("more entr"),
                       "a root that fits under the cap has nothing left out to report")
    }

    // MARK: - Seeding

    func testAnExistingContextFileIsNeverOverwritten() throws {
        let project = KiteloopProject(rootURL: tempDir)
        try project.ensureKiteloopDirectory()
        let mine = "# My own words\n\nDo not touch this.\n"
        try mine.write(to: project.contextURL, atomically: true, encoding: .utf8)
        try writeReadme(String(repeating: "alpha beta ", count: 300))

        ProjectContextSeeder(project: project).seedIfNeeded()

        XCTAssertEqual(try String(contentsOf: project.contextURL, encoding: .utf8), mine)
    }
}
