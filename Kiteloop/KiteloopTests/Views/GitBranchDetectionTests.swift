import XCTest
@testable import Kiteloop

final class GitBranchDetectionTests: XCTestCase {

    @discardableResult
    private func git(_ arguments: [String], in directory: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func makeTempDir(_ label: String) throws -> URL {
        try makeTemporaryDirectory(prefix: label)
    }

    func testRunGitBranch_ValidRepo() async throws {
        let tempDir = try makeTemporaryDirectory(prefix: "git-test")

        let initProcess = Process()
        initProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        initProcess.arguments = ["init", "-b", "main"]
        initProcess.currentDirectoryURL = tempDir
        initProcess.standardOutput = FileHandle.nullDevice
        initProcess.standardError = FileHandle.nullDevice
        try initProcess.run()
        initProcess.waitUntilExit()

        let branch = await ChatView.runGitBranch(at: tempDir)
        XCTAssertEqual(branch, "main")
    }

    func testRunGitBranch_NonGitDir() async throws {
        let tempDir = try makeTemporaryDirectory(prefix: "non-git")

        let branch = await ChatView.runGitBranch(at: tempDir)
        XCTAssertEqual(branch, "")
    }

    func testRunGitBranch_DoesNotBlockCooperativePool() async throws {
        let tempDir = try makeTemporaryDirectory(prefix: "git-pool")

        let initProcess = Process()
        initProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        initProcess.arguments = ["init", "-b", "feature"]
        initProcess.currentDirectoryURL = tempDir
        initProcess.standardOutput = FileHandle.nullDevice
        initProcess.standardError = FileHandle.nullDevice
        try initProcess.run()
        initProcess.waitUntilExit()

        // Run multiple concurrent git branch detections — should not starve the pool
        let results = await withTaskGroup(of: String.self, returning: [String].self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await ChatView.runGitBranch(at: tempDir)
                }
            }
            var results: [String] = []
            for await result in group {
                results.append(result)
            }
            return results
        }

        XCTAssertEqual(results.count, 10)
        XCTAssertTrue(results.allSatisfy { $0 == "feature" })
    }

    /// A freshly `git init`ed repo — an unborn branch. `rev-parse --abbrev-ref HEAD`
    /// prints the literal "HEAD" and exits 128 here; the branch name is still known.
    func testRunGitBranch_UnbornBranchReportsBranchName() async throws {
        let tempDir = try makeTempDir("git-unborn")
        try git(["init", "-b", "trunk"], in: tempDir)

        // No commit — HEAD points at a ref that does not exist yet.
        XCTAssertNotEqual(try git(["rev-parse", "--verify", "HEAD"], in: tempDir), 0)

        let branch = await ChatView.runGitBranch(at: tempDir)
        XCTAssertEqual(branch, "trunk")
    }

    func testRunGitBranch_RepoWithCommits() async throws {
        let tempDir = try makeTempDir("git-committed")
        try git(["init", "-b", "main"], in: tempDir)
        try git(["-c", "user.email=test@example.com", "-c", "user.name=Test",
                 "commit", "--allow-empty", "-m", "initial"], in: tempDir)

        let branch = await ChatView.runGitBranch(at: tempDir)
        XCTAssertEqual(branch, "main")
    }

    func testRunGitBranch_DetachedHeadIsEmpty() async throws {
        let tempDir = try makeTempDir("git-detached")
        try git(["init", "-b", "main"], in: tempDir)
        try git(["-c", "user.email=test@example.com", "-c", "user.name=Test",
                 "commit", "--allow-empty", "-m", "initial"], in: tempDir)
        try git(["checkout", "--detach", "HEAD"], in: tempDir)

        // Empty, not a commit-ish — the header hides the branch chip entirely.
        let branch = await ChatView.runGitBranch(at: tempDir)
        XCTAssertEqual(branch, "")
    }

    func testBranchChipName_DetectedBranchReplacesTheOneOnScreen() {
        XCTAssertEqual(ChatView.branchChipName(detected: "feature", showing: "main"), "feature")
    }

    func testBranchChipName_EmptyDetectionClearsTheOneOnScreen() {
        XCTAssertEqual(ChatView.branchChipName(detected: "", showing: "main"), "")
    }
}
