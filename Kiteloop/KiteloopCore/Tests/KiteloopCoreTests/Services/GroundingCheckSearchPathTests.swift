import XCTest
@testable import KiteloopCore

/// The grounding check answers "does this verify command's executable exist"
/// from the app's one search policy, handed in as a directory list. On
/// 2026-09-03 it refused a `cargo` verify on a machine that had cargo, because
/// the list it built for itself never reached `~/.cargo/bin` — and the refusal
/// said nothing about where it had looked.
final class GroundingCheckSearchPathTests: XCTestCase {

    private var root: URL!
    private var projectBin: URL!

    override func setUpWithError() throws {
        root = try makeTemporaryDirectory(prefix: "grounding-search-path")
        projectBin = root.appending(path: "project-tools")
        try FileManager.default.createDirectory(at: projectBin, withIntermediateDirectories: true)
        let cargo = projectBin.appending(path: "cargo")
        try "#!/bin/sh\n".write(to: cargo, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: cargo.path(percentEncoded: false))
    }

    private func item(verify: String) -> BacklogItem {
        BacklogItem(id: "rust-check", title: "Check the crate", verify: verify, status: .ready,
                    type: .local, size: .s)
    }

    // MARK: - Resolution through the handed-in list

    func testAnExecutableReachableOnlyThroughAProjectExtraPathIsAccepted() {
        let extras = [projectBin.path(percentEncoded: false)]

        XCTAssertTrue(GroundingCheck.Executables.resolves("cargo", root: root, searchDirectories: ["/usr/bin"] + extras))
        XCTAssertFalse(GroundingCheck.Executables.resolves("cargo", root: root, searchDirectories: ["/usr/bin"]),
                       "nothing but the list is searched — ProcessInfo's PATH is not consulted")
    }

    func testRepositorySourcesGroundAVerifyThroughTheProjectsExtraPath() {
        let sources = GroundingCheck.Sources.repository(
            root: root, searchDirectories: ["/usr/bin", projectBin.path(percentEncoded: false)])

        let verdict = GroundingCheck.evaluate(item: item(verify: "cargo test --workspace"), detail: nil, sources: sources)

        XCTAssertTrue(verdict.isGrounded, verdict.summary)
    }

    // MARK: - The refusal names where the app looked

    func testTheRefusalNamesTheDirectoriesSearched() throws {
        // A directory this test owns, so the refusal holds whatever this
        // machine has installed: /opt/homebrew/bin stopped being one the day
        // Homebrew's rust put a cargo there.
        let emptyBin = root.appending(path: "empty-bin")
        try FileManager.default.createDirectory(at: emptyBin, withIntermediateDirectories: true)
        let searched = ["/usr/bin", emptyBin.path(percentEncoded: false)]
        let sources = GroundingCheck.Sources.repository(root: root, searchDirectories: searched)

        let verdict = GroundingCheck.evaluate(item: item(verify: "cargo test"), detail: nil, sources: sources)

        XCTAssertFalse(verdict.isGrounded)
        XCTAssertTrue(verdict.summary.contains(
            "runs `cargo`, which resolves to no executable (searched \(searched.joined(separator: ":")))"),
                      verdict.summary)
        XCTAssertFalse(verdict.summary.contains("\n"), "one line, like every other refusal")
    }

    func testARelativePathRefusalPointsAtTheRepoRootRatherThanTheSearchList() {
        let sources = GroundingCheck.Sources.repository(root: root, searchDirectories: ["/usr/bin", "/opt/homebrew/bin"])

        let verdict = GroundingCheck.evaluate(item: item(verify: "scripts/does-not-exist.sh"),
                                              detail: nil, sources: sources)

        XCTAssertFalse(verdict.isGrounded)
        XCTAssertTrue(verdict.summary.contains(
            "runs `scripts/does-not-exist.sh`, which resolves to no executable "
            + "(it is not an executable file under the repo root, and a `verify:` path is resolved "
            + "from the repo root rather than looked up on the search path)"), verdict.summary)
        XCTAssertFalse(verdict.summary.contains("/usr/bin"),
                       "the search directories were never opened for a path — do not name them")
    }

    func testAnAbsolutePathRefusalNamesThatPathAndNotTheSearchList() {
        let sources = GroundingCheck.Sources.repository(root: root, searchDirectories: ["/usr/bin", "/opt/homebrew/bin"])
        let absent = root.appending(path: "nowhere/tool.sh").path(percentEncoded: false)

        let verdict = GroundingCheck.evaluate(item: item(verify: absent), detail: nil, sources: sources)

        XCTAssertFalse(verdict.isGrounded)
        XCTAssertTrue(verdict.summary.contains(
            "runs `\(absent)`, which resolves to no executable (nothing executable is at that path)"),
                      verdict.summary)
        XCTAssertFalse(verdict.summary.contains("searched "),
                       "an absolute token is asked of that one path, not of the search directories")
    }

    func testAnExecutableRelativePathStillGrounds() {
        let sources = GroundingCheck.Sources.repository(root: root, searchDirectories: ["/usr/bin"])

        let verdict = GroundingCheck.evaluate(item: item(verify: "project-tools/cargo test"),
                                              detail: nil, sources: sources)

        XCTAssertTrue(verdict.isGrounded, verdict.summary)
    }

    func testALongSearchListIsCutWithACountOfWhatWasLeftOff() {
        let directories = (1...40).map { "/very/long/directory/number/\($0)/bin" }

        let described = GroundingCheck.Executables.searchedDescription(directories, limit: 120)

        XCTAssertTrue(described.hasPrefix("searched /very/long/directory/number/1/bin"), described)
        XCTAssertTrue(described.hasSuffix(" more"), described)
        XCTAssertLessThan(described.count, 160)
        XCTAssertEqual(GroundingCheck.Executables.searchedDescription([]), "no directory was searched")
    }
}
