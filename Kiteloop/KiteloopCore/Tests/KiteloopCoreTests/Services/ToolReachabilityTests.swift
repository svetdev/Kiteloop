import XCTest
@testable import KiteloopCore

/// `ToolReachability`: one row per executable a project's verify commands run,
/// with where it resolved or — for one that did not — the directories that
/// were searched, so an operator reads the gap before a run is refused for it.
final class ToolReachabilityTests: XCTestCase {

    private var root: URL!
    private var binDir: URL!

    override func setUpWithError() throws {
        root = try makeTemporaryDirectory(prefix: "tool-reachability")
        binDir = root.appending(path: "tools")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try installExecutable(named: "cargo", in: binDir)
        try installExecutable(named: "check.sh", in: root)
    }

    private func installExecutable(named name: String, in directory: URL) throws {
        let url = directory.appending(path: name)
        try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: url.path(percentEncoded: false))
    }

    private var searched: [String] { [binDir.path(percentEncoded: false), "/nonexistent/bin"] }

    // MARK: - Rows

    func testAResolvableExecutableCarriesItsPathAndNoSearchList() {
        let rows = ToolReachability.rows(commands: ["cargo test --workspace"], root: root, searchDirectories: searched)

        XCTAssertEqual(rows, [ToolReachability.Row(
            name: "cargo", path: binDir.appending(path: "cargo").path(percentEncoded: false), searched: [])])
        XCTAssertTrue(rows[0].isReachable)
    }

    func testAnUnresolvableExecutableCarriesNoPathAndTheDirectoriesSearched() {
        let rows = ToolReachability.rows(commands: ["lizard -C 8 Sources"], root: root, searchDirectories: searched)

        XCTAssertEqual(rows, [ToolReachability.Row(name: "lizard", path: nil, searched: searched)])
        XCTAssertFalse(rows[0].isReachable)
    }

    func testARelativeScriptResolvesAgainstTheRootAndAMissingOneNamesIt() {
        let rows = ToolReachability.rows(commands: ["./check.sh && ./missing.sh"], root: root, searchDirectories: searched)

        XCTAssertEqual(rows.map(\.name), ["./check.sh", "./missing.sh"])
        XCTAssertEqual(rows[0].path, root.appending(path: "check.sh").path(percentEncoded: false))
        XCTAssertNil(rows[1].path)
        XCTAssertEqual(rows[1].searched, [root.path(percentEncoded: false)])
    }

    func testEachExecutableAppearsOnceSortedByNameAcrossCommandsAndSegments() {
        let rows = ToolReachability.rows(
            commands: ["cd Kiteloop && cargo build", "cargo test|tee log.txt", "lizard ."],
            root: root, searchDirectories: searched)

        XCTAssertEqual(rows.map(\.name), ["cargo", "lizard", "tee"], "builtins dropped, duplicates folded, sorted")
    }

    // MARK: - Commands

    func testCommandsGatherEveryItemsVerifyAndTheMapsRunnableOnce() {
        let groomed = BacklogItem(id: "a", title: "A", verify: "make a", status: .ready, type: .local)
        let detail = BacklogItemDetail(id: "a", title: "A",
                                       verifyCommands: [.init(name: "core", cmd: "./scripts/run-core-tests.sh")],
                                       acceptanceCriteria: [], outOfScope: [])
        let lineOnly = BacklogItem(id: "b", title: "B", verify: "cargo test", status: .ready, type: .local)
        let map = VerifyCoverage.Map(rules: [
            .init(glob: "Sources/**", command: "cargo test"),
            .init(glob: "Kiteloop/**", command: "xcodebuild -scheme Kiteloop", run: "cd Kiteloop && xcodebuild build"),
        ])

        let commands = ToolReachability.commands(items: [(groomed, detail), (lineOnly, nil)], map: map)

        XCTAssertEqual(commands, ["./scripts/run-core-tests.sh", "cargo test", "cd Kiteloop && xcodebuild build"],
                       "the groomed detail wins over the item line, the map's runnable spelling is used, duplicates fold")
    }

    // MARK: - Report

    func testTheReportNamesTheProjectByItsFolderAndCarriesTheRows() {
        let report = ToolReachability.report(root: root, commands: ["cargo build"], searchDirectories: searched)

        XCTAssertEqual(report.project, root.lastPathComponent)
        XCTAssertEqual(report.path, root.path(percentEncoded: false))
        XCTAssertEqual(report.tools.map(\.name), ["cargo"])
    }
}
