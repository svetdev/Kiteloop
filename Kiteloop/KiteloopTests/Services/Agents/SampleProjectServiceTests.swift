import XCTest
import KiteloopCore
@testable import Kiteloop

/// `SampleProjectService.install` is what "Try a Sample Project" runs: it has
/// to leave behind something autopilot can actually finish a run against, which
/// means a real git repository (`RunWorkEvidence` reads git, not files) with a
/// team already wired to the two bundled example agents.
final class SampleProjectServiceTests: XCTestCase {
    private var destination: URL!
    private var bundledSource: URL!

    override func setUpWithError() throws {
        destination = try makeTemporaryDirectory(prefix: "sample-project-dest")
            .appending(path: "sample-project")
        bundledSource = try makeTemporaryDirectory(prefix: "sample-project-source")
        try writeFixtureSample(at: bundledSource)
    }

    private func writeFixtureSample(at url: URL) throws {
        try "- [ ] a | A | verify: true | size:XS | ready".write(
            to: url.appending(path: "BACKLOG.md"), atomically: true, encoding: .utf8)
        try "echo hi".write(to: url.appending(path: "greet.sh"), atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func git(_ args: [String], in directory: URL) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    func testInstallCopiesTheBundledSampleIntoARealGitRepo() throws {
        let url = try SampleProjectService.install(destination: destination, bundledSource: bundledSource)

        XCTAssertEqual(url, destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appending(path: "BACKLOG.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appending(path: "greet.sh").path))

        let commitCount = git(["rev-list", "--count", "HEAD"], in: destination)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(commitCount, "1")

        let status = git(["status", "--porcelain"], in: destination)
        XCTAssertTrue(status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      "the initial commit should leave nothing uncommitted")
    }

    func testInstallPreAssignsBothExampleAgentsInTeamConfig() throws {
        let url = try SampleProjectService.install(destination: destination, bundledSource: bundledSource)

        let data = try Data(contentsOf: KiteloopProject(rootURL: url).teamConfigURL)
        let team = try JSONDecoder().decode(PackageTeamConfig.self, from: data)
        let ids = Set(team.agents.map(\.id))
        XCTAssertEqual(ids, ["example-coder", "example-reviewer"])
        XCTAssertTrue(team.agents.allSatisfy { $0.ref.hasSuffix($0.id) })
    }

    func testInstallPreAssignsWorkerAndReviewerInAutopilotConfig() throws {
        let url = try SampleProjectService.install(destination: destination, bundledSource: bundledSource)

        struct SeedConfig: Codable { var workerAgentID: String?; var reviewerAgentID: String? }
        let data = try Data(contentsOf: KiteloopProject(rootURL: url).autopilotConfigURL)
        let config = try JSONDecoder().decode(SeedConfig.self, from: data)
        XCTAssertEqual(config.workerAgentID, "example-coder")
        XCTAssertEqual(config.reviewerAgentID, "example-reviewer")
    }

    func testInstallLeavesAnExistingDestinationCompletelyAlone() throws {
        try SampleProjectService.install(destination: destination, bundledSource: bundledSource)
        let teamConfigURL = KiteloopProject(rootURL: destination).teamConfigURL
        try "not json".write(to: teamConfigURL, atomically: true, encoding: .utf8)

        let url = try SampleProjectService.install(destination: destination, bundledSource: bundledSource)

        XCTAssertEqual(url, destination)
        let contents = try String(contentsOf: teamConfigURL, encoding: .utf8)
        XCTAssertEqual(contents, "not json", "a second install must not touch a destination that already exists")
    }

    func testInstallThrowsWhenTheBundledSampleHasNoBacklog() throws {
        let emptySource = try makeTemporaryDirectory(prefix: "sample-project-empty-source")

        XCTAssertThrowsError(
            try SampleProjectService.install(destination: destination, bundledSource: emptySource)
        ) { error in
            XCTAssertEqual(error as? SampleProjectService.InstallError, .bundledSampleNotFound)
        }
    }
}
